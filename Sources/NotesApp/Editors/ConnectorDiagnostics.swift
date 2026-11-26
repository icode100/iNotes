#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

@MainActor
private final class ConnectorDiagnosticState: ObservableObject {
    @Published var content: PageContent
    @Published var tool = InkTool.diagram
    @Published var fill = false
    @Published var theme = PageTheme.light
    init(_ content: PageContent) { self.content = content }
}

private struct ConnectorDiagnosticEditor: View {
    @ObservedObject var state: ConnectorDiagnosticState
    var body: some View {
        UnifiedPageEditor(text: Binding(get: { state.content.text }, set: { state.content.text = $0 }),
            rtfData: Binding(get: { state.content.rtfData }, set: { state.content.rtfData = $0 }),
            strokes: Binding(get: { state.content.strokes }, set: { state.content.strokes = $0 }),
            pencilKitData: Binding(get: { state.content.pencilKitData }, set: { state.content.pencilKitData = $0 }),
            diagrams: Binding(get: { state.content.diagrams }, set: { state.content.diagrams = $0 }),
            tool: state.tool, colorHex: "#B33755", lineWidth: 2, paper: .blank, theme: state.theme,
            diagramKind: .connector, connectorRoute: .elbow, arrowHeads: .both, diagramFill: state.fill,
            onPageChange: { state.content = $0 },
            onPageValidate: { (try? PageDiagramLimits.validate($0.diagrams)) != nil },
            onObjectPlacement: { state.tool = .select })
    }
}

/// Direct native gestures in an isolated offscreen component. No global events,
/// pointer movement, user clipboard or production library are involved.
@MainActor
enum ConnectorDiagnostics {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws -> Int {
        try autoreleasepool { try runChecks() }
    }

