import SwiftUI
import NotesCore
#if os(macOS)
import AppKit
import QuartzCore
#else
import UIKit
#endif

/// Window-local presentation state. Hiding chrome never replaces the page editor.
@MainActor
final class EditorPresentation: ObservableObject {
    @Published var fullPage = false
    @Published var toolsVisible = true
    @Published var sheetsVisible = true
    @Published var headingVisible = true

    func toggleSheets() {
        if fullPage { fullPage = false; sheetsVisible = true }
        else { sheetsVisible.toggle() }
    }

    func toggleHeading() {
        if fullPage { fullPage = false; headingVisible = true }
        else { headingVisible.toggle() }
    }
}

#if os(macOS)
/// NavigationSplitView's detail-only visibility retains its content column on
/// macOS. Collapse the existing native navigation items without replacing the
/// detail controller, reparenting the editor, or taking over the split delegate.
struct WorkspaceNavigationChrome: NSViewRepresentable {
    var fullPage: Bool
    var sheetsVisible: Bool
    var onSheetsVisibilityChange: (Bool) -> Void
    var onLeadingInsetChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WorkspaceNavigationProbe {
        let view = WorkspaceNavigationProbe()
        view.setAccessibilityElement(false)
        view.fullPage = fullPage
        view.sheetsVisible = sheetsVisible
        view.onSheetsVisibilityChange = onSheetsVisibilityChange
        view.onLeadingInsetChange = onLeadingInsetChange
        return view
    }

    func updateNSView(_ view: WorkspaceNavigationProbe, context: Context) {
        view.fullPage = fullPage
        view.sheetsVisible = sheetsVisible
        view.onSheetsVisibilityChange = onSheetsVisibilityChange
        view.onLeadingInsetChange = onLeadingInsetChange
        view.scheduleSynchronization()
    }

    static func dismantleNSView(_ view: WorkspaceNavigationProbe, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class WorkspaceNavigationProbe: NSView {
    var fullPage = false
    var sheetsVisible = true
    var onSheetsVisibilityChange: ((Bool) -> Void)?
    var onLeadingInsetChange: ((CGFloat) -> Void)?
    private var leadingInset: CGFloat?
    private var expandedSheetsWidth: CGFloat?
    private var restoreExpandedSheetsWidth = false
    private var applying = false
    private var transitionInProgress = false
    private var transitionGeneration = 0
    private var wasFullPage = false
    private var previousCollapsed: [Bool] = []
    private var collapseObservation: NSKeyValueObservation?
    private var sidebarObservations: [NSKeyValueObservation] = []
    private var splitResizeObserver: NSObjectProtocol?
    private var geometryScheduled = false
    private var scheduled = false
    private var dismantled = false
    private weak var savedController: NSSplitViewController?
    private var savedItems: [ItemState] = []
    private var savedDetail: ItemState?
    private var restoration: NavigationRestoration?
    private static let restorationOwners = NSMapTable<NSSplitViewController, NavigationRestoration>.weakToStrongObjects()

    private struct ItemState {
        let item: NSSplitViewItem
        let collapsed: Bool
        let canCollapse: Bool
        let collapseFromResize: Bool
        let collapseBehavior: NSSplitViewItem.CollapseBehavior
        let springLoaded: Bool
        let minimumThickness: CGFloat
        let maximumThickness: CGFloat
        let preferredThicknessFraction: CGFloat
        let automaticMaximumThickness: CGFloat
        let adjustsSafeArea: Bool?

        init(_ item: NSSplitViewItem) {
            self.item = item
            collapsed = item.isCollapsed
            canCollapse = item.canCollapse
            collapseFromResize = item.canCollapseFromWindowResize
            collapseBehavior = item.collapseBehavior
            springLoaded = item.isSpringLoaded
            minimumThickness = item.minimumThickness
            maximumThickness = item.maximumThickness
            preferredThicknessFraction = item.preferredThicknessFraction
            automaticMaximumThickness = item.automaticMaximumThickness
            if #available(macOS 26.0, *) { adjustsSafeArea = item.automaticallyAdjustsSafeAreaInsets }
            else { adjustsSafeArea = nil }
        }

        func restorePolicy() {
            item.minimumThickness = minimumThickness
            item.maximumThickness = maximumThickness
            item.preferredThicknessFraction = preferredThicknessFraction
            item.automaticMaximumThickness = automaticMaximumThickness
            item.canCollapse = canCollapse
            // Assign after canCollapse, whose sidebar setter also changes this.
            item.canCollapseFromWindowResize = collapseFromResize
            item.isSpringLoaded = springLoaded
            item.collapseBehavior = collapseBehavior
            if #available(macOS 26.0, *), let adjustsSafeArea {
                item.automaticallyAdjustsSafeAreaInsets = adjustsSafeArea
            }
        }

        func restore() {
            // A zero-duration replacement alone cannot stop a collapse whose
            // AppKit transaction has been queued but has not started yet. Block
            // the default collapse animation while restoring, then give the
            // original animation policy back to the next navigation owner.
            let originalAnimations = item.animations
            item.animations["collapsed"] = NSNull()
            defer { item.animations = originalAnimations }
            restorePolicy()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                item.animator().isCollapsed = collapsed
            }
        }
    }

