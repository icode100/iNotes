import SwiftUI
#if os(macOS)
import AppKit
#endif

private struct CustomizeFloatingToolbarKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var customizeFloatingToolbar: () -> Void {
        get { self[CustomizeFloatingToolbarKey.self] }
        set { self[CustomizeFloatingToolbarKey.self] = newValue }
    }
}

enum FloatingPageTool: Hashable {
    enum Command: String {
        case exitWorkspace, colors, undo, redo, paper, more, equations, attachment
        case selection, textSize, navigation, heading, tablet, toolbarLayout, hideToolbar
        #if os(macOS)
        case shapes, fill
        #endif
    }
    case command(Command), drawing(InkTool)
    #if os(macOS)
    case format(RichTextCommand)
    #endif

    var key: String {
        switch self {
        case .command(let command): return command.rawValue
        case .drawing(let tool): return "draw." + tool.rawValue
        #if os(macOS)
        case .format(let command): return "format." + command.rawValue
        #endif
        }
    }
}

struct FloatingToolbarChoice: Identifiable {
    enum Category: String, CaseIterable {
        case drawing = "Drawing and selection", text = "Text", page = "Page and workspace"
    }
    let tool: FloatingPageTool
    let title: String
    let symbol: String
    let category: Category
    let startsVisible: Bool
    var id: String { tool.key }

    static let preferenceKey = "floatingToolbarButtons"
    static let factory = "default"

    static let drawingChoices: [(tool: InkTool, title: String, symbol: String)] = [
        (.text, "Text", "textformat"), (.select, "Select", "cursorarrow"), (.lasso, "Lasso", "lasso"),
        (.pen, "Pen", "pencil.tip"), (.line, "Straight line", "line.diagonal"), (.pencil, "Pencil", "pencil"),
        (.marker, "Marker", "paintbrush.pointed"), (.highlighter, "Highlighter", "highlighter"), (.eraser, "Eraser", "eraser")
    ]
    #if os(macOS)
    static let formatCommands: [(title: String, icon: String, command: RichTextCommand)] = [
        ("Bold", "bold", .bold), ("Italic", "italic", .italic), ("Underline", "underline", .underline),
        ("Heading", "textformat.size", .heading), ("Body text", "textformat", .body),
        ("Bullet list", "list.bullet", .bullet), ("Checklist", "checklist", .checklist)
    ]
    #endif

    static let all: [Self] = {
        func button(_ command: FloatingPageTool.Command, _ title: String, _ symbol: String,
                    _ category: Category, visible: Bool = false) -> Self {
            Self(tool: .command(command), title: title, symbol: symbol, category: category, startsVisible: visible)
        }
        // Exit comes first so its default placement is reachable in a narrow viewport.
        var items = [button(.exitWorkspace, "Exit Full Page or Full Screen", "arrow.down.right.and.arrow.up.left", .page, visible: true)]
        items += drawingChoices.map {
            Self(tool: .drawing($0.tool), title: $0.title, symbol: $0.symbol,
                 category: $0.tool == .text ? .text : .drawing, startsVisible: true)
        }
        #if os(macOS)
        items += [button(.shapes, "Shapes and tables", "square.on.circle", .drawing, visible: true),
                  button(.fill, "Shape fill and arrow style", "paintbrush.fill", .drawing, visible: true)]
        #endif
        items += [
            button(.colors, "Colors", "paintpalette", .drawing, visible: true),
            button(.undo, "Undo", "arrow.uturn.backward", .page, visible: true),
            button(.redo, "Redo", "arrow.uturn.forward", .page, visible: true),
            button(.paper, "Paper and appearance", "slider.horizontal.3", .page, visible: true),
            button(.more, "More page tools", "ellipsis.circle", .page, visible: true),
            button(.textSize, "Text size", "textformat.size", .text, visible: true),
            button(.selection, "Selection actions", "square.dashed", .drawing),
            button(.equations, "Equations", "function", .text),
            button(.attachment, "Attach a file", "paperclip", .page),
            button(.navigation, "Show or hide page navigation", "ellipsis.rectangle", .page),
            button(.heading, "Show or hide heading", "text.rectangle", .page),
            button(.tablet, "Pen tablet status", "pencil.tip", .page),
            button(.toolbarLayout, "Full-screen toolbar layout", "circle.grid.3x3.circle", .page),
            button(.hideToolbar, "Hide drawing toolbar", "rectangle.topthird.inset.filled", .page)
        ]
        #if os(macOS)
        items += formatCommands.map {
            Self(tool: .format($0.command), title: $0.title, symbol: $0.icon, category: .text, startsVisible: false)
        }
        #endif
        return items
    }()

    static func visibleIDs(in setting: String) -> Set<String> {
        if setting == factory { return Set(all.filter(\.startsVisible).map(\.id)) }
        return Set(setting.split(separator: ",").map(String.init))
    }