    private static func runChecks() throws -> Int {
        var checks = 0
        func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(description: "Connector diagnostic failed: " + message) }
            checks += 1
        }
        let a = PageDiagram(kind: .rectangle, x: 100, y: 200, width: 260, height: 180, text: "A")
        let b = PageDiagram(kind: .roundedRectangle, x: 700, y: 260, width: 260, height: 180, text: "B")
        let straight = PageDiagram(kind: .connector, colorHex: "#3869B2", lineWidth: 2, text: "Straight",
            startAttachment: PageDiagramAttachment(targetDiagramID: a.id, side: .bottom),
            endAttachment: PageDiagramAttachment(targetDiagramID: b.id, side: .top), arrowHeads: .both)
        let free = PageDiagram(kind: .connector, start: InkPoint(x: 100, y: 700), end: InkPoint(x: 400, y: 700))
        let halfFree = PageDiagram(kind: .connector, text: "One free end", end: InkPoint(x: 500, y: 610),
            startAttachment: PageDiagramAttachment(targetDiagramID: a.id, side: .bottom), route: .elbow)
        let state = ConnectorDiagnosticState(PageContent(text: "Connector preview fixture", diagrams: [a, b, straight, free, halfFree]))
        let host = NSHostingView(rootView: ConnectorDiagnosticEditor(state: state))
        let window = NSWindow(contentRect: NSRect(x: -7500, y: -7200, width: 1100, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.makeFirstResponder(nil); window.orderOut(nil); window.close() }
        func passive() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08)) }
        func findPage(_ view: NSView) -> UnifiedMacPageView? {
            if let page = view as? UnifiedMacPageView { return page }
            return view.subviews.lazy.compactMap { findPage($0) }.first
        }
        host.layoutSubtreeIfNeeded() // Initial offscreen fixture setup only.
        passive()
        guard let page = findPage(host), let controller = page.selectionController,
              let scroll = page.enclosingScrollView else { throw Failure(description: "Missing native connector fixture") }
        scroll.magnification = 1
        let identity = ObjectIdentifier(page), history = controller.history
        history.groupsByEvent = false
        func event(_ type: NSEvent.EventType, _ point: InkPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let location = page.convert(NSPoint(x: point.x, y: point.y), to: nil)
            guard let value = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                throw Failure(description: "Cannot create an app-local connector event")
            }
            return value
        }
        func click(_ point: InkPoint, flags: NSEvent.ModifierFlags = []) throws {
            page.selectionView.mouseDown(with: try event(.leftMouseDown, point, flags: flags))
            page.selectionView.mouseUp(with: try event(.leftMouseUp, point, flags: flags))
        }
        func value(_ id: UUID, in content: PageContent) throws -> PageDiagram {
            guard let result = content.diagrams.first(where: { $0.id == id }) else { throw Failure(description: "Missing connector object") }
            return result
        }
        func same(_ lhs: InkPoint, _ rhs: InkPoint) -> Bool { hypot(lhs.x - rhs.x, lhs.y - rhs.y) < 0.000_001 }
        func shifted(_ point: InkPoint, _ dx: Double, _ dy: Double) -> InkPoint { InkPoint(x: point.x + dx, y: point.y + dy) }

        // These visible edge points are deliberately far from all midpoint
        // ports. Before edge snapping, this produced an apparently connected
        // arrow whose endpoints remained free and static when boxes moved.
        let edgeStart = InkPoint(x: 360, y: 220), edgeEnd = InkPoint(x: 700, y: 420)
        try require(hypot(edgeStart.x - 360, edgeStart.y - 290) > 18,
                    "The edge-attachment fixture lies outside the old midpoint tolerance")
        page.selectionView.mouseDown(with: try event(.leftMouseDown, edgeStart))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, edgeEnd))
        try require(state.content.diagrams.count == 5 && controller.hasPreview,
                    "Native connector creation remains a transient preview")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, edgeEnd)); passive()
        guard let drawn = state.content.diagrams.last else { throw Failure(description: "No native edge connector") }
        try require(drawn.kind == .connector && drawn.startAttachment?.targetDiagramID == a.id
                    && drawn.startAttachment?.side == .right && drawn.endAttachment?.targetDiagramID == b.id
                    && drawn.endAttachment?.side == .left,
                    "Dragging between visible box edges attaches both endpoints")
        try require(controller.editDiagramText(id: drawn.id, text: "Elbow label"), "The connected arrow has a visible label")
        passive()
        let elbow = try value(drawn.id, in: state.content)
        let centerA = InkPoint(x: a.x + a.width / 2, y: a.y + a.height / 2)
        try click(InkPoint(x: 1_000, y: 600))
        try require(controller.selection.isEmpty, "A normal blank click clears the newly placed connector selection")
        try click(InkPoint(x: 430, y: 340))
        try require(controller.selection.diagrams == [straight.id], "The previous connector is selected before direct box pickup")
        history.removeAllActions()
        let before = state.content
        let initialElbowLabel = page.diagramView.labelBounds(of: elbow, in: before.diagrams)
        func checkPreview(_ dx: Double, _ dy: Double, _ phase: String) throws {
            let shown = controller.displayedContent
            try require(state.content == before && controller.hasPreview && page.diagramView.diagrams == shown.diagrams,
                        phase + " renders the transient page without persisting intermediate geometry")
            let shownA = try value(a.id, in: shown)
            try require(abs(shownA.x - a.x - dx) < 0.000_001 && abs(shownA.y - a.y - dy) < 0.000_001,
                        phase + " moves the visible box")
            for original in [straight, elbow, halfFree] {
                let arrow = try value(original.id, in: shown)
                let oldEnds = PageDiagramGeometry.resolvedEndpoints(for: original, in: before.diagrams)
                let newEnds = PageDiagramGeometry.resolvedEndpoints(for: arrow, in: page.diagramView.diagrams)
                try require(same(newEnds.start, shifted(oldEnds.start, dx, dy)) && same(newEnds.end, oldEnds.end),
                            phase + " moves each attached start while preserving the other attached or free end")
                let points = PageDiagramGeometry.connectorPoints(for: arrow, in: page.diagramView.diagrams)
                try require(points.first.map { same($0, newEnds.start) } == true && points.last.map { same($0, newEnds.end) } == true,
                            phase + " supplies live shaft/elbow endpoints to both native arrowheads")
            }
            try require(try value(free.id, in: shown) == free, phase + " preserves deliberate free connectors")
            if let initialElbowLabel, let label = page.diagramView.labelBounds(of: elbow, in: shown.diagrams) {
                try require(abs(label.midX - initialElbowLabel.midX - dx / 2) < 0.000_001
                            && abs(label.midY - initialElbowLabel.midY - dy / 2) < 0.000_001,
                            phase + " projects the visible connector label from the moved endpoints")
            }
        }
        page.selectionView.mouseDown(with: try event(.leftMouseDown, centerA))
        try require(controller.selection.diagrams == [a.id], "Mouse-down picks up a visible box inside the previously selected arrow bounds")
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, shifted(centerA, 50, 40)))
        try checkPreview(50, 40, "First native drag event")
        state.fill.toggle(); passive()
        try require(page.diagramOptions.fill == state.fill && findPage(host).map(ObjectIdentifier.init) == identity,
                    "The mid-drag SwiftUI property update reaches the same native representable")
        try checkPreview(50, 40, "Representable refresh during drag")
        state.theme = .rubyDark; passive()
        try require(page.theme == .rubyDark, "A real mid-drag appearance update reaches the page")
        try checkPreview(50, 40, "Theme refresh during drag")
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, shifted(centerA, 90, 65)))
        try checkPreview(90, 65, "Subsequent native drag event")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, shifted(centerA, 90, 65))); passive()
        let moved = state.content
        try require(!controller.hasPreview && state.content == controller.content && page.diagramView.diagrams == moved.diagrams,
                    "Mouse-up commits exactly the live connected page")
        history.undo(); passive()
        try require(state.content == before && page.diagramView.diagrams == before.diagrams, "One undo restores both boxes and their exact connector graph")
        history.redo(); passive()
        try require(state.content == moved, "Redo restores the committed connected geometry")

        // Resizing the target changes midpoint anchors while shaft, arrowhead
        // directions, elbow legs and labels still use the same preview array.
        let movedA = try value(a.id, in: moved)
        controller.selection = MacPageSelection(diagrams: [a.id])
        let handle = InkPoint(x: movedA.x + movedA.width, y: movedA.y + movedA.height)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, handle))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, shifted(handle, 60, 30)))
        let resizedPreview = controller.displayedContent
        state.fill.toggle(); passive()
        try require(state.content == moved && page.diagramView.diagrams == resizedPreview.diagrams,
                    "A native resize preview survives an actual representable refresh")
        let resizedA = try value(a.id, in: resizedPreview)
        for original in [straight, elbow] {
            let arrow = try value(original.id, in: resizedPreview)
            let ends = PageDiagramGeometry.resolvedEndpoints(for: arrow, in: page.diagramView.diagrams)
            try require(same(ends.start, PageDiagramGeometry.anchorPoint(on: resizedA, side: original.startAttachment!.side)),
                        "Native resizing projects each connected start at the new target border")
        }
        page.selectionView.mouseUp(with: try event(.leftMouseUp, shifted(handle, 60, 30))); passive()
        let resized = state.content
        history.undo(); passive(); try require(state.content == moved, "Resize undo restores exact connected snapshots")
        history.redo(); passive(); try require(state.content == resized, "Resize redo restores exact connected snapshots")

        controller.perform(.clear)
        let centerB = InkPoint(x: b.x + b.width / 2, y: b.y + b.height / 2)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, centerB))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, shifted(centerB, 25, 35)))
        let targetPreview = controller.displayedContent
        let oldTargetEnds = PageDiagramGeometry.resolvedEndpoints(for: elbow, in: resized.diagrams)
        let newTargetEnds = PageDiagramGeometry.resolvedEndpoints(for: elbow, in: page.diagramView.diagrams)
        try require(controller.selection.diagrams == [b.id] && state.content == resized
                    && same(newTargetEnds.start, oldTargetEnds.start) && same(newTargetEnds.end, shifted(oldTargetEnds.end, 25, 35))
                    && (try value(free.id, in: targetPreview)) == free,
                    "Direct pickup from an empty selection moves the opposite attached end live without moving free arrows")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, shifted(centerB, 25, 35))); passive()
        let movedTarget = state.content
        history.undo(); passive(); try require(state.content == resized, "Opposite-target movement has one exact undo")
        history.redo(); passive(); try require(state.content == movedTarget, "Opposite-target redo restores the endpoint projection")
        history.undo(); passive()

        // Moving both targets must move both ends; unselected free arrows stay
        // at their original world coordinates. No connector payload is rewritten.
        let currentA = try value(a.id, in: resized), currentB = try value(b.id, in: resized)
        let groupStart = InkPoint(x: currentA.x + currentA.width / 2, y: currentA.y + currentA.height / 2)
        try click(groupStart)
        try click(InkPoint(x: currentB.x + currentB.width / 2, y: currentB.y + currentB.height / 2), flags: .shift)
        try require(controller.selection.diagrams == [a.id, b.id], "Actual Shift-click selects both target boxes")
        page.selectionView.mouseDown(with: try event(.leftMouseDown, groupStart))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, shifted(groupStart, 30, 25)))
        let groupPreview = controller.displayedContent
        let oldEnds = PageDiagramGeometry.resolvedEndpoints(for: elbow, in: resized.diagrams)
        let groupEnds = PageDiagramGeometry.resolvedEndpoints(for: elbow, in: page.diagramView.diagrams)
        try require(same(groupEnds.start, shifted(oldEnds.start, 30, 25)) && same(groupEnds.end, shifted(oldEnds.end, 30, 25))
                    && (try value(free.id, in: groupPreview)) == free && state.content == resized,
                    "Dragging both target boxes updates both arrow ends while leaving free endpoints alone")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, shifted(groupStart, 30, 25))); passive()
        let grouped = state.content
        history.undo(); passive(); try require(state.content == resized, "Group movement undoes both target projections together")
        history.redo(); passive(); try require(state.content == grouped, "Group redo retains attachment IDs and free geometry")

        // An old free arrow only acquires a target after the user's explicit
        // endpoint gesture, including a visible edge outside midpoint tolerance.
        controller.selection = MacPageSelection(diagrams: [free.id])
        let finalA = try value(a.id, in: grouped)
        let edge = InkPoint(x: finalA.x, y: finalA.y + 25)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, free.end))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, edge))
        let reconnected = try value(free.id, in: controller.displayedContent)
        try require(state.content == grouped && reconnected.endAttachment?.targetDiagramID == a.id
                    && reconnected.endAttachment?.side == .left && reconnected.startAttachment == nil,
                    "Explicit endpoint drag attaches an old free end at a visible box border")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, edge)); passive()
        let attached = state.content
        history.undo(); passive(); try require(state.content == grouped, "Reattachment undo restores the deliberately free arrow")
        history.redo(); passive(); try require(state.content == attached, "Reattachment redo restores only the chosen attachment")
        var library = NoteLibrary.sample()
        guard var sheet = library.nodes.first(where: { $0.kind == .sheet }) else { throw Failure(description: "No connector persistence sheet") }
        sheet.pageContent = attached
        try library.update(sheet)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-connectors-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(url: directory.appendingPathComponent("Library.json"))
        try repository.save(library)
        try require(try repository.load()?.node(id: sheet.id)?.pageContent == attached,
                    "Save/reopen preserves connected endpoints, labels, routes and free-end semantics")

        controller.selection = MacPageSelection(diagrams: [elbow.id])
        let inspector = MacDiagramSelectionStyle()
        controller.diagramSelectionStyle = inspector
        inspector.bind(controller)
        passive()
        try require(inspector.editableConnector?.id == elbow.id, "The arrow-style control binds to the selected connector")
        var style = ConnectorAppearance(elbow)
        style.heads = .both; style.route = .straight; style.openHeads = true
        style.width = 4; style.pattern = .dashed; style.color = "#177E89"
        try require(inspector.apply(style, to: elbow.id), "Apply commits changes to the connector in one edit")
        passive()
        let styledPage = state.content
        let styled = try value(elbow.id, in: styledPage)
        try require(ConnectorAppearance(styled) == style && styled.startAttachment == elbow.startAttachment
            && styled.endAttachment == elbow.endAttachment && styled.text == elbow.text,
            "Appearance edits preserve both anchors and the arrow label")
        try require(history.undoActionName == "Change Arrow Style", "The style edit is one named undo action")
        history.undo(); passive()
        try require(state.content == attached, "Undo restores the exact previous connector and page")
        history.redo(); passive()
        try require(state.content == styledPage, "Redo restores all selected style attributes together")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try require(controller.copySelection(to: board), "Copy the styled arrow to an isolated pasteboard")
        let v5Type = NSPasteboard.PasteboardType(PageClipboardPayload.styledDiagramPasteboardType)
        guard let bytes = board.data(forType: v5Type) else { throw Failure(description: "Missing version 5 styled diagram payload") }
        try require(board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.pasteboardType)) == nil
            && (try PageClipboardPayload.decodeValidated(bytes)).diagrams.first?.openArrowheads == true,
            "A styled arrow round-trips on the native clipboard using its compatible type")
        sheet.pageContent = styledPage
        try library.update(sheet)
        try repository.save(library)
        let reopened = try repository.load()
        try require(reopened?.formatVersion == 5 && reopened?.node(id: sheet.id)?.pageContent == styledPage,
                    "Styled arrows retain the selected appearance after saving and reopening")
        controller.selection = MacPageSelection(diagrams: [straight.id])
        var routing = ConnectorAppearance(straight)
        try require(routing.attachmentSides == .fixed, "Earlier connectors retain the sides originally chosen")
        routing.attachmentSides = .automatic
        try require(inspector.apply(routing, to: straight.id), "An existing connector can opt into automatic sides")
        let rerouted = try value(straight.id, in: state.content)
        try require(rerouted.startAttachment?.side == .right && rerouted.endAttachment?.side == .left
                    && rerouted.startAttachment?.followsTarget == true && rerouted.endAttachment?.followsTarget == true,
                    "Applying Automatic immediately repositions an existing arrow between facing edges")
        try require(state.content.diagrams.filter { $0.id != straight.id } == styledPage.diagrams.filter { $0.id != straight.id },
                    "Changing attachment sides preserves every other page object")
        routing.attachmentSides = .fixed
        try require(inspector.apply(routing, to: straight.id), "The visible pair of ports can be pinned")
        let pinned = try value(straight.id, in: state.content)
        try require(pinned.startAttachment?.side == .right && pinned.endAttachment?.side == .left
                    && pinned.startAttachment?.followsTarget == nil && pinned.endAttachment?.followsTarget == nil,
                    "Pinning a routed arrow retains its current points of attachment")
        history.undo(); passive()
        try require(try value(straight.id, in: state.content) == rerouted, "One undo restores the automatic attachments")
        history.undo(); passive()
        try require(state.content == styledPage, "Undoing adoption restores the original fixed sides exactly")
        controller.selection = MacPageSelection(diagrams: [a.id])
        try require(!inspector.apply(style, to: elbow.id), "An inspector cannot alter an arrow after selection changed")
        print("Connector native checks passed: \(checks) (real drag/resize previews, representable updates, edge snapping, free ends, undo and persistence)")
        return checks
    }
}
#endif