    /// AppKit may start a queued collapse after the probe has been removed.
    /// Keep native restoration alive until its outstanding transactions finish,
    /// independently of the SwiftUI view, without publishing presentation state.
    @MainActor
    private final class NavigationRestoration {
        private weak var controller: NSSplitViewController?
        private let items: [ItemState]
        private let detail: ItemState?
        private var pending = 0
        private var detached = false
        private var restoring = false
        private var observations: [NSKeyValueObservation] = []
        private var afterRestoration: (() -> Void)?

        init(controller: NSSplitViewController, items: [ItemState], detail: ItemState?) {
            self.controller = controller
            self.items = items
            self.detail = detail
            WorkspaceNavigationProbe.restorationOwners.object(forKey: controller)?.relinquish()
            WorkspaceNavigationProbe.restorationOwners.setObject(self, forKey: controller)
        }

        private var ownsController: Bool {
            guard let controller else { return false }
            return WorkspaceNavigationProbe.restorationOwners.object(forKey: controller) === self
        }

        func beginTransition() { pending += 1 }

        func waitForRestoration(_ continuation: @escaping () -> Void) -> Bool {
            guard ownsController else { return false }
            // One controller has one current probe. Keep only its latest
            // request; the continuation weakly owns the replacement view.
            // SwiftUI may attach the replacement before dismantling this owner.
            afterRestoration = continuation
            return true
        }

        func completeTransition() {
            pending = max(0, pending - 1)
            guard detached, ownsController else { return }
            restore()
            if pending == 0 {
                controller?.splitView.layoutSubtreeIfNeeded()
                finishRestoration()
            }
        }

        func detach() {
            detached = true
            if pending > 0 {
                observations = items.map { state in
                    state.item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                        MainActor.assumeIsolated {
                            guard let self, !self.restoring, self.ownsController,
                                  item.isCollapsed != state.collapsed else { return }
                            self.restore()
                        }
                    }
                }
            }
            restore()
            if pending == 0 { finishRestoration() }
        }

        private func finishRestoration() {
            relinquish()
            let continuation = afterRestoration
            afterRestoration = nil
            continuation?()
        }

        private func restore() {
            guard ownsController, !restoring else { return }
            restoring = true
            defer { restoring = false }
            detail?.restorePolicy()
            for state in items { state.restore() }
        }

        private func relinquish() {
            observations = []
            if let controller, ownsController {
                WorkspaceNavigationProbe.restorationOwners.removeObject(forKey: controller)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let splitResizeObserver { NotificationCenter.default.removeObserver(splitResizeObserver) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleSynchronization()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { restoreNavigation() }
        else { scheduleSynchronization() }
    }

    override func layout() {
        super.layout()
        scheduleSynchronization()
    }

    func scheduleSynchronization() {
        guard !scheduled, !dismantled else { return }
        scheduled = true
        // SwiftUI may still be installing its split items during updateNSView.
        // Coalesce lifecycle/layout callbacks and change AppKit on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard !self.dismantled else { return }
            self.synchronizeNavigation()
        }
    }

    func dismantle() {
        dismantled = true
        restoreNavigation()
    }

    private func scheduleGeometryRefresh() {
        guard !geometryScheduled, !dismantled else { return }
        geometryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryScheduled = false
            guard !self.dismantled, self.window != nil,
                  let controller = self.savedController else { return }
            // Native sidebar animations can resize ancestor columns without
            // changing this underlay-sized probe's bounds. Measure after native
            // resize events; never force layout or reapply pane sizing here.
            self.updateLeadingInset(in: controller)
        }
    }

