import SwiftUI
import NotesCore
#if os(macOS)
import AppKit
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

/// Small native paths provide scenery in both appearances without bitmap assets.
struct WorkspaceScenery: View {
    @AppStorage("workspaceTheme") private var selectedTheme = "classic"
    @Environment(\.colorScheme) private var colorScheme
    var theme: WorkspaceTheme { WorkspaceTheme(rawValue: selectedTheme) ?? .classic }
    var body: some View {
        Canvas { context, size in
            guard theme != .classic else { return }
            let dark = colorScheme == .dark
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.surface(isDark: dark)))
            let h = min(size.height, 260)
            for layer in 0..<3 {
                let offset = Double(layer) * h * 0.13
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h * 0.7 + offset))
                switch theme {
                case .alpine:
                    path.addLine(to: CGPoint(x: size.width * 0.22, y: h * 0.28 + offset))
                    path.addLine(to: CGPoint(x: size.width * 0.45, y: h * 0.65 + offset))
                    path.addLine(to: CGPoint(x: size.width * 0.73, y: h * 0.12 + offset))
                    path.addLine(to: CGPoint(x: size.width, y: h * 0.55 + offset))
                case .forest:
                    for tree in 0..<9 {
                        let x = size.width * Double(tree) / 8
                        path.addLine(to: CGPoint(x: x, y: h * 0.72 + offset))
                        path.addLine(to: CGPoint(x: x + size.width / 16, y: h * (tree.isMultiple(of: 2) ? 0.3 : 0.45) + offset))
                    }
                case .coast, .classic:
                    path.addCurve(to: CGPoint(x: size.width, y: h * 0.55 + offset),
                                  control1: CGPoint(x: size.width * 0.35, y: offset),
                                  control2: CGPoint(x: size.width * 0.6, y: h * 1.2 + offset))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(theme.accent(isDark: dark).opacity(dark ? 0.065 : 0.055)))
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
