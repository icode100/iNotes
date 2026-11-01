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
}

#if os(macOS)
/// NavigationSplitView's detail-only visibility retains its content column on
/// macOS. Collapse the existing native navigation items without replacing the
/// detail controller, reparenting the editor, or taking over the split delegate.
struct WorkspaceNavigationChrome: NSViewRepresentable {
    var fullPage: Bool

    func makeNSView(context: Context) -> WorkspaceNavigationProbe {
        let view = WorkspaceNavigationProbe()
        view.setAccessibilityElement(false)
        view.fullPage = fullPage
        return view
    }

    func updateNSView(_ view: WorkspaceNavigationProbe, context: Context) {
        view.fullPage = fullPage
        view.scheduleSynchronization()
    }

    static func dismantleNSView(_ view: WorkspaceNavigationProbe, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class WorkspaceNavigationProbe: NSView {
    var fullPage = false
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

        func restore() {
            item.minimumThickness = minimumThickness
            item.maximumThickness = maximumThickness
            item.preferredThicknessFraction = preferredThicknessFraction
            item.automaticMaximumThickness = automaticMaximumThickness
            item.canCollapse = canCollapse
            // Assign after canCollapse, whose sidebar setter also changes this.
            item.canCollapseFromWindowResize = collapseFromResize
            item.isSpringLoaded = springLoaded
            item.collapseBehavior = collapseBehavior
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
        guard fullPage, window != nil else { restoreNavigation(); return }
        guard let controller = enclosingNavigationController() else { return }
        let navigationItems = Array(controller.splitViewItems.dropLast())
        if savedController !== controller || savedItems.map({ ObjectIdentifier($0.item) }) != navigationItems.map(ObjectIdentifier.init) {
            restoreNavigation()
            savedController = controller
            savedItems = navigationItems.map(ItemState.init)
        }
        for state in savedItems {
            let item = state.item
            if !item.canCollapse { item.canCollapse = true }
            if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
            if item.isSpringLoaded { item.isSpringLoaded = false }
            if item.collapseBehavior != .preferResizingSiblingsWithFixedSplitView {
                item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            }
            if !item.isCollapsed { item.isCollapsed = true }
        }
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