    private func synchronizeNavigation() {
        guard window != nil else { restoreNavigation(); return }
        guard let controller = enclosingNavigationController() else { return }
        let navigationItems = Array(controller.splitViewItems.dropLast())
        guard navigationItems.count >= 2 else { return }
        if let previous = Self.restorationOwners.object(forKey: controller), previous !== restoration,
           previous.waitForRestoration({ [weak self] in self?.scheduleSynchronization() }) {
            // Do not observe an old transaction as a user's divider change or
            // snapshot its intermediate state for a new navigation owner.
            return
        }
        if savedController !== controller || savedItems.map({ ObjectIdentifier($0.item) }) != navigationItems.map(ObjectIdentifier.init) {
            restoreNavigation()
            savedController = controller
            savedItems = navigationItems.map(ItemState.init)
            savedDetail = controller.splitViewItems.last.map(ItemState.init)
            restoration = NavigationRestoration(controller: controller, items: savedItems, detail: savedDetail)
            splitResizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: controller.splitView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleGeometryRefresh() }
            }
            sidebarObservations = navigationItems.dropLast().map { item in
                item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleGeometryRefresh() }
                }
            }
            // Observe native divider collapses as well as toolbar toggles. The
            // model must follow a drag, otherwise the next SwiftUI update would
            // reopen the pane. AppKit split-item changes occur on the main thread.
            collapseObservation = navigationItems.last?.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying, !self.transitionInProgress,
                          !self.fullPage, !self.dismantled else { return }
                    let visible = !item.isCollapsed
                    self.sheetsVisible = visible
                    if visible { self.restoreExpandedSheetsWidth = true }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.dismantled, !self.fullPage,
                              self.sheetsVisible == visible else { return }
                        self.onSheetsVisibilityChange?(visible)
                    }
                }
            }
        }
        applying = true
        defer { applying = false }
        // Let the native split view own column geometry and its animation.
        // Underlay frames require delayed SwiftUI padding updates which can
        // visibly lag behind a sidebar transition when the middle pane is shut.
        if #available(macOS 26.0, *) {
            for item in controller.splitViewItems.dropFirst() where item.automaticallyAdjustsSafeAreaInsets {
                item.automaticallyAdjustsSafeAreaInsets = false
            }
        }
        guard let sheets = navigationItems.last else { return }
        if !sheets.canCollapse { sheets.canCollapse = true }
        if sheets.canCollapseFromWindowResize { sheets.canCollapseFromWindowResize = false }
        if sheets.minimumThickness != 120 { sheets.minimumThickness = 120 }
        if sheets.maximumThickness != 480 { sheets.maximumThickness = 480 }
        if sheets.collapseBehavior != .preferResizingSiblingsWithFixedSplitView {
            sheets.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        // Hosting bounds can include the sidebar underlay on newer macOS.
        // Remember the visible list width, not that larger backing-view width.
        if !sheets.isCollapsed && !wasFullPage && !restoreExpandedSheetsWidth && !transitionInProgress {
            let rect = sheets.viewController.view.convert(sheets.viewController.view.bounds, to: controller.splitView)
            expandedSheetsWidth = max(120, min(480, rect.maxX - sheetsLeadingEdge(in: controller)))
        }
        let changesPresentation = wasFullPage != fullPage || (!fullPage && sheets.isCollapsed == sheetsVisible)
        let wasTransitioning = transitionInProgress
        if changesPresentation {
            transitionGeneration += 1
            let generation = transitionGeneration
            transitionInProgress = true
            NSAnimationContext.beginGrouping()
            let animation = NSAnimationContext.current
            animation.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.allowsImplicitAnimation = true
            let restoration = restoration
            restoration?.beginTransition()
            animation.completionHandler = { [weak self] in
                MainActor.assumeIsolated {
                    restoration?.completeTransition()
                    guard let self, !self.dismantled, self.transitionGeneration == generation else { return }
                    self.transitionInProgress = false
                    // Retain this snapshot only through an interrupted exit.
                    // A later sheets animation must not reuse an older session.
                    if !self.fullPage { self.previousCollapsed = [] }
                    self.scheduleSynchronization()
                }
            }
        }
        defer { if changesPresentation { NSAnimationContext.endGrouping() } }
        func collapse(_ item: NSSplitViewItem, _ collapsed: Bool) {
            // Even an equal model value may have an older animation pending.
            // The newest explicit transition must replace that animation.
            if changesPresentation { item.animator().isCollapsed = collapsed }
            else if item.isCollapsed != collapsed { item.isCollapsed = collapsed }
        }
        if fullPage {
            // A quick exit/re-entry must retain the pre-full-page layout, not
            // snapshot columns still finishing the interrupted restore animation.
            if !wasFullPage && (!wasTransitioning || previousCollapsed.isEmpty) {
                previousCollapsed = navigationItems.map(\.isCollapsed)
            }
            for item in navigationItems {
                if !item.canCollapse { item.canCollapse = true }
                if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
                if item.isSpringLoaded { item.isSpringLoaded = false }
                if item.collapseBehavior != .preferResizingSiblingsWithFixedSplitView {
                    item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                }
                collapse(item, true)
            }
        } else {
            if wasFullPage {
                // Restore the independently hidden sidebar, while the sheets
                // pane follows its own state (including a restore button).
                for (index, state) in savedItems.dropLast().enumerated() {
                    state.restorePolicy()
                    if previousCollapsed.indices.contains(index) {
                        collapse(state.item, previousCollapsed[index])
                    }
                }
            }
            if sheets.isCollapsed == sheetsVisible {
                collapse(sheets, !sheetsVisible)
                if sheetsVisible { restoreExpandedSheetsWidth = true }
            }
            // Do not force the destination layout while AppKit is expanding
            // the item: that jumps to its final frame and cancels smooth motion.
            // Check any remaining width correction only after native completion.
            if sheetsVisible && restoreExpandedSheetsWidth && !transitionInProgress, let expandedSheetsWidth {
                controller.splitView.layoutSubtreeIfNeeded()
                let targetEdge = sheetsLeadingEdge(in: controller) + expandedSheetsWidth
                let currentEdge = sheets.viewController.view.convert(sheets.viewController.view.bounds,
                                                                      to: controller.splitView).maxX
                // Native expansion normally retains the width. Reassigning an
                // unchanged divider target can restart its in-flight animation.
                if abs(currentEdge - targetEdge) > 1 {
                    controller.splitView.setPosition(targetEdge, ofDividerAt: controller.splitViewItems.count - 2)
                }
                restoreExpandedSheetsWidth = false
            }
        }
        wasFullPage = fullPage
        updateLeadingInset(in: controller)
    }

    private func sheetsLeadingEdge(in controller: NSSplitViewController) -> CGFloat {
        let split = controller.splitView
        return controller.splitViewItems.dropLast(2).filter { !$0.isCollapsed }
            .map { $0.viewController.view.convert($0.viewController.view.bounds, to: split).maxX + split.dividerThickness }
            .max() ?? split.bounds.minX
    }

    private func updateLeadingInset(in controller: NSSplitViewController) {
        guard let detail = controller.splitViewItems.last else { return }
        let split = controller.splitView
        let detailView = detail.viewController.view
        let detailRect = detailView.convert(detailView.bounds, to: split)
        let navigationRight = controller.splitViewItems.dropLast()
            .filter { !$0.isCollapsed }
            .map { $0.viewController.view.convert($0.viewController.view.bounds, to: split).maxX }
            .max() ?? detailRect.minX
        // Newer macOS can extend a column underneath the sidebar. When the
        // middle column is collapsed its successor receives no leading safe
        // area. Supply only the measured overlap; never move/recreate the editor.
        var nativeColumns = false
        if #available(macOS 26.0, *) {
            nativeColumns = controller.splitViewItems.dropFirst().allSatisfy { !$0.automaticallyAdjustsSafeAreaInsets }
        }
        // During expansion a visible pane's target frame can precede the
        // moving detail frame. With native nonoverlapping columns that is the
        // animation, not occlusion; compensating with padding cancels its motion.
        let overlap = nativeColumns ? 0 : max(0, min(detailRect.width, navigationRight - detailRect.minX)
                                              - detailView.safeAreaInsets.left)
        if let leadingInset, abs(overlap - leadingInset) <= 0.5 { return }
        leadingInset = overlap
        onLeadingInsetChange?(overlap)
    }

    private func enclosingNavigationController() -> NSSplitViewController? {
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical,
               let controller = split.delegate as? NSSplitViewController,
               controller.splitViewItems.count >= 2,
               let detail = controller.splitViewItems.last,
               isDescendant(of: detail.viewController.view) {
                return controller
            }
            ancestor = view.superview
        }
        return nil
    }

    private func restoreNavigation() {
        transitionGeneration += 1
        transitionInProgress = false
        collapseObservation = nil
        sidebarObservations = []
        if let splitResizeObserver { NotificationCenter.default.removeObserver(splitResizeObserver) }
        splitResizeObserver = nil
        leadingInset = nil
        wasFullPage = false
        previousCollapsed = []
        expandedSheetsWidth = nil
        restoreExpandedSheetsWidth = false
        guard !savedItems.isEmpty else { return }
        savedItems = []
        savedController = nil
        savedDetail = nil
        // AppKit retains each item's last expanded width while collapsed.
        // Restoring its sizing policy and collapsed state restores those widths
        // without modifying native view frames or the editor's ancestry.
        let detachedRestoration = restoration
        restoration = nil
        detachedRestoration?.detach()
    }
}
#endif