    static func setting(_ setting: String, including id: String, visible: Bool) -> String {
        var ids = visibleIDs(in: setting)
        if visible { ids.insert(id) } else { ids.remove(id) }
        return ids.sorted().joined(separator: ",")
    }
}

struct FloatingToolbarCustomization: View {
    @AppStorage(FloatingToolbarChoice.preferenceKey) private var setting = FloatingToolbarChoice.factory
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.workspaceDiagnosticControls) private var diagnostics
    #endif

    private func visibility(of choice: FloatingToolbarChoice) -> Binding<Bool> {
        Binding(get: { FloatingToolbarChoice.visibleIDs(in: setting).contains(choice.id) },
                set: { setting = FloatingToolbarChoice.setting(setting, including: choice.id, visible: $0) })
    }

    private func restore() { setting = FloatingToolbarChoice.factory }
    private func finish() { dismiss() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customize floating toolbar").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(FloatingToolbarChoice.Category.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.rawValue).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), alignment: .leading)], alignment: .leading, spacing: 10) {
                                ForEach(FloatingToolbarChoice.all.filter { $0.category == category }) { choice in
                                    let selected = visibility(of: choice)
                                    Toggle(isOn: selected) { Label(choice.title, systemImage: choice.symbol) }
                                    #if os(macOS)
                                    .toggleStyle(.checkbox)
                                    .background {
                                        if let diagnostics {
                                            WorkspaceDiagnosticControlProbe(controls: diagnostics, identifier: "floating.choice." + choice.id,
                                                value: selected.wrappedValue ? "On" : "Off", action: { selected.wrappedValue.toggle() })
                                        }
                                    }
                                    #endif
                                    .accessibilityLabel(choice.title)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack {
                Button("Restore defaults", action: restore)
                    #if os(macOS)
                    .background {
                        if let diagnostics {
                            WorkspaceDiagnosticControlProbe(controls: diagnostics, identifier: "floating.choice.restore", action: restore)
                        }
                    }
                    #endif
                Spacer()
                Button("Done", action: finish).keyboardShortcut(.defaultAction)
                    #if os(macOS)
                    .background {
                        if let diagnostics {
                            WorkspaceDiagnosticControlProbe(controls: diagnostics, identifier: "floating.choice.done", action: finish)
                        }
                    }
                    #endif
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 584, height: 510)
        #endif
    }
}

/// Coordinates are in the visible page viewport, independent of page zoom and scroll.
struct FloatingPageToolbarLayout {
    let diameter: CGFloat
    let collapsedCenter: CGPoint
    let bubbleCenter: CGPoint
    let itemCenters: [CGPoint]
    let nextPageCenter: CGPoint?

    var usesPopover: Bool { itemCenters.isEmpty }

    static func resolve(size: CGSize, anchor: CGPoint, itemCount: Int) -> Self {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        let viewport = CGSize(width: width, height: height)
        let shorter = min(width, height)
        let diameter = min(44, max(0, shorter - 4))
        let inset = edgeInset(diameter: diameter, size: viewport)
        let home = CGPoint(x: inset + unit(anchor.x) * max(0, width - 2 * inset),
                           y: inset + unit(anchor.y) * max(0, height - 2 * inset))
        let pitch = diameter + 5
        let limit = shorter / 2 - inset
        let count = max(0, itemCount)
        guard diameter > 0, count > 0 else {
            return Self(diameter: diameter, collapsedCenter: home, bubbleCenter: home, itemCenters: [], nextPageCenter: nil)
        }
        var hub = home
        var slots: [CGPoint] = []
        if limit >= pitch {
            // Chord length, rather than arc length, bounds adjacent circular buttons.
            let ringCapacity = floor(CGFloat.pi / asin(pitch / (2 * limit)) + 0.000_001)
            let number = Int(min(CGFloat(count), ringCapacity))
            let radius = number <= 2 ? pitch : max(pitch, pitch / (2 * sin(.pi / CGFloat(number))))
            let margin = inset + radius
            hub.x = max(margin, min(width - margin, home.x))
            hub.y = max(margin, min(height - margin, home.y))
            slots = (0..<number).map { index in
                let angle = CGFloat(index) * 2 * .pi / CGFloat(number) - .pi / 2
                return CGPoint(x: hub.x + cos(angle) * radius, y: hub.y + sin(angle) * radius)
            }
        } else {
            // A narrow split view can still fit a row or column of buttons.
            let horizontal = width >= height
            let length = horizontal ? width : height
            let capacity = Int(min(CGFloat(count), max(0, floor((length - 2 * inset) / pitch))))
            if capacity >= 2 || count == 1 && capacity == 1 {
                let number = min(count, capacity)
                let origin = horizontal ? home.x : home.y
                let step = origin < length / 2 ? pitch : -pitch
                let offset = step * CGFloat(number)
                let first = max(inset - min(offset, 0), min(length - inset - max(offset, 0), origin))
                if horizontal { hub.x = first } else { hub.y = first }
                slots = (1...number).map { index in
                    let coordinate = first + step * CGFloat(index)
                    return horizontal ? CGPoint(x: coordinate, y: hub.y) : CGPoint(x: hub.x, y: coordinate)
                }
            }
        }
        var next: CGPoint?
        if slots.count < count { next = slots.popLast() }
        return Self(diameter: diameter, collapsedCenter: home, bubbleCenter: hub,
                    itemCenters: slots, nextPageCenter: next)
    }

