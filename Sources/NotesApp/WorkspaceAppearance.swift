import SwiftUI
import NotesCore
#if os(macOS)
import AppKit
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
    private var wasFullPage = false
    private var previousCollapsed: [Bool] = []
    private var collapseObservation: NSKeyValueObservation?
    private var scheduled = false
    private var dismantled = false
    private weak var savedController: NSSplitViewController?
    private var savedItems: [ItemState] = []

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
        }

        func restore() {
            restorePolicy()
            item.isCollapsed = collapsed
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

    private func synchronizeNavigation() {
        guard window != nil else { restoreNavigation(); return }
        guard let controller = enclosingNavigationController() else { return }
        let navigationItems = Array(controller.splitViewItems.dropLast())
        guard navigationItems.count >= 2 else { return }
        if savedController !== controller || savedItems.map({ ObjectIdentifier($0.item) }) != navigationItems.map(ObjectIdentifier.init) {
            restoreNavigation()
            savedController = controller
            savedItems = navigationItems.map(ItemState.init)
            // Observe native divider collapses as well as toolbar toggles. The
            // model must follow a drag, otherwise the next SwiftUI update would
            // reopen the pane. AppKit split-item changes occur on the main thread.
            collapseObservation = navigationItems.last?.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying, !self.fullPage, !self.dismantled else { return }
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
        guard let sheets = navigationItems.last else { return }
        sheets.canCollapse = true
        sheets.canCollapseFromWindowResize = false
        sheets.minimumThickness = 120
        sheets.maximumThickness = 480
        sheets.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Hosting bounds can include the sidebar underlay on newer macOS.
        // Remember the visible list width, not that larger backing-view width.
        if !sheets.isCollapsed && !wasFullPage && !restoreExpandedSheetsWidth {
            let rect = sheets.viewController.view.convert(sheets.viewController.view.bounds, to: controller.splitView)
            expandedSheetsWidth = max(120, min(480, rect.maxX - sheetsLeadingEdge(in: controller)))
        }
        if fullPage {
            if !wasFullPage { previousCollapsed = navigationItems.map(\.isCollapsed) }
            for item in navigationItems {
                item.canCollapse = true
                item.canCollapseFromWindowResize = false
                item.isSpringLoaded = false
                item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                if !item.isCollapsed { item.isCollapsed = true }
            }
        } else {
            if wasFullPage {
                // Restore the independently hidden sidebar, while the sheets
                // pane follows its own state (including a restore button).
                for (index, state) in savedItems.dropLast().enumerated() {
                    state.restorePolicy()
                    if previousCollapsed.indices.contains(index) {
                        state.item.isCollapsed = previousCollapsed[index]
                    }
                }
            }
            if sheets.isCollapsed == sheetsVisible {
                sheets.isCollapsed = !sheetsVisible
                if sheetsVisible { restoreExpandedSheetsWidth = true }
            }
            if sheetsVisible && restoreExpandedSheetsWidth, let expandedSheetsWidth {
                controller.splitView.layoutSubtreeIfNeeded()
                controller.splitView.setPosition(sheetsLeadingEdge(in: controller) + expandedSheetsWidth,
                                                 ofDividerAt: controller.splitViewItems.count - 2)
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
        let overlap = max(0, min(detailRect.width, navigationRight - detailRect.minX)
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
        collapseObservation = nil
        wasFullPage = false
        previousCollapsed = []
        expandedSheetsWidth = nil
        restoreExpandedSheetsWidth = false
        guard !savedItems.isEmpty else { return }
        let snapshots = savedItems
        savedItems = []
        savedController = nil
        // AppKit retains each item's last expanded width while collapsed.
        // Restoring its sizing policy and collapsed state restores those widths
        // without modifying native view frames or the editor's ancestry.
        for state in snapshots { state.restore() }
    }
}
#endif

enum WorkspaceTheme: String, CaseIterable, Identifiable {
    case classic, alpine, coast, forest
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func accent(isDark: Bool) -> Color {
        switch self {
        case .classic: return .accentColor
        case .alpine: return Color(hex: isDark ? "#BDB3F5" : "#6653AA")
        case .coast: return Color(hex: isDark ? "#81CFE3" : "#14758F")
        case .forest: return Color(hex: isDark ? "#A5D3A7" : "#39754D")
        }
    }
    func surface(isDark: Bool) -> Color {
        switch self {
        case .classic: return .clear
        case .alpine: return Color(hex: isDark ? "#252330" : "#F1EFF8")
        case .coast: return Color(hex: isDark ? "#1D2A31" : "#ECF5F7")
        case .forest: return Color(hex: isDark ? "#212C25" : "#EEF4ED")
        }
    }
}

/// Shared native-image cache keeps the six full-quality photographs out of the
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
    @AppStorage("workspaceTheme") private var selectedTheme = "classic"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var theme: WorkspaceTheme { WorkspaceTheme(rawValue: selectedTheme) ?? .classic }

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

struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("pageColorScheme") private var pageColorScheme = "system"
    @AppStorage("workspaceTheme") private var workspaceTheme = "classic"
    var body: some View {
        Menu {
            Picker("Light and dark", selection: $appearance) {
                Text("Match system").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Picker("Page colors · all sheets", selection: $pageColorScheme) {
                Text("Match appearance").tag("system")
                Text("Vintage · off-white").tag("vintage")
            }
            Picker("Workspace scenery", selection: $workspaceTheme) {
                ForEach(WorkspaceTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
            }
        } label: { Label("Appearance", systemImage: "paintpalette") }
        .help("Application scenery and page colors for all sheets")
    }
}