enum WorkspaceTheme: String, CaseIterable, Identifiable {
    case classic, alpine, coast, arctic
    case openSkyscape = "open-skyscape"
    case rubyHills = "ruby-hills"
    case nature
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openSkyscape: return "Open Skyscape"
        case .rubyHills: return "Ruby Hills"
        default: return rawValue.capitalized
        }
    }

    /// Keep an older Forest preference scenic without retaining the removed
    /// artwork or changing notebook data. All appearance consumers use this
    /// resolver so the menu selection, accents, and background agree.
    init(preferenceValue: String) {
        self = preferenceValue == "forest" ? .nature : (Self(rawValue: preferenceValue) ?? .classic)
    }

    static var photographicThemes: [Self] { allCases.filter { $0 != .classic } }

    func accent(isDark: Bool) -> Color {
        switch self {
        case .classic: return .accentColor
        case .alpine: return Color(hex: isDark ? "#BDB3F5" : "#6653AA")
        case .coast: return Color(hex: isDark ? "#81CFE3" : "#14758F")
        case .arctic: return Color(hex: isDark ? "#8DD9ED" : "#19728A")
        case .openSkyscape: return Color(hex: isDark ? "#A5CFF5" : "#286DA8")
        case .rubyHills: return Color(hex: isDark ? "#E8A6B4" : "#A3444E")
        case .nature: return Color(hex: isDark ? "#BBD39A" : "#56713A")
        }
    }
    func surface(isDark: Bool) -> Color {
        switch self {
        case .classic: return .clear
        case .alpine: return Color(hex: isDark ? "#252330" : "#F1EFF8")
        case .coast: return Color(hex: isDark ? "#1D2A31" : "#ECF5F7")
        case .arctic: return Color(hex: isDark ? "#192A35" : "#EDF5F8")
        case .openSkyscape: return Color(hex: isDark ? "#1C2839" : "#EEF5FC")
        case .rubyHills: return Color(hex: isDark ? "#302229" : "#F8EEEE")
        case .nature: return Color(hex: isDark ? "#252C20" : "#F1F3E8")
        }
    }

    /// Opaque labels avoid native sidebar vibrancy fading small text into artwork.
    func sidebarSecondary(isDark: Bool) -> AnyShapeStyle {
        #if os(macOS)
        if self != .classic { return AnyShapeStyle(Color(hex: isDark ? "#D7E3E8" : "#37474F")) }
        #endif
        return AnyShapeStyle(.secondary)
    }
}