    static func normalizedAnchor(for center: CGPoint, size: CGSize, diameter: CGFloat) -> CGPoint {
        let inset = edgeInset(diameter: diameter, size: size)
        func normalized(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            length > 2 * inset ? unit((value - inset) / (length - 2 * inset)) : 0.5
        }
        return CGPoint(x: normalized(center.x, size.width), y: normalized(center.y, size.height))
    }

    private static func edgeInset(diameter: CGFloat, size: CGSize) -> CGFloat {
        min(max(0, min(size.width, size.height)) / 2, diameter / 2 + 4)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0.5 }
}

struct FloatingPageToolbar<Item: Hashable, ItemContent: View>: View {
    let items: [Item]
    let hoverOnly: Bool
    @Environment(\.customizeFloatingToolbar) private var customize
    @Binding var anchor: CGPoint
    @ViewBuilder let content: (Item) -> ItemContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    #if os(macOS)
    @Environment(\.workspaceDiagnosticControls) private var diagnostics
    #endif
    @FocusState private var hubFocused: Bool
    @ViewState private var expanded = false
    @ViewState private var hovering = false
    @ViewState private var pageIndex = 0
    @ViewState private var dragOrigin: CGPoint?
    @ViewState private var dragAnchor: CGPoint?
    @ViewState private var suppressClick = false
    @GestureState private var dragIsActive = false
    @Namespace private var viewport

