#if os(macOS)
import AppKit
import NotesCore

@MainActor
enum QuickAddDiagnostics {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws -> Int {
        try autoreleasepool {
            var checks = 0
            func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
                guard value() else { throw Failure(description: "Connected object check failed: " + message) }
                checks += 1
            }
            let window = NSWindow(contentRect: NSRect(x: -8600, y: -7900, width: 980, height: 740),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 980, height: 740))
            let page = UnifiedMacPageView(frame: CGRect(origin: .zero, size: InkExport.paperSize))
            scroll.documentView = page
            window.contentView = scroll
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            let controller = MacPageSelectionController()
            controller.page = page
            page.selectionController = controller
            page.selectionView.controller = controller
            page.inkView.isInputEnabled = true
            guard let quick = page.quickAdd else { throw Failure(description: "No quick-add control on the editable page") }
            let box = PageDiagram(kind: .rectangle, x: 100, y: 160, width: 160, height: 100, text: "Start")
            let blocking = PageDiagram(kind: .table, x: 295, y: 140, width: 300, height: 160)
            let second = PageDiagram(kind: .ellipse, x: 700, y: 180, width: 130, height: 100)
            let arrow = PageDiagram(kind: .connector, colorHex: "#3869B2", linePattern: .dashed,
                startAttachment: .init(targetDiagramID: box.id, side: .right),
                endAttachment: .init(targetDiagramID: second.id, side: .left), route: .elbow, arrowHeads: .both)
            let free = PageDiagram(kind: .connector, colorHex: "#A62D42", linePattern: .dotted,
                                   start: InkPoint(x: 60, y: 460), end: InkPoint(x: 130, y: 535), arrowHeads: .both)
            // Reusing IDs across object types is legal. Each menu and anchor
            // must identify the actual source type as well as its UUID.
            let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
            let image = PageImage(id: box.id, x: 400, y: 405, width: 70, height: 60, imageData: redPNG)
            let text = PageTextBox(id: box.id, x: 515, y: 405, width: 140, text: "Text box")
            let equation = NoteEquation(id: box.id, latex: "a+b", x: 700, y: 405, width: 120, height: 60)
            let base = PageContent(text: "Preserve this body", textBoxes: [text], equations: [equation],
                                   images: [image], diagrams: [box, blocking, second, arrow, free])
            var saved = base
            controller.history.groupsByEvent = false
            controller.onCommit = { saved = $0 }
            @MainActor func render(_ content: PageContent) {
                page.displayObjects(textBoxes: content.textBoxes, equations: content.equations, images: content.images,
                                    diagrams: content.diagrams, editable: true, onTextBoxChange: { _, _, _ in }, onEquationEdit: nil)
                page.resizePaperToContent()
            }
            controller.onRender = render
            controller.load(base)
            render(base)
            let center = CGPoint(x: box.x + 30, y: box.y + 30)
            page.scrollToVisible(CGRect(x: 0, y: 0, width: 900, height: 690))
            for tool in [InkTool.pen, .text, .select, .lasso, .diagram] {
                page.activeTool = tool
                let ordinary = page.inputView(at: center, event: nil)
                guard let tracking = page.trackingAreas.first(where: { $0.owner === quick }),
                      let mouse = NSEvent.mouseEvent(with: .mouseMoved, location: page.convert(center, to: nil),
                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                          clickCount: 0, pressure: 0) else { throw Failure(description: "Missing local hover event or tracking area") }
                try check(NSApp.sendAction(NSSelectorFromString("mouseMoved:"), to: tracking.owner, from: mouse)
                          && quick.source == QuickAddSource(id: box.id) && !quick.button.isHidden, "Actual page hover exposes + in " + tool.rawValue)
                try check(page.inputView(at: center, event: nil) === ordinary && page.activeTool == tool,
                          "Hover preserves ordinary input in " + tool.rawValue)
                let plus = CGPoint(x: quick.button.frame.midX, y: quick.button.frame.midY)
                try check(page.inputView(at: plus, event: nil) === quick.button, "Only + receives its own click")
                quick.track(plus)
                try check(quick.source == QuickAddSource(id: box.id), "The button remains reachable after crossing the edge")
                quick.track(CGPoint(x: 20, y: 40))
                try check(quick.button.isHidden, "Hovering blank paper hides +")
            }
            page.activeTool = .pen
            page.diagramOptions.fill = true
            page.diagramOptions.route = .elbow
            page.diagramOptions.rows = 2
            page.diagramOptions.columns = 4
            page.inkView.linePattern = .dashed
            page.inkView.colorHex = "#7852A9"
            page.inkView.lineWidth = 3
            let menu = quick.menu(for: QuickAddSource(id: box.id))
            try check(menu.items.map(\.title) == ["Rectangle", "Rounded rectangle", "Ellipse", "Triangle", "Diamond", "Table"],
                      "The native picker offers all closed shapes and tables")
            for (i, kind) in [PageDiagram.Kind.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond, .table].enumerated() {
                menu.performActionForItem(at: i)
                let added = Array(saved.diagrams.dropFirst(base.diagrams.count))
                guard added.count == 2 else { throw Failure(description: "Menu did not insert a connected " + kind.rawValue) }
                let object = added[0], link = added[1]
                try check(object.kind == kind && object.fill && (kind != .table || object.rows == 2 && object.columns == 4),
                          "Menu inserts requested object with creation defaults")
                try check(link.kind == .connector && link.arrowHeads == .end && link.route == .elbow && link.linePattern == .dashed
                          && link.colorHex == "#7852A9" && link.startAttachment?.targetDiagramID == box.id
                          && link.endAttachment?.targetDiagramID == object.id, "New connectors carry a single head and real live anchors")
                let rect = PageDiagramGeometry.bounds(of: object, in: saved.diagrams)
                try check([box, blocking, second].allSatisfy { !PageDiagramGeometry.bounds(of: $0, in: saved.diagrams).intersects(rect) }
                          && rect.minX >= 0 && rect.maxX <= page.bounds.width, "Placement avoids existing shapes and page edges")
                let result = saved
                try check(controller.selection.diagrams == [object.id] && page.activeTool == .select,
                          "The connected object is selected with single-placement semantics")
                controller.history.undo()
                try check(saved == base, "One undo restores the complete input page")
                controller.history.redo()
                try check(saved == result, "Redo preserves every ID, anchor and style")
                controller.history.undo()
            }
            try check(controller.addConnectedObject(from: QuickAddSource(id: arrow.id), kind: .ellipse)
                      && saved.diagrams.last?.startAttachment?.targetDiagramID == second.id
                      && saved.diagrams.first(where: { $0.id == arrow.id }) == arrow, "Branch from the destination of an attached arrow")
            controller.history.undo()
            try check(controller.addConnectedObject(from: QuickAddSource(id: free.id), kind: .triangle)
                      && saved.diagrams.count == base.diagrams.count + 1, "Extend a free-ended arrow in place")
            let extended = saved.diagrams.first { $0.id == free.id }
            try check(extended?.endAttachment?.targetDiagramID == saved.diagrams.last?.id && extended?.start == free.start
                      && extended?.linePattern == free.linePattern && extended?.arrowHeads == free.arrowHeads, "Completing an arrow preserves its custom style")
            controller.history.undo()
            for source in [QuickAddSource(id: image.id, kind: .image), QuickAddSource(id: text.id, kind: .textBox),
                           QuickAddSource(id: equation.id, kind: .equation)] {
                guard let frame = source.frame(on: page) else { throw Failure(description: "Missing external target view") }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                page.activeTool = .text
                page.scrollToVisible(frame.insetBy(dx: -30, dy: -30))
                let input = page.inputView(at: center, event: nil)
                quick.track(center)
                try check(quick.source == source && !quick.button.isHidden && page.inputView(at: center, event: nil) === input,
                          "Hover recognizes the precise external object while preserving native text input")
                quick.menu(for: source).performActionForItem(at: 0)
                guard let link = saved.diagrams.last, let start = link.startAttachment else {
                    throw Failure(description: "External quick-add produced no attached arrow")
                }
                try check(start.targetKind == source.kind && start.targetDiagramID == source.id &&
                          link.start == PageDiagramGeometry.anchorPoint(in: frame, side: start.side) &&
                          link.endAttachment?.targetDiagramID == saved.diagrams.dropLast().last?.id,
                          "Quick-add uses the typed source and its measured frame despite colliding UUIDs")
                let result = saved
                controller.history.undo()
                try check(saved == base, "External quick-add is one undo transaction")
                controller.history.redo()
                try check(saved == result, "External quick-add redo preserves the live typed endpoint")
                controller.history.undo()

                // Drive the existing native endpoint handle, including its
                // transient projection and atomic mouse-up commit.
                page.activeTool = .select
                controller.selection = MacPageSelection(diagrams: [free.id])
                let destination = InkPoint(x: frame.minX, y: frame.midY)
                func endpointEvent(_ type: NSEvent.EventType, at position: InkPoint) throws -> NSEvent {
                    let location = page.convert(CGPoint(x: position.x, y: position.y), to: nil)
                    guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
                    else { throw Failure(description: "No local connector handle event") }
                    return event
                }
                page.selectionView.mouseDown(with: try endpointEvent(.leftMouseDown, at: free.end))
                page.selectionView.mouseDragged(with: try endpointEvent(.leftMouseDragged, at: destination))
                let preview = controller.displayedContent.diagrams.first { $0.id == free.id }
                try check(saved == base && preview?.endAttachment?.targetKind == source.kind &&
                          preview?.endAttachment?.targetDiagramID == source.id && preview?.endAttachment?.side == .left,
                          "Dragging an existing arrow endpoint onto an external object previews its typed attachment")
                page.selectionView.mouseUp(with: try endpointEvent(.leftMouseUp, at: destination))
                try check(saved.diagrams.first { $0.id == free.id } == preview && preview?.end == destination,
                          "Mouse-up saves the projected port and its live external target")
                controller.history.undo()
                try check(saved == base, "Reconnecting the arrow undoes in one step")
            }
            page.inkView.isInputEnabled = false
            quick.track(center)
            try check(quick.button.isHidden && !controller.addConnectedObject(from: QuickAddSource(id: box.id), kind: .ellipse)
                      && saved == base, "Trashed pages reject quick insertion")
            page.inkView.isInputEnabled = true
            controller.onValidate = { _ in false }
            try check(!controller.addConnectedObject(from: QuickAddSource(id: box.id), kind: .ellipse) && saved == base && !controller.history.canUndo,
                      "Rejected insertion preserves content and the active history")
            try check(!controller.addConnectedObject(from: QuickAddSource(id: UUID()), kind: .rectangle), "Stale menu items cannot add an orphan")
            checks += try facingPortChecks(on: page, controller: controller, quick: quick, window: window)
            checks += try clipboardChecks(on: page, controller: controller, base: base)
            return checks
        }
    }

    private static func facingPortChecks(on page: UnifiedMacPageView, controller: MacPageSelectionController,
                                         quick: MacDiagramQuickAdd, window: NSWindow) throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(description: "Moving a Quick Add child: " + message) }
            checks += 1
        }
        @MainActor func event(_ type: NSEvent.EventType, _ point: InkPoint) throws -> NSEvent {
            let location = page.convert(CGPoint(x: point.x, y: point.y), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
            else { throw Failure(description: "Missing native shape move event") }
            return event
        }
        let parent = PageDiagram(kind: .roundedRectangle, x: 375, y: 160, width: 160, height: 100)
        var saved = PageContent(diagrams: [parent])
        controller.onValidate = nil
        controller.onCommit = { saved = $0 }
        controller.load(saved); controller.onRender?(saved)
        controller.history.removeAllActions()
        page.diagramOptions.route = .straight
        page.inkView.colorHex = "#E63218"
        page.inkView.linePattern = .solid
        page.inkView.lineWidth = 4
        page.scrollToVisible(CGRect(x: 0, y: 0, width: 900, height: 690))
        quick.track(CGPoint(x: 455, y: 210))
        try check(quick.source == QuickAddSource(id: parent.id) && !quick.button.isHidden, "Native hover exposes + on the rounded parent")
        guard let source = quick.source else { throw Failure(description: "Missing rounded parent hover") }
        quick.menu(for: source).performActionForItem(at: 0)
        guard let child = saved.diagrams.first(where: { $0.kind == .rectangle }),
              let automatic = saved.diagrams.first(where: { $0.kind == .connector })
        else { throw Failure(description: "Rectangle menu did not create both objects") }
        try check(child.x > parent.x + parent.width && automatic.startAttachment?.targetDiagramID == parent.id
                  && automatic.endAttachment?.targetDiagramID == child.id, "The + creates a right-hand rectangle and connects it")

        // A second arrow between the very same objects is drawn explicitly
        // from top to left. Only the Quick Add arrow should switch ports.
        page.activeTool = .diagram
        page.diagramOptions.kind = .connector
        page.inkView.colorHex = "#2046C5"
        page.inkView.lineWidth = 1
        let parentTop = PageDiagramGeometry.anchorPoint(on: parent, side: .top)
        let childLeft = PageDiagramGeometry.anchorPoint(on: child, side: .left)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, parentTop))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, childLeft))
        page.selectionView.mouseUp(with: try event(.leftMouseUp, childLeft))
        guard let manual = saved.diagrams.last, manual.kind == .connector, manual.id != automatic.id
        else { throw Failure(description: "No manually drawn comparison arrow") }
        try check(manual.startAttachment?.side == .top && manual.endAttachment?.side == .left,
                  "An explicit port-to-port gesture attaches the comparison arrow")
        let original = saved
        func center(_ object: PageDiagram) -> InkPoint {
            InkPoint(x: object.x + object.width / 2, y: object.y + object.height / 2)
        }
        @MainActor func checkView(_ from: PageDiagram.AnchorSide, _ to: PageDiagram.AnchorSide, at point: InkPoint) throws {
            let shown = page.diagramView.diagrams
            guard let moved = shown.first(where: { $0.id == child.id }),
                  let link = shown.first(where: { $0.id == automatic.id }),
                  let fixed = shown.first(where: { $0.id == manual.id }) else { throw Failure(description: "Missing visible diagram") }
            let start = PageDiagramGeometry.anchorPoint(on: parent, side: from)
            let end = PageDiagramGeometry.anchorPoint(on: moved, side: to)
            let expected = PageDiagramGeometry.resolvedEndpoints(for: link, in: shown)
            try check(center(moved) == point && expected.start == start && expected.end == end,
                      "The visible parent and child use their facing ports, " + from.rawValue + " and " + to.rawValue)
            let pinned = PageDiagramGeometry.resolvedEndpoints(for: fixed, in: shown)
            try check(pinned.start == parentTop && pinned.end == PageDiagramGeometry.anchorPoint(on: moved, side: .left),
                      "The manual arrow remains on the chosen top and left edges throughout the move")
            // Render just a small patch in the gap, close to the child's facing
            // port. The obsolete side-to-side shaft misses this patch on a move.
            let sample = CGPoint(x: end.x + (start.x - end.x) * 0.3, y: end.y + (start.y - end.y) * 0.3)
            try check(try arrowIsDrawn(on: page.diagramView, at: sample), "The red arrow is visibly drawn approaching the facing port")
        }
        var previous = center(child)
        try checkView(.right, .left, at: previous)
        let positions: [(InkPoint, PageDiagram.AnchorSide, PageDiagram.AnchorSide)] = [
            (InkPoint(x: 455, y: 540), .bottom, .top), (InkPoint(x: 140, y: 210), .left, .right)
        ]
        var checkpoints = [original]
        for (target, from, to) in positions {
            let before = saved
            controller.selection = MacPageSelection(diagrams: [child.id])
            page.selectionView.mouseDown(with: try event(.leftMouseDown, previous))
            page.selectionView.mouseDragged(with: try event(.leftMouseDragged, target))
            try check(controller.hasPreview && saved == before, "Native drag shows the child before committing")
            try checkView(from, to, at: target)
            page.selectionView.mouseUp(with: try event(.leftMouseUp, target))
            try check(!controller.hasPreview && saved != before && saved == controller.content, "Mouse-up commits the move")
            try checkView(from, to, at: target)
            checkpoints.append(saved)
            previous = target
        }
        controller.history.undo()
        try check(saved == checkpoints[1], "Undo restores the exact lower placement")
        try checkView(.bottom, .top, at: positions[0].0)
        controller.history.undo()
        try check(saved == original, "A second Undo restores the original right-hand placement")
        try checkView(.right, .left, at: center(child))
        controller.history.redo(); controller.history.redo()
        try check(saved == checkpoints[2], "Redo restores both edits and the original connector identities")
        try checkView(.left, .right, at: positions[1].0)

        controller.selection = MacPageSelection(diagrams: [automatic.id])
        guard let copy = controller.clipboardPayload()?.diagrams.first,
              let finalChild = saved.diagrams.first(where: { $0.id == child.id }) else { throw Failure(description: "Missing arrow-only copy") }
        try check(copy.startAttachment == nil && copy.endAttachment == nil &&
                  copy.start == PageDiagramGeometry.anchorPoint(on: parent, side: .left) &&
                  copy.end == PageDiagramGeometry.anchorPoint(on: finalChild, side: .right),
                  "Copying just the arrow uses its final visible ports as free endpoints")
        var library = NoteLibrary.sample()
        guard var node = library.nodes.first(where: { $0.kind == .sheet }) else { throw Failure(description: "No sample page") }
        node.pageContent = saved
        try library.update(node)
        let reopened = try LibraryArchive.decode(LibraryArchive.encode(library))
        try check(reopened.node(id: node.id)?.pageContent == saved, "Archive round-trip preserves both automatic and manually attached arrows")
        return checks
    }

    private static func arrowIsDrawn(on view: MacPageDiagramView, at point: CGPoint) throws -> Bool {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 9, pixelsHigh: 9,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw Failure(description: "Cannot render native arrow sample") }
        let patch = NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 9, height: 9))
        graphics.cgContext.translateBy(x: -patch.minX, y: -patch.minY)
        view.draw(patch)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        for y in 2...6 {
            for x in 2...6 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.7,
                   color.redComponent > color.blueComponent + 0.3 && color.redComponent > color.greenComponent + 0.3 { return true }
            }
        }
        return false
    }

    private static func clipboardChecks(on page: UnifiedMacPageView, controller: MacPageSelectionController,
                                        base: PageContent) throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(description: "Connected clipboard check failed: " + message) }
            checks += 1
        }
        let image = base.images[0], box = base.textBoxes[0], equation = base.equations[0]
        let a = PageDiagram(kind: .connector, text: "image → box",
            startAttachment: .init(targetDiagramID: image.id, side: .right, targetKind: .image),
            endAttachment: .init(targetDiagramID: box.id, side: .left, targetKind: .textBox))
        let b = PageDiagram(kind: .connector, text: "equation → image",
            startAttachment: .init(targetDiagramID: equation.id, side: .top, targetKind: .equation),
            endAttachment: .init(targetDiagramID: image.id, side: .bottom, targetKind: .image))
        var original = base
        original.diagrams += [a, b]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-connected-clipboard-" + UUID().uuidString)
        let key = "iNotes-connected-clipboard-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key); try? FileManager.default.removeItem(at: folder) }
        let store = NotesStore(directory: folder, preferences: defaults)
        guard let pageID = store.selectedSheet?.id else { throw Failure(description: "No temporary clipboard page") }
        store.update(pageID) { $0.pageContent = original }
        @MainActor func saved() -> PageContent? { store.library.node(id: pageID)?.pageContent }
        controller.onValidate = { store.validatePageChange(pageID, content: $0) }
        controller.onCommit = { candidate in store.update(pageID) { $0.pageContent = candidate } }
        controller.load(original); controller.onRender?(original)
        controller.history.removeAllActions()
        page.activeTool = .select
        controller.selection = MacPageSelection(diagrams: [a.id])
        guard let only = controller.clipboardPayload()?.diagrams.first, let visible = page.diagramView.diagrams.first(where: { $0.id == a.id }) else {
            throw Failure(description: "Missing native arrow-only copy")
        }
        try check(only.startAttachment == nil && only.endAttachment == nil && only.start == visible.start && only.end == visible.end
                  && visible.start != a.start && visible.end != a.end, "Copying an arrow alone detaches it at the displayed world coordinates")
        let group = MacPageSelection(textBoxes: [box.id], equations: [equation.id], images: [image.id], diagrams: [a.id, b.id])
        controller.selection = group
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try check(controller.copySelection(to: board), "Copy to a private pasteboard accepts mixed typed targets")
        guard let data = board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.styledDiagramPasteboardType)) else {
            throw Failure(description: "No compatible clipboard data for live object links")
        }
        let payload = try PageClipboardPayload.decodeValidated(data)
        try check(payload.images == [image] && payload.textBoxes == [box] && payload.equations == [equation]
                  && payload.diagrams.count == 2 && board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.pasteboardType)) == nil,
                  "The typed clipboard retains all three sources and only advertises the compatible page format")
        for duplicate in [false, true] {
            controller.selection = group
            if duplicate { controller.perform(.duplicate) }
            else { try check(controller.paste(payload, offset: 20, action: "Paste Selection"), "The decoded mixed group pastes") }
            guard let value = saved(), let newImage = value.images.last, let newBox = value.textBoxes.last,
                  let newEquation = value.equations.last else { throw Failure(description: "Mixed group lost a source") }
            let arrows = Array(value.diagrams.suffix(2))
            try check(value.diagrams.count == original.diagrams.count + 2 && arrows[0].startAttachment == .init(targetDiagramID: newImage.id, side: .right, targetKind: .image)
                      && arrows[0].endAttachment == .init(targetDiagramID: newBox.id, side: .left, targetKind: .textBox)
                      && arrows[1].startAttachment == .init(targetDiagramID: newEquation.id, side: .top, targetKind: .equation)
                      && arrows[1].endAttachment == .init(targetDiagramID: newImage.id, side: .bottom, targetKind: .image)
                      && Set([newImage.id, newBox.id, newEquation.id, image.id]).count == 4,
                      "Paste and Duplicate each reconnect exclusively to their fresh typed targets")
            controller.perform(.delete)
            try check(saved() == original, "Deleting the duplicated group leaves original stored links and content byte-for-byte equivalent")
            controller.history.undo()
            try check(saved() == value, "Native Undo restores every pasted target ID and both arrows")
            controller.history.undo()
            try check(saved() == original, "Undo of the original insertion restores the source snapshot")
        }
        controller.selection = MacPageSelection(images: [image.id])
        controller.perform(.delete)
        guard let remaining = saved(), let detachedA = remaining.diagrams.first(where: { $0.id == a.id }),
              let detachedB = remaining.diagrams.first(where: { $0.id == b.id }) else { throw Failure(description: "Target deletion removed the arrows") }
        try check(detachedA.startAttachment == nil && detachedA.start == visible.start && detachedA.endAttachment == a.endAttachment &&
                  detachedB.endAttachment == nil && detachedB.startAttachment == b.startAttachment && remaining.textBoxes == [box]
                  && remaining.equations == [equation], "Deleting only the image detaches only its typed ends despite identical cross-type UUIDs")
        controller.history.undo()
        controller.selection = group
        let undoName = controller.history.undoActionName
        store.trash(pageID)
        try check(!controller.paste(payload, offset: 20, action: "Paste Selection") && saved() == original && controller.selection == group
                  && controller.history.undoActionName == undoName, "The real store rejects a delayed paste after its page enters Trash with atomic history and content")
        _ = store.flush()
        return checks
    }
}
#endif