/// Shared native-image cache keeps the full-quality photographs out of the
/// notebook model and avoids decoding another copy for each navigation pane.
@MainActor
enum WorkspaceArtwork {
    #if os(macOS)
    private static let cache = NSCache<NSString, NSImage>()
    #else
    private static let cache = NSCache<NSString, UIImage>()
    #endif

    private static let resources: Bundle? = {
        // SwiftPM puts resources beside its executable. The distributable Mac
        // app relocates that bundle into Contents/Resources; Xcode's iPad target
        // copies WorkspaceThemes directly into its main bundle. Resolve these
        // explicitly so a missing relocated bundle never triggers Bundle.module's
        // fatal error or depends on a temporary build directory still existing.
        let bases = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for base in bases {
            if let bundle = Bundle(url: base.appendingPathComponent("iNotes_NotesApp.bundle")),
               bundle.url(forResource: "coast-light", withExtension: "png", subdirectory: "WorkspaceThemes") != nil {
                return bundle
            }
        }
        return Bundle.main
    }()

    static func url(theme: WorkspaceTheme, isDark: Bool) -> URL? {
        guard theme != .classic else { return nil }
        return resources?.url(forResource: "\(theme.rawValue)-\(isDark ? "dark" : "light")",
                              withExtension: "png", subdirectory: "WorkspaceThemes")
    }