    init(items: [Item], hoverOnly: Bool, anchor: Binding<CGPoint>, @ViewBuilder content: @escaping (Item) -> ItemContent) {
        self.items = items
        self.hoverOnly = hoverOnly
        _anchor = anchor
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = FloatingPageToolbarLayout.resolve(size: size, anchor: dragAnchor ?? anchor, itemCount: items.count)
            let capacity = max(1, layout.itemCenters.count)
            let pages = max(1, (items.count + capacity - 1) / capacity)
            let current = min(pageIndex, pages - 1)
            let first = current * capacity
            let displayed = Array(items.dropFirst(first).prefix(capacity))
            let hint = hoverOnly && !hovering && !hubFocused && !expanded && !voiceOver && dragOrigin == nil
            let position = expanded ? layout.bubbleCenter : layout.collapsedCenter
            ZStack(alignment: .topLeading) {
                if expanded && !layout.usesPopover {
                    ForEach(Array(displayed.enumerated()), id: \.element) { offset, item in
                        tool(item, diameter: layout.diameter)
                            .position(layout.itemCenters[offset])
                    }
                    if let next = layout.nextPageCenter {
                        Button { pageIndex = (current + 1) % pages } label: {
                            Image(systemName: "chevron.forward").frame(width: layout.diameter, height: layout.diameter)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: Circle())
                        .help("Next tools")
                        .accessibilityLabel("Next tools")
                        .accessibilityValue("Page \(current + 1) of \(pages)")
                        .position(next)
                    }
                }
                handle(hint: hint, diameter: layout.diameter)
                    .onHover { hovering = $0 }
                    .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(viewport))
                        .updating($dragIsActive) { _, active, _ in active = true }
                        .onChanged { drag($0.translation, from: position, size: size, diameter: layout.diameter) }
                        .onEnded { drop($0.translation, size: size, diameter: layout.diameter) })
                    .onChange(of: dragIsActive) { _, active in
                        guard !active else { return }
                        DispatchQueue.main.async {
                            // A system-cancelled drag can omit onEnded.
                            guard dragOrigin != nil else { return }
                            dragAnchor = nil
                            dragOrigin = nil
                            suppressClick = false
                        }
                    }
                    .background {
                        #if os(macOS)
                        if let diagnostics {
                            WorkspaceDiagnosticControlProbe(controls: diagnostics, identifier: "floating.bubble",
                                value: expanded ? "expanded" : hint ? "hint" : "collapsed", action: toggle)
                            FloatingToolbarGestureProbe(hover: { hovering = $0 },
                                drag: { drag($0, from: position, size: size, diameter: layout.diameter) },
                                drop: { drop($0, size: size, diameter: layout.diameter) })
                        }
                        #endif
                    }
                    .popover(isPresented: Binding(get: { expanded && layout.usesPopover && !items.isEmpty },
                        set: { if !$0 && layout.usesPopover { expanded = false } })) {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 3), spacing: 8) {
                                ForEach(items, id: \.self) { item in tool(item, diameter: 44) }
                            }.padding(10)
                        }.frame(width: 180, height: min(275, CGFloat((items.count + 2) / 3) * 52 + 20))
                    }
                    .position(position)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(name: viewport)
            .background {
                #if os(macOS)
                if let diagnostics {
                    WorkspaceDiagnosticControlProbe(controls: diagnostics, identifier: "floating.overlay",
                        value: String(expanded && !layout.usesPopover ? displayed.count : 0))
                }
                #endif
            }
            .onChange(of: items) { _, newItems in
                pageIndex = 0
                if newItems.isEmpty { expanded = false }
            }
            .onKeyPress(.escape) {
                guard expanded else { return .ignored }
                toggle()
                return .handled
            }
        }
    }

    private func tool(_ item: Item, diameter: CGFloat) -> some View {
        content(item)
            .frame(width: diameter, height: diameter)
            .background(.regularMaterial, in: Circle())
            .overlay { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1).allowsHitTesting(false) }
    }

    private func handle(hint: Bool, diameter: CGFloat) -> some View {
        #if os(macOS)
        let target = hint ? min(21, diameter) : diameter
        #else
        // Touch users can always tap the location hint without a hover device.
        let target = diameter
        #endif
        let visible = hint ? min(21, diameter) : diameter
        return Button(action: toggle) {
            Image(systemName: hint ? "ellipsis" : expanded ? "xmark" : "pencil.and.outline")
                .font(.system(size: hint ? 11 : 16, weight: .semibold))
                .foregroundStyle(hint ? Color.secondary : Color.primary)
                .frame(width: visible, height: visible)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1).allowsHitTesting(false) }
                .opacity(hint ? 0.72 : 1)
                .frame(width: target, height: target)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($hubFocused)
        .contextMenu { Button("Customize floating toolbar…", action: customize) }
        .accessibilityAction(named: Text("Customize floating toolbar"), customize)
        .help(items.isEmpty ? "Choose floating toolbar buttons" : expanded ? "Close tools · Drag to move" : "Open tools · Drag to move")
        .accessibilityLabel("Floating toolbar")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(items.isEmpty ? "Choose buttons to add." : "Opens or closes the drawing tools.")
        .accessibilityAction(named: Text("Move left")) { nudge(-0.15, 0) }
        .accessibilityAction(named: Text("Move right")) { nudge(0.15, 0) }
        .accessibilityAction(named: Text("Move up")) { nudge(0, -0.15) }
        .accessibilityAction(named: Text("Move down")) { nudge(0, 0.15) }
    }

    private func toggle() {
        guard !suppressClick else { return }
        guard !items.isEmpty else { customize(); return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.13)) {
            expanded.toggle()
            pageIndex = 0
        }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        anchor = CGPoint(x: min(1, max(0, anchor.x + dx)), y: min(1, max(0, anchor.y + dy)))
    }

    private func drag(_ translation: CGSize, from position: CGPoint, size: CGSize, diameter: CGFloat) {
        if dragOrigin == nil {
            dragOrigin = position
            suppressClick = true
            expanded = false
            pageIndex = 0
        }
        guard let origin = dragOrigin else { return }
        let center = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        dragAnchor = FloatingPageToolbarLayout.normalizedAnchor(for: center, size: size, diameter: diameter)
    }

    private func drop(_ translation: CGSize, size: CGSize, diameter: CGFloat) {
        guard let origin = dragOrigin else { return }
        let center = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        anchor = FloatingPageToolbarLayout.normalizedAnchor(for: center, size: size, diameter: diameter)
        dragAnchor = nil
        dragOrigin = nil
        // SwiftUI can deliver the button's release action after the drag ended.
        DispatchQueue.main.async { suppressClick = false }
    }
}

#if os(macOS)
/// Mounted only by the isolated native fixture. Gestures use these same handlers.
struct FloatingToolbarGestureProbe: NSViewRepresentable {
    let hover: (Bool) -> Void
    let drag: (CGSize) -> Void
    let drop: (CGSize) -> Void

    final class View: NSView {
        var hover: (Bool) -> Void = { _ in }
        var drag: (CGSize) -> Void = { _ in }
        var drop: (CGSize) -> Void = { _ in }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> View {
        let view = View()
        view.setAccessibilityHidden(true)
        return view
    }
    func updateNSView(_ view: View, context: Context) {
        view.hover = hover
        view.drag = drag
        view.drop = drop
    }
}
#endif
