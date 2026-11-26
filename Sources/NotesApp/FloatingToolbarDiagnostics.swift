#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

@MainActor
enum FloatingToolbarDiagnostics {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw WorkspaceDiagnostics.Failure(description: "Floating toolbar: " + message) }
            checks += 1
        }
        func wait(_ message: String, until condition: () -> Bool) throws {
            let deadline = Date(timeIntervalSinceNow: 5)
            repeat {
                RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.016)))
            } while !condition() && Date() < deadline
            try check(condition(), message)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-floating-\(UUID())")
        let suite = "io.inotes.floating-toolbar-checks.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw WorkspaceDiagnostics.Failure(description: "Missing isolated floating toolbar defaults")
        }
        defaults.set("text", forKey: "inkTool")
        defaults.set(0.56, forKey: "floatingToolbarAnchorX")
        defaults.set(0.55, forKey: "floatingToolbarAnchorY")
        let store = NotesStore(directory: directory, preferences: defaults)
        defer {
            _ = store.prepareForQuit()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        guard let pageID = store.selectedSheet?.id else { throw WorkspaceDiagnostics.Failure(description: "Missing disposable floating toolbar page") }
        let seed = "Toolbar fixture", suffix = " edited"
        store.update(pageID) { $0.body = seed; $0.richTextRTF = nil }
        _ = NSApplication.shared
        let controls = WorkspaceDiagnosticControls()
        let presentation = EditorPresentation()
        let host = NSHostingController(rootView: ContentView(presentation: presentation)
            .environmentObject(store).environmentObject(InputDeviceMonitor())
            .environment(\.workspaceDiagnosticControls, controls).defaultAppStorage(defaults))
        let rect = NSRect(x: -6400, y: -6200, width: 1150, height: 800)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        window.setFrame(rect, display: false)
        defer {
            controls.removeAll()
            window.orderOut(nil)
            window.close()
        }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let result = view as? T, result.window === window, !result.isHiddenOrHasHiddenAncestor { return result }
            for child in view.subviews { if let result = find(type, in: child) { return result } }
            return nil
        }
        func button(_ id: String) -> WorkspaceDiagnosticControls.Control? { controls.control(id) }
        func frame(_ id: String) -> CGRect? { button(id)?.frame(in: host.view) }
        func visible(_ id: String) -> Bool { frame(id).map { !$0.isEmpty } == true }
        func press(_ id: String) throws {
            try wait("\(id) is mounted and enabled") { visible(id) && button(id)?.isEnabled == true }
            try check(button(id)?.perform() == true, "\(id) executes its mounted button action")
        }
        func openRing() throws {
            if !visible("floating.pen") { try press("floating.bubble") }
            try wait("opening the ring exposes Pen and both history controls") {
                visible("floating.pen") && visible("floating.undo") && visible("floating.redo")
            }
        }
        try wait("windowed page starts with the docked toolbar") {
            visible("page.history.undo") && find(UnifiedMacPageView.self, in: host.view) != nil
        }
        guard let page = find(UnifiedMacPageView.self, in: host.view), let scroll = page.enclosingScrollView,
              let manager = page.textView.undoManager else { throw WorkspaceDiagnostics.Failure(description: "Missing native floating toolbar page") }
        let editor = page.textView
        try check(!visible("floating.bubble") && window.makeFirstResponder(editor), "windowed text can take focus before any preference change")
        editor.setSelectedRange(NSRange(location: (seed as NSString).length, length: 0))
        editor.breakUndoCoalescing()
        manager.beginUndoGrouping()
        editor.insertText(suffix, replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        manager.endUndoGrouping()
        try wait("native typing creates the page's undo action") { store.selectedSheet?.body == seed + suffix && manager.canUndo }
        let caret = editor.selectedRange()
        scroll.setMagnification(1.18, centeredAt: CGPoint(x: page.visibleRect.midX, y: page.visibleRect.midY))
        let zoom = scroll.magnification
        func checkPage(_ context: String) throws {
            try check(find(UnifiedMacPageView.self, in: host.view) === page && page.textView === editor &&
                      page.textView.undoManager === manager && store.sheetID == pageID &&
                      abs(scroll.magnification - zoom) < 0.001, context + " keeps the same editor, page, history and zoom")
        }
        presentation.fullPage = true
        try wait("Docked is the fresh full-page default after native navigation settles") {
            find(WorkspaceNavigationProbe.self, in: host.view)?.diagnosticsSnapshot().isQuiescent(
                expectedFullPage: true, expectedSheetsVisible: presentation.sheetsVisible) == true &&
                visible("page.history.undo") && !visible("floating.bubble")
        }
        defaults.set("floating", forKey: "fullScreenToolbarMode")
        try wait("Floating replaces the docked controls in full-page mode") { visible("floating.bubble") && !visible("page.history.undo") }
        try check(editor.selectedRange() == caret && manager.canUndo && editor.string == seed + suffix,
                  "switching to floating preserves the text caret, body and undo action")
        try openRing()
        try press("floating.undo")
        try wait("floating Undo updates native and saved text") { editor.string == seed && store.selectedSheet?.body == seed && manager.canRedo }
        try openRing()
        try press("floating.redo")
        try wait("floating Redo returns the native edit") { editor.string == seed + suffix && store.selectedSheet?.body == seed + suffix && manager.canUndo }
        try openRing()
        try press("floating.pen")
        try wait("floating Pen changes the mounted page's input owner") { page.activeTool == .pen && !editor.isEditable }
        try openRing()
        try checkPage("Ring tool changes")

        guard let overlay = frame("floating.overlay"), let bubble = frame("floating.bubble"),
              let count = button("floating.overlay")?.value.flatMap(Int.init), count > 0 else {
            throw WorkspaceDiagnostics.Failure(description: "Floating toolbar did not expose its measured viewport and command count")
        }
        func asRootPoint(_ local: CGPoint) -> CGPoint {
            CGPoint(x: overlay.minX + local.x, y: host.view.isFlipped ? overlay.minY + local.y : overlay.maxY - local.y)
        }
        let anchor = CGPoint(x: defaults.double(forKey: "floatingToolbarAnchorX"), y: defaults.double(forKey: "floatingToolbarAnchorY"))
        let layout = FloatingPageToolbarLayout.resolve(size: overlay.size, anchor: anchor, itemCount: count)
        let center = asRootPoint(layout.bubbleCenter)
        try check(hypot(center.x - bubble.midX, center.y - bubble.midY) <= 2,
                  "the mounted bubble agrees with its saved anchor in the visible page viewport")
        let penFrame = frame("floating.pen") ?? .zero
        try check(overlay.contains(penFrame) && !penFrame.isEmpty && layout.itemCenters.contains {
            let location = asRootPoint($0)
            return penFrame.insetBy(dx: -1, dy: -1).contains(location)
        }, "the actual mounted Pen control occupies a reachable ring slot")
        for id in ["floating.bubble", "floating.pen", "floating.undo"] {
            guard let buttonFrame = frame(id) else { throw WorkspaceDiagnostics.Failure(description: "Missing button \(id)") }
            let point = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            let hit = host.view.hitTest(host.view.convert(point, to: host.view.superview))
            try check(hit != nil && hit !== page && hit?.isDescendant(of: page) != true,
                      "the center of \(id) hits toolbar chrome above the native page")
        }
        // Find blank points strictly inside the expanded ring. Exclude every
        // command's full rectangular allocation and the bubble before asking
        // the complete hosting hierarchy which native view receives the hit.
        let commandRadius = layout.diameter / 2
        let centers = layout.itemCenters.map(asRootPoint)
        let extent = centers.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        let viewport = scroll.contentView.convert(scroll.contentView.visibleRect, to: host.view)
        var gaps = [CGPoint]()
        for radius in stride(from: ceil(max(bubble.width, bubble.height) / 2) + 4, to: extent - 3, by: 5) {
            for step in 0..<24 {
                let angle = CGFloat(step) * .pi / 12
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                guard viewport.contains(point), !bubble.insetBy(dx: -3, dy: -3).contains(point),
                      !centers.contains(where: { abs($0.x - point.x) <= commandRadius + 3 && abs($0.y - point.y) <= commandRadius + 3 }),
                      gaps.allSatisfy({ hypot($0.x - point.x, $0.y - point.y) > 12 }) else { continue }
                gaps.append(point)
                if gaps.count == 4 { break }
            }
            if gaps.count == 4 { break }
        }
        try check(gaps.count >= 2, "the expanded ring has separate blank points inside its perimeter")
        for point in gaps {
            let hit = host.view.hitTest(host.view.convert(point, to: host.view.superview))
            try check(hit === page.inkView || hit?.isDescendant(of: page.inkView) == true,
                      "expanded ring gap routes the full native hit test to ink at \(point), hit=\(String(describing: hit))")
        }
        guard let gestures = find(FloatingToolbarGestureProbe.View.self, in: host.view) else {
            throw WorkspaceDiagnostics.Failure(description: "Missing mounted floating toolbar gesture handlers")
        }
        let cornerDrag = CGSize(width: overlay.width * 2, height: -overlay.height * 2)
        gestures.drag(cornerDrag)
        try wait("dragging collapses the ring for placement") {
            button("floating.bubble")?.value == "collapsed" && !visible("floating.pen")
        }
        try check(defaults.double(forKey: "floatingToolbarAnchorX") == anchor.x && defaults.double(forKey: "floatingToolbarAnchorY") == anchor.y,
                  "drag previews leave the saved anchor intact until release")
        gestures.drop(cornerDrag)
        try wait("releasing outside the viewport saves a normalized corner anchor") {
            defaults.double(forKey: "floatingToolbarAnchorX") == 1 && defaults.double(forKey: "floatingToolbarAnchorY") == 0
        }
        func atSavedCorner() -> Bool {
            guard let surface = frame("floating.overlay"), let hub = frame("floating.bubble") else { return false }
            let layout = FloatingPageToolbarLayout.resolve(size: surface.size, anchor: CGPoint(x: 1, y: 0), itemCount: count)
            let y = host.view.isFlipped ? surface.minY + layout.collapsedCenter.y : surface.maxY - layout.collapsedCenter.y
            return abs(hub.midX - (surface.minX + layout.collapsedCenter.x)) <= 2 && abs(hub.midY - y) <= 2 &&
                surface.insetBy(dx: -1, dy: -1).contains(hub)
        }
        try wait("released bubble fits at the saved viewport corner", until: atSavedCorner)
        presentation.toolsVisible = false
        try wait("Hide drawing toolbar removes the floating and docked controls") { !visible("floating.overlay") && !visible("page.history.undo") }
        presentation.toolsVisible = true
        try wait("Show drawing toolbar restores the selected mode and saved corner", until: atSavedCorner)
        defaults.set("hover", forKey: "fullScreenToolbarMode")
        try wait("hover-only mode initially displays the compact locator") {
            button("floating.bubble")?.value == "hint" && !visible("floating.pen")
        }
        guard let hover = find(FloatingToolbarGestureProbe.View.self, in: host.view), let hint = frame("floating.bubble") else {
            throw WorkspaceDiagnostics.Failure(description: "Missing mounted hover-only toolbar")
        }
        hover.hover(true)
        try wait("entering the locator reveals its larger button") {
            button("floating.bubble")?.value == "collapsed" && (frame("floating.bubble")?.width ?? 0) > hint.width
        }
        try press("floating.bubble")
        hover.hover(false)
        try wait("an expanded hover menu stays available after leaving its locator") {
            button("floating.bubble")?.value == "expanded" && visible("floating.pen")
        }
        try press("floating.bubble")
        try wait("closing the hover menu restores the locator at its persisted anchor") {
            button("floating.bubble")?.value == "hint" && atSavedCorner()
        }
        presentation.fullPage = false
        try wait("exiting full-page restores the docked toolbar") { visible("page.history.undo") && !visible("floating.overlay") }
        try checkPage("Returning to docked")
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: other)
        try check(!presentation.nativeFullScreen && visible("page.history.undo"), "a different window's fullscreen event leaves the toolbar docked")
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try wait("the owning window's native fullscreen entry activates floating controls") {
            presentation.nativeFullScreen && visible("floating.bubble") && !visible("page.history.undo")
        }
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: other)
        try check(presentation.nativeFullScreen, "a different window's fullscreen exit leaves this window in fullscreen")
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try wait("the owning window's fullscreen exit returns to the docked toolbar") {
            !presentation.nativeFullScreen && visible("page.history.undo") && !visible("floating.overlay")
        }
        try checkPage("Leaving native fullscreen")
        return checks
    }
}
#endif