    static func image(theme: WorkspaceTheme, isDark: Bool) -> Image? {
        guard let url = url(theme: theme, isDark: isDark) else { return nil }
        let key = url.lastPathComponent as NSString
        cache.countLimit = 2
        cache.totalCostLimit = 20 * 1024 * 1024
        #if os(macOS)
        if let image = cache.object(forKey: key) { return Image(nsImage: image) }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key, cost: 1672 * 941 * 4)
        return Image(nsImage: image)
        #else
        if let image = cache.object(forKey: key) { return Image(uiImage: image) }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key, cost: 1672 * 941 * 4)
        return Image(uiImage: image)
        #endif
    }
}

struct WorkspaceScenery: View {
    var readableSidebar = false
    @AppStorage("workspaceTheme") private var selectedTheme = "classic"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var theme: WorkspaceTheme { WorkspaceTheme(preferenceValue: selectedTheme) }

    var body: some View {
        GeometryReader { geometry in
            if theme != .classic {
                let dark = colorScheme == .dark
                let surface = theme.surface(isDark: dark)
                // Keep landscape detail recognizable in narrow navigation panes,
                // fading into a quiet surface below rather than stretching it.
                let height = min(geometry.size.height, 420)
                ZStack(alignment: .top) {
                    surface
                    if let artwork = WorkspaceArtwork.image(theme: theme, isDark: dark) {
                        artwork.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: height)
                            .clipped()
                            .overlay {
                                (dark ? Color.black : Color.white)
                                    .opacity(contrast == .increased ? (dark ? 0.72 : 0.88) : (dark ? 0.38 : 0.64))
                            }
                            #if os(macOS)
                            .overlay {
                                // A stable surface behind navigation labels also quiets
                                // bright waves/rocks beneath native disclosure controls.
                                if readableSidebar {
                                    surface.opacity(contrast == .increased ? 1 : 0.72)
                                }
                            }
                            #endif
                            .overlay {
                                LinearGradient(stops: [.init(color: surface.opacity(0), location: 0.35),
                                                       .init(color: surface.opacity(0.3), location: 0.7),
                                                       .init(color: surface, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A native menu state remains visible even when macOS strips label images.
struct CheckedMenuButton: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isSelected }, set: { selected in
            // These are exclusive choices, so clicking the current item must
            // not clear it. Selecting another item updates the owning setting.
            if selected { action() }
        }))
        .toggleStyle(.automatic)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("pageColorScheme") private var pageColorScheme = "system"
    @AppStorage("workspaceTheme") private var workspaceTheme = "classic"
    var body: some View {
        Menu {
            Menu("Light and dark") {
                CheckedMenuButton(title: "Match system", isSelected: appearance == "system") { appearance = "system" }
                CheckedMenuButton(title: "Light", isSelected: appearance == "light") { appearance = "light" }
                CheckedMenuButton(title: "Dark", isSelected: appearance == "dark") { appearance = "dark" }
            }
            Menu("Page colors · all sheets") {
                CheckedMenuButton(title: "Match appearance", isSelected: pageColorScheme == "system") { pageColorScheme = "system" }
                CheckedMenuButton(title: "Vintage · off-white", isSelected: pageColorScheme == "vintage") { pageColorScheme = "vintage" }
            }
            Menu("Workspace scenery") {
                ForEach(WorkspaceTheme.allCases) { theme in
                    CheckedMenuButton(title: theme.title, isSelected: WorkspaceTheme(preferenceValue: workspaceTheme) == theme) { workspaceTheme = theme.rawValue }
                }
            }
        } label: { Label("Appearance", systemImage: "paintpalette") }
        .help("Application scenery and page colors for all sheets")
    }
}
