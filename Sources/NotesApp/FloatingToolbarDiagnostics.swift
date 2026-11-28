#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

@MainActor
enum FloatingToolbarDiagnostics {
    // Exercise the owning window's native command without moving the user's
    // desktop to a different macOS Space.
    private final class FixtureWindow: NSWindow {
        var simulateFullScreenStyle = false
        private(set) var toggleRequests = 0

        override var styleMask: NSWindow.StyleMask {
            get { simulateFullScreenStyle ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = simulateFullScreenStyle ? newValue.subtracting(.fullScreen) : newValue }
        }

        override func toggleFullScreen(_ sender: Any?) {
            toggleRequests += 1
            guard simulateFullScreenStyle else { return }
            simulateFullScreenStyle = false
            NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: self)
        }
    }

    @MainActor
    private final class ViewportFrameTrace: NSObject {
        let scroll: NSScrollView
        let root: NSView
        private(set) var firstChange: CGRect?
        private(set) var changeCount = 0

        init(scroll: NSScrollView, root: NSView) {
            self.scroll = scroll
            self.root = root
        }

        func reset() {
            firstChange = nil
            changeCount = 0
        }

        @objc func frameChanged(_ notification: Notification) {
            guard notification.object as? NSScrollView === scroll else { return }
            changeCount += 1
            if firstChange == nil { firstChange = scroll.convert(scroll.bounds, to: root) }
        }
    }

    private struct ViewportReference {
        let viewport: CGRect
        let host: CGRect

        // AppKit can grow the hosting window to fit its content. Reapply the
        // original editor insets to the actual available rectangle.
        func available(in bounds: CGRect) -> CGRect {
            CGRect(x: bounds.minX + (viewport.minX - host.minX),
                   y: bounds.minY + (viewport.minY - host.minY),
                   width: viewport.width + (bounds.width - host.width),
                   height: viewport.height + (bounds.height - host.height))
        }
    }

    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw WorkspaceDiagnostics.Failure(description: "Floating toolbar: " + message) }
            checks += 1
        }
        func wait(_ message: @autoclosure () -> String, until condition: () -> Bool) throws {
            let deadline = Date(timeIntervalSinceNow: 5)
            repeat {
                RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.016)))
            } while !condition() && Date() < deadline
            try check(condition(), message())
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
        let window = FixtureWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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
        func press(_ id: String, beforeAction: () -> Void = {}) throws {
            try wait("\(id) is mounted and enabled") { visible(id) && button(id)?.isEnabled == true }
            beforeAction()
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

        // Use the same content-bearing window, with its native Pen input owner and undo history.
        let handleID = "page-navigation-handle", pinID = "page-navigation-pin"
        let dotID = "page-carousel-\(pageID.uuidString)"
        func hoverNavigation(_ type: NSEvent.EventType, bottomOffset: CGFloat = 0, windowX: CGFloat? = nil,
                             at windowPoint: CGPoint? = nil) throws {
            let content = window.contentLayoutRect
            guard let tracker = find(PageNavigationHoverRegion.TrackingView.self, in: host.view) else {
                throw WorkspaceDiagnostics.Failure(description: "Missing the mounted page-navigation pointer tracker")
            }
            let bottom = tracker.convert(tracker.bounds, to: nil).minY
            let location = windowPoint ?? NSPoint(x: windowX ?? content.midX, y: bottom + bottomOffset)
            guard let event = NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, trackingNumber: 0, userData: nil) else {
                throw WorkspaceDiagnostics.Failure(description: "Missing the mounted page-navigation pointer tracker")
            }
            if type == .mouseEntered {
                let rectangles = tracker.trackingAreas.compactMap { area -> NSRect? in
                    guard (area.owner as? NSView) === tracker, area.options.contains(.mouseEnteredAndExited),
                          area.options.contains(.activeInKeyWindow) else { return nil }
                    return tracker.convert(area.rect, to: nil)
                }
                func coversBottom(_ height: CGFloat) -> Bool {
                    rectangles.contains { rect in
                        abs(rect.minY - bottom) <= 1 && abs(rect.height - height) <= 1
                            && rect.contains(NSPoint(x: content.minX + 24, y: bottom + 3))
                            && rect.contains(NSPoint(x: content.maxX - 24, y: bottom + height - 3))
                    }
                }
                try check(coversBottom(16) && coversBottom(50)
                          && rectangles.allSatisfy { !$0.contains(NSPoint(x: content.midX, y: bottom + 135)) },
                          "registered AppKit areas cover the narrow edge and full footer across the window: \(rectangles)")
                tracker.mouseEntered(with: event)
            } else {
                tracker.mouseExited(with: event)
            }
        }
        func navigationViewport() -> CGRect { scroll.convert(scroll.bounds, to: host.view) }
        let reservationID = "page-navigation-reservation"
        let trace = ViewportFrameTrace(scroll: scroll, root: host.view)
        let wasPosting = scroll.postsFrameChangedNotifications
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(trace, selector: #selector(ViewportFrameTrace.frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        defer {
            NotificationCenter.default.removeObserver(trace)
            scroll.postsFrameChangedNotifications = wasPosting
        }
        func layoutContext() -> String {
            "window=\(window.frame) root=\(host.view.bounds) viewport=\(navigationViewport()) " +
            "bar=\(String(describing: frame("page-carousel"))) reservation=\(String(describing: frame(reservationID))) " +
            "frameChanges=\(trace.changeCount) firstChange=\(String(describing: trace.firstChange))"
        }
        func navigationSettled() -> Bool {
            find(WorkspaceNavigationProbe.self, in: host.view)?.diagnosticsSnapshot().isQuiescent(
                expectedFullPage: presentation.fullPage, expectedSheetsVisible: true) == true
        }
        func sameViewport(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.maxX - rhs.maxX) <= 1 && abs(lhs.maxY - rhs.maxY) <= 1 &&
            abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
        }
        func reference() -> ViewportReference {
            ViewportReference(viewport: navigationViewport(), host: host.view.bounds)
        }
        func pinFits(_ pinned: CGRect, available: CGRect, footer: CGRect, reservation: CGRect,
                     height: CGFloat, flipped: Bool) -> Bool {
            let topInsetChange = flipped ? pinned.minY - available.minY : pinned.maxY - available.maxY
            let gap = flipped ? footer.minY - pinned.maxY : pinned.minY - footer.maxY
            let bottomInsetChange = flipped ? footer.maxY - available.maxY : footer.minY - available.minY
            return abs(pinned.minX - available.minX) <= 1 && abs(pinned.maxX - available.maxX) <= 1 &&
                abs(pinned.width - available.width) <= 1 && abs(topInsetChange) <= 1 &&
                abs(available.height - pinned.height - height) <= 2 &&
                abs(footer.minX - available.minX) <= 1 && abs(footer.maxX - available.maxX) <= 1 &&
                abs(footer.height - height) <= 1 && abs(gap) <= 2 && abs(bottomInsetChange) <= 2 &&
                sameViewport(footer, reservation)
        }
        // Native run 54 grew the host by 14 points while reserving 50.
        let recorded = ViewportReference(viewport: CGRect(x: 228, y: 240, width: 922, height: 382),
                                         host: CGRect(x: 0, y: 0, width: 1150, height: 622))
        let available = recorded.available(in: CGRect(x: 0, y: 0, width: 1150, height: 636))
        let recordedPin = CGRect(x: 228, y: 240, width: 922, height: 346)
        let recordedFooter = CGRect(x: 228, y: 586, width: 922, height: 50)
        func fitsRecording(_ viewport: CGRect) -> Bool {
            pinFits(viewport, available: available, footer: recordedFooter,
                    reservation: recordedFooter, height: 50, flipped: true)
        }
        try check(fitsRecording(recordedPin) && !fitsRecording(recordedPin.offsetBy(dx: 0, dy: -7)) &&
                  !fitsRecording(available), "host growth allows only the measured footer reservation and original top inset")
        func pageTakesInk(at point: CGPoint) -> Bool {
            let hit = host.view.hitTest(host.view.convert(point, to: host.view.superview))
            return hit === page.inkView || hit?.isDescendant(of: page.inkView) == true
        }
        func scrollbar(_ context: String) throws -> NSScroller {
            guard let scroller = scroll.horizontalScroller, scroller.window === window,
                  !scroller.isHiddenOrHasHiddenAncestor, scroller.knobProportion < 1,
                  !scroller.rect(for: .knob).isEmpty else {
                throw WorkspaceDiagnostics.Failure(description: "\(context) needs a horizontally overflowing page with a visible scrollbar")
            }
            return scroller
        }
        func knobCenter(_ scroller: NSScroller) -> CGPoint {
            let knob = scroller.rect(for: .knob)
            return scroller.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
        }
        func checkScrollbarHit(_ scroller: NSScroller, _ windowPoint: CGPoint, _ context: String) throws {
            let hit = host.view.hitTest(host.view.superview?.convert(windowPoint, from: nil) ?? windowPoint)
            try check(hit === scroller || hit?.isDescendant(of: scroller) == true,
                      "\(context) delivers a scrollbar click to AppKit at \(windowPoint), got \(String(describing: hit))")
        }
        func dragScrollbar(_ context: String) throws {
            let scroller = try scrollbar(context)
            let start = knobCenter(scroller)
            try checkScrollbarHit(scroller, start, context)
            let center = scroller.convert(CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
            try checkScrollbarHit(scroller, center, context)
            let end = CGPoint(x: start.x + (scroller.doubleValue > 0.5 ? -36 : 36), y: start.y)
            let before = scroll.documentVisibleRect.minX
            func event(_ type: NSEvent.EventType, _ location: CGPoint) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                    throw WorkspaceDiagnostics.Failure(description: "Could not create scrollbar drag event")
                }
                return event
            }
            // AppKit's synchronous knob tracking consumes these window-local events.
            NSApp.postEvent(try event(.leftMouseUp, end), atStart: true)
            NSApp.postEvent(try event(.leftMouseDragged, end), atStart: true)
            window.sendEvent(try event(.leftMouseDown, start))
            try check(abs(scroll.documentVisibleRect.minX - before) > 1, "\(context) native knob drag pans the visible page")
        }
        try check(defaults.object(forKey: "pageNavigationMode") == nil,
                  "the page-navigation fixture starts without a saved mode")
        func scrollerBacking(in view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if view.identifier?.rawValue == "page-navigation-scroller-backing" { return view }
            return view.subviews.lazy.compactMap { scrollerBacking(in: $0) }.first
        }
        // Match the reported 75% in a regular window. Resize the same live
        // editor so the page naturally crosses the horizontal overflow boundary.
        let originalSize = host.view.bounds.size
        scroll.scrollerStyle = .overlay
        window.setContentSize(NSSize(width: 940, height: originalSize.height))
        scroll.setMagnification(0.75, centeredAt: CGPoint(x: page.visibleRect.midX, y: page.visibleRect.midY))
        try wait("the narrow window has an overflowing page and a collapsed navigation handle") {
            visible(handleID) && !visible("page-carousel") && presentation.pageScrollerClearance > 0
        }
        try check(scrollerBacking(in: scroll) == nil, "collapsed hover leaves the paper visible down to the window edge")
        try press(handleID)
        try wait("the revealed windowed footer paints the overlay scrollbar lane: \(layoutContext())") {
            visible("page-carousel") && scrollerBacking(in: scroll) != nil
        }
        guard let backing = scrollerBacking(in: scroll), let narrowBar = frame("page-carousel") else {
            throw WorkspaceDiagnostics.Failure(description: "Missing revealed footer surface")
        }
        let lane = backing.convert(backing.visibleRect, to: nil)
        let controlsInWindow = host.view.convert(narrowBar, to: nil)
        let editorInWindow = scroll.convert(scroll.bounds, to: nil)
        try check(lane.height > 0 && abs(lane.minY - window.contentLayoutRect.minY) <= 1 &&
                  abs(lane.maxY - controlsInWindow.minY) <= 1 &&
                  abs(lane.minX - editorInWindow.minX) <= 1 && abs(lane.maxX - editorInWindow.maxX) <= 1 &&
                  abs(lane.minX - controlsInWindow.minX) <= 1 && abs(lane.maxX - controlsInWindow.maxX) <= 1,
                  "the revealed overlay lane fills the width under the controls to the window edge: lane=\(lane) controls=\(controlsInWindow) editor=\(editorInWindow)")
        let laneCenter = backing.superview?.convert(CGPoint(x: lane.midX, y: lane.midY), from: nil) ?? .zero
        try check(backing.hitTest(laneCenter) == nil, "the footer surface passes pointer events through to AppKit")
        guard let contentIndex = scroll.subviews.firstIndex(of: scroll.contentView),
              let backingIndex = scroll.subviews.firstIndex(of: backing),
              let horizontal = scroll.horizontalScroller,
              let scrollerIndex = scroll.subviews.firstIndex(where: { $0 === horizontal || horizontal.isDescendant(of: $0) }),
              let bitmap = backing.bitmapImageRepForCachingDisplay(in: backing.bounds) else {
            throw WorkspaceDiagnostics.Failure(description: "The overlay lane needs a mounted paper clip, backing and native scroller")
        }
        try check(contentIndex < backingIndex && backingIndex < scrollerIndex,
                  "the footer surface draws over the paper and underneath the native overlay scrollbar")
        backing.cacheDisplay(in: backing.bounds, to: bitmap)
        try check((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) >= 0.99,
                  "the rendered backing actually masks the paper beneath the fading overlay scrollbar")
        try press(pinID)
        try wait("pinning the narrow overlay footer removes the paper backing") {
            visible(reservationID) && button(pinID)?.value == "pinned" && scrollerBacking(in: scroll) == nil
        }
        try press(pinID)
        try wait("unpinning the narrow overlay footer restores the collapsed handle") {
            visible(handleID) && !visible(dotID) && !visible(reservationID)
        }
        try press(handleID)
        try wait("the narrow overlay footer has its surface again after unpinning") { scrollerBacking(in: scroll) != nil }
        window.setContentSize(NSSize(width: 1600, height: originalSize.height))
        try wait("widening the same window fits the 75% page and removes the scrollbar backing: \(layoutContext())") {
            guard let bar = frame("page-carousel") else { return false }
            return page.visibleRect.width >= page.bounds.width - 1 && scrollerBacking(in: scroll) == nil &&
                abs(host.view.convert(bar, to: nil).minY - window.contentLayoutRect.minY) <= 1
        }
        window.setContentSize(originalSize)
        scroll.setMagnification(zoom, centeredAt: CGPoint(x: page.visibleRect.midX, y: page.visibleRect.midY))
        try wait("narrowing the window restores the backing under the open footer") { scrollerBacking(in: scroll) != nil }
        try press(handleID)
        try wait("closing the overflowing footer removes its backing") { !visible(dotID) && scrollerBacking(in: scroll) == nil }
        // Keep a persistent scrollbar for the real knob drags below, even on
        // hosts that fade overlay scrollbars without a physical pointer.
        scroll.scrollerStyle = .legacy
        for mode in ["windowed", "Full Page", "native full screen"] {
            presentation.fullPage = mode == "Full Page"
            if mode == "native full screen" {
                NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
            }
            try wait("\(mode) exposes the collapsed bottom navigation after native transitions") {
                navigationSettled() && visible(handleID) && !visible("page-carousel") && !visible(reservationID)
            }
            let base = reference()
            let scroller = try scrollbar(mode)
            try hoverNavigation(.mouseEntered, at: knobCenter(scroller))
            try wait("\(mode) approaching the scrollbar knob leaves the navigation handle collapsed") {
                visible(handleID) && !visible(dotID)
            }
            try dragScrollbar("\(mode) collapsed")
            // First approach from underneath the visible notebook sidebar, then from the page.
            try hoverNavigation(.mouseEntered, bottomOffset: 46)
            try wait("\(mode) entering the upper tracking area alone leaves the page clear") { !visible(dotID) }
            try hoverNavigation(.mouseEntered, bottomOffset: 3, windowX: mode == "windowed" ? 24 : nil)
            try wait("\(mode) reveals the current page dot, add and pin on bottom-edge movement") {
                visible(dotID) && visible("page-carousel-add") && visible(pinID)
            }
            guard let bar = frame("page-carousel"), let pin = frame(pinID) else {
                throw WorkspaceDiagnostics.Failure(description: "Missing mounted page navigation")
            }
            let revealed = navigationViewport()
            try check(sameViewport(base.available(in: host.view.bounds), revealed),
                      "\(mode) revealing the footer preserves the available viewport: before=\(base) \(layoutContext())")
            let scrollerInWindow = scroller.convert(scroller.bounds, to: nil)
            let barInWindow = host.view.convert(bar, to: nil)
            try check(abs(barInWindow.minY - scrollerInWindow.maxY) <= 1,
                      "\(mode) places the revealed controls directly above the native scrollbar: bar=\(barInWindow) scroller=\(scrollerInWindow)")
            try dragScrollbar("\(mode) revealed")
            let nearFooter = CGPoint(x: revealed.midX, y: host.view.isFlipped ? bar.minY - 6 : bar.maxY + 6)
            try check(pageTakesInk(at: nearFooter) && !pageTakesInk(at: CGPoint(x: pin.midX, y: pin.midY)),
                      "\(mode) routes ink immediately above the footer and reserves the pin for navigation")
            try hoverNavigation(.mouseExited, bottomOffset: bar.height - 3)
            try wait("\(mode) keeps the controls accessible when moving from the edge into the footer") { visible(dotID) }
            if mode == "windowed" {
                let beforeBrowse = reference()
                try press("page-browser-button")
                try wait("the hover footer opens the page browser") { button("page-browser-button")?.value == "open" }
                try hoverNavigation(.mouseExited, bottomOffset: bar.height + 110)
                try wait("the browser and its footer remain open while using the popover") {
                    button("page-browser-button")?.value == "open" && visible(dotID)
                }
                try check(sameViewport(beforeBrowse.available(in: host.view.bounds), navigationViewport()),
                          "opening the page browser preserves the viewport: before=\(beforeBrowse) \(layoutContext())")
                try press("page-browser-button")
                try wait("closing the page browser retracts the hover footer") { !visible(dotID) && visible(handleID) }
                try check(sameViewport(beforeBrowse.available(in: host.view.bounds), navigationViewport()),
                          "closing the page browser preserves the viewport: before=\(beforeBrowse) \(layoutContext())")
            }
            try hoverNavigation(.mouseExited, bottomOffset: bar.height + 110)
            try wait("\(mode) retracts the footer when the pointer leaves it") { !visible(dotID) && visible(handleID) }
            try press(handleID)
            try wait("\(mode) reopens the hover footer before pinning") { visible(pinID) && navigationSettled() }
            let beforePin = reference()
            try check(sameViewport(base.available(in: beforePin.host), beforePin.viewport),
                      "\(mode) preserves the viewport through hover and handle actions: baseline=\(base) \(layoutContext())")
            try press(pinID, beforeAction: trace.reset)
            // A saved preference can precede the native allocation. Observe the
            // spacer's mount and this scroll view's first frame change after the
            // action. Neither signal requires the proposed geometry to be right.
            try wait("\(mode) applies the pin to the native footer and editor: before=\(beforePin) \(layoutContext())") {
                navigationSettled() && visible(dotID) && visible(reservationID) && trace.changeCount > 0 &&
                button(pinID)?.value == "pinned" && defaults.string(forKey: "pageNavigationMode") == "pinned"
            }
            let pinned = navigationViewport()
            guard let pinnedBar = frame("page-carousel"), let reservation = frame(reservationID) else {
                throw WorkspaceDiagnostics.Failure(description: "Missing mounted pinned footer: \(layoutContext())")
            }
            try check(pinFits(pinned, available: beforePin.available(in: host.view.bounds),
                              footer: pinnedBar, reservation: reservation, height: bar.height, flipped: host.view.isFlipped),
                      "\(mode) reserves exactly the pinned footer's height in the editor: before=\(beforePin) hoverBar=\(bar) \(layoutContext())")
            try check(scrollerBacking(in: scroll) == nil, "\(mode) pinned navigation leaves its separate editor scrollbar untouched")
            try dragScrollbar("\(mode) pinned")
            try checkPage("\(mode) bottom navigation")
            try check(manager.canUndo && editor.string == seed + suffix,
                      "\(mode) revealing and pinning preserve the native edit and undo")
            if mode != "native full screen" {
                try press(pinID, beforeAction: trace.reset)
                try wait("\(mode) restores the hover preference and its native layout: pinned=\(pinned) \(layoutContext())") {
                    navigationSettled() && trace.changeCount > 0 && !visible(reservationID) &&
                    defaults.string(forKey: "pageNavigationMode") == "hover" && visible(handleID)
                        && find(PageNavigationHoverRegion.TrackingView.self, in: host.view) != nil
                }
                try check(sameViewport(beforePin.available(in: host.view.bounds), navigationViewport()),
                          "\(mode) unpinning restores the entire viewport: before=\(beforePin) \(layoutContext())")
                try hoverNavigation(.mouseExited, bottomOffset: bar.height + 110)
            }
        }
        try press("page-carousel-add")
        try wait("the pinned footer adds and selects a new page in native full screen") {
            presentation.nativeFullScreen && store.selectedSheet?.id != pageID && store.selectedSheet?.title == ""
        }
        guard let secondID = store.sheetID else { throw WorkspaceDiagnostics.Failure(description: "Missing new zoom fixture page") }
        let secondDot = "page-carousel-\(secondID.uuidString)"
        func currentScroll() -> PageZoomScrollView? { find(UnifiedMacPageView.self, in: host.view)?.enclosingScrollView as? PageZoomScrollView }
        try wait("the new page mounts its own native editor at 100 percent") {
            guard let native = currentScroll(), native !== scroll else { return false }
            return native.zoomSetting == .scale(1) && abs(native.magnification - 1) < 0.000001
        }
        // Measure the real controls in this fixture window. The passive probes
        // have no action and do not participate in hit testing.
        var eventNumber = 100
        func click(_ id: String, enabled: Bool = true) throws {
            try wait("\(id) is mounted with the expected enablement") { visible(id) && button(id)?.isEnabled == enabled }
            guard let target = frame(id) else { throw WorkspaceDiagnostics.Failure(description: "Missing frame for \(id)") }
            let point = host.view.convert(CGPoint(x: target.midX, y: target.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                eventNumber += 1
                guard let result = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw WorkspaceDiagnostics.Failure(description: "Could not create mouse input for \(id)")
                }
                return result
            }
            let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
            // AppKit may consume mouse-up while handling mouse-down. SwiftUI
            // can also finish tracking after mouse-down returns.
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false)
            if pending?.eventNumber == up.eventNumber, pending?.windowNumber == window.windowNumber,
               let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(release)
            }
        }
        let zoomIn = "page-zoom-in", zoomOut = "page-zoom-out"
        try wait("both zoom buttons and their slider have mounted frames") {
            visible(zoomOut) && visible("page-zoom-slider") && visible(zoomIn)
        }
        guard let minus = frame(zoomOut), let track = frame("page-zoom-slider"), let plus = frame(zoomIn) else {
            throw WorkspaceDiagnostics.Failure(description: "Missing zoom controls in the mounted footer")
        }
        try check(!minus.isEmpty && !plus.isEmpty && !track.isEmpty &&
                  minus.maxX <= track.minX + 1 && track.maxX <= plus.minX + 1,
                  "the zoom buttons flank the native slider without covering its track")
        try click(zoomIn)
        try wait("Zoom in magnifies the new page to 120 percent and remembers the choice") {
            currentScroll()?.zoomSetting == .scale(1.2) && store.makeZoomSession(for: secondID).setting == .scale(1.2)
        }
        try click(zoomOut)
        try wait("Zoom out reverses the increment on the same page") { currentScroll()?.zoomSetting == .scale(1) }
        func zoomField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Page zoom percentage",
               field.window === window, !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { zoomField(in: $0) }.first
        }
        func enterZoomText(_ value: String) throws -> NSTextView {
            guard let field = zoomField(in: host.view), window.makeFirstResponder(field),
                  let editor = field.currentEditor() as? NSTextView else {
                throw WorkspaceDiagnostics.Failure(description: "Missing editable footer zoom percentage")
            }
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            try wait("the native zoom field keeps the pending percentage at the caret") {
                field.currentEditor() === editor && editor.string == value
            }
            return editor
        }
        let typedZoom = try enterZoomText("127.5%")
        try check(currentScroll()?.zoomSetting == .scale(1), "typing keeps the page at its current zoom during editing")
        typedZoom.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try wait("Return applies the typed zoom to the active page") { currentScroll()?.zoomSetting == .scale(1.275) }
        let cancelled = try enterZoomText("82")
        cancelled.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try wait("Escape discards the typed percentage") {
            currentScroll()?.zoomSetting == .scale(1.275) && zoomField(in: host.view)?.stringValue == ZoomPercentage.display(1.275)
        }
        _ = try enterZoomText("401")
        window.makeFirstResponder(nil)
        try wait("an out-of-range percentage restores the prior zoom on blur") {
            currentScroll()?.zoomSetting == .scale(1.275) && zoomField(in: host.view)?.stringValue == ZoomPercentage.display(1.275)
        }
        for (text, scale, disabled, enabled) in [("25", 0.25, zoomOut, zoomIn), ("400", 4.0, zoomIn, zoomOut)] {
            let fieldEditor = try enterZoomText(text)
            fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try wait("at \(text) percent only the inward zoom button is enabled") {
                currentScroll()?.zoomSetting == .scale(scale) && button(disabled)?.isEnabled == false
                    && button(enabled)?.isEnabled == true
            }
            try click(disabled, enabled: false)
            try wait("clicking the disabled button leaves zoom at \(text) percent") { currentScroll()?.zoomSetting == .scale(scale) }
        }
        _ = try enterZoomText("75")
        window.makeFirstResponder(nil)
        try wait("losing focus commits a valid percentage without a percent sign") { currentScroll()?.zoomSetting == .scale(0.75) }
        try press("page-zoom-fit-width")
        try wait("Fit Width on the footer fits the new page and marks the button selected") {
            currentScroll()?.fitsPageWidth == true && button("page-zoom-fit-width")?.value == "Selected"
        }
        guard let fittedScale = currentScroll()?.magnification else { throw WorkspaceDiagnostics.Failure(description: "Missing fitted page") }
        let expectedScale = min(4, max(0.25, fittedScale * 1.2))
        try click(zoomIn)
        try wait("Zoom in switches Fit Width to a manual step from the measured fit") {
            guard let native = currentScroll(), case let .scale(actual) = native.zoomSetting else { return false }
            return abs(actual - expectedScale) < 0.000001 && abs(native.magnification - actual) < 0.000001
        }
        try press("page-zoom-fit-page")
        try wait("Fit Page selects the whole-page fit and clears the width indicator") {
            currentScroll()?.zoomSetting == .fitPage && button("page-zoom-fit-page")?.value == "Selected"
                && button("page-zoom-fit-width")?.value == "Not selected"
        }
        try press(dotID)
        try wait("the pinned page dot returns to the original content in native full screen") {
            store.sheetID == pageID && find(UnifiedMacPageView.self, in: host.view)?.textView.string == seed + suffix
        }
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try wait("exiting native full screen preserves pinned navigation and the active page") {
            !presentation.nativeFullScreen && visible(dotID) && button(pinID)?.value == "pinned"
        }
        func matchesOriginalZoom() -> Bool {
            guard let native = currentScroll(), case .scale(let scale) = native.zoomSetting else { return false }
            return abs(scale - 1.18) < 0.000001 && abs(native.magnification - 1.18) < 0.000001
        }
        try check(matchesOriginalZoom(), "returning through the page dot restores the original page's 118 percent zoom")
        var preferences = store.notebookDefaults
        preferences.zoom = .scale(1.5)
        store.saveNotebookDefaults(preferences)
        try press(secondDot)
        try wait("the second page reopens with its own remembered Fit Page setting") {
            store.sheetID == secondID && currentScroll()?.zoomSetting == .fitPage
        }
        try press(dotID)
        try wait("the original page retains 118 percent after changing the notebook default") {
            store.sheetID == pageID && matchesOriginalZoom()
        }
        try press("page-carousel-add")
        try wait("a new page uses the revised 150 percent default") {
            guard let id = store.sheetID, id != pageID, id != secondID, let native = currentScroll() else { return false }
            return native.zoomSetting == .scale(1.5) && abs(native.magnification - 1.5) < 0.000001
        }
        try check(store.flush(), "the zoom fixture can reopen its temporary library")
        let reopenedStore = NotesStore(directory: directory, preferences: defaults)
        let reopenedWindow = EditorPresentation()
        let restored = reopenedWindow.zoomSession(for: pageID, in: reopenedStore)
        let restoredSecond = reopenedWindow.zoomSession(for: secondID, in: reopenedStore)
        if case .scale(let scale) = restored.setting {
            try check(abs(scale - 1.18) < 0.000001 && restoredSecond.setting == .fitPage &&
                      reopenedStore.notebookDefaults.zoom == .scale(1.5),
                      "a reopened store restores both page choices separately from its default")
        } else {
            throw WorkspaceDiagnostics.Failure(description: "Missing original percentage after reopening the zoom fixture")
        }
        try press(dotID)
        try wait("the original page is mounted for the direct Exit action") { store.sheetID == pageID && matchesOriginalZoom() }
        guard let exitPage = find(UnifiedMacPageView.self, in: host.view),
              let exitUndo = exitPage.textView.undoManager else { throw WorkspaceDiagnostics.Failure(description: "Missing direct Exit fixture editor") }
        let exitSetting = defaults.string(forKey: "fullScreenToolbarMode")
        let exitSelection = exitPage.textView.selectedRange()
        for (fullPage, native) in [(true, false), (false, true), (true, true)] {
            let label = native ? "Exit Full Screen" : "Exit Full Page"
            let before = window.toggleRequests
            presentation.fullPage = fullPage
            if native { NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window) }
            try wait("the floating toolbar appears before \(label)") {
                navigationSettled() && visible("floating.bubble") && !visible("floating.exitWorkspace")
            }
            try press("floating.bubble")
            try wait("\(label) is directly accessible on the first tools ring") {
                visible("floating.exitWorkspace") && button("floating.exitWorkspace")?.value == label
            }
            try press("floating.exitWorkspace") { window.simulateFullScreenStyle = native }
            try wait("\(label) returns to the ordinary window and docked controls with one press") {
                !presentation.isFullScreenWorkspace && navigationSettled() && visible("page.history.undo") && !visible("floating.overlay")
            }
            try check(window.toggleRequests == before + (native ? 1 : 0) &&
                      find(UnifiedMacPageView.self, in: host.view) === exitPage &&
                      exitPage.textView.undoManager === exitUndo && exitPage.textView.selectedRange() == exitSelection &&
                      exitPage.textView.string == seed + suffix && matchesOriginalZoom() &&
                      defaults.string(forKey: "fullScreenToolbarMode") == exitSetting,
                      "\(label) sends the correct native command and preserves page, caret, undo, zoom, and toolbar preference")
        }
        // Use the same pinned footer and a disposable long topic. Install the
        // fixture library in one update so only the chosen page mounts.
        guard let parent = store.selectedSheet?.parentID else {
            throw WorkspaceDiagnostics.Failure(description: "Missing parent for page navigation fixture")
        }
        var library = store.library
        let topic = try library.create(kind: .topic, title: "Long page strip", parentID: parent)
        var pages = try (1...14).map { _ in try library.create(kind: .sheet, parentID: topic) }
        func dot(_ index: Int) -> String { "page-carousel-\(pages[index].uuidString)" }
        func numbersOnScreen() -> [Int] { pages.indices.filter { visible(dot($0)) } }
        let previous = "page-range-previous", next = "page-range-next"
        func checkNumbers(_ context: String) throws {
            guard let browse = frame("page-browser-button"), let add = frame("page-carousel-add"),
                  let footer = frame("page-carousel"), let selected = pages.firstIndex(where: { $0 == store.sheetID }) else {
                throw WorkspaceDiagnostics.Failure(description: "\(context) is missing page navigation")
            }
            let indices = numbersOnScreen()
            let frames = indices.compactMap { frame(dot($0)) }
            try check(indices.contains(selected) && button(dot(selected))?.value == "Current page" &&
                      zip(indices, indices.dropFirst()).allSatisfy { $1 == $0 + 1 },
                      "\(context) shows the selected page in a contiguous numbered range: \(indices)")
            try check(frames.allSatisfy {
                $0.width >= 43.5 && $0.height >= 43.5 && abs($0.midY - add.midY) <= 1 &&
                $0.minX >= browse.maxX - 1 && $0.maxX <= add.minX + 1 && footer.insetBy(dx: -1, dy: -1).contains($0)
            } && zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 1 },
                      "\(context) has whole aligned targets between Browse and Add: \(frames)")
            func hasPageStripScroller(_ view: NSView) -> Bool {
                if let scroller = view as? NSScrollView, scroller.hasHorizontalScroller, !scroller.isHiddenOrHasHiddenAncestor {
                    let rect = scroller.convert(scroller.visibleRect, to: host.view)
                    if !rect.isEmpty && footer.contains(CGPoint(x: rect.midX, y: rect.midY)) { return true }
                }
                return view.subviews.contains(where: hasPageStripScroller)
            }
            try check(!hasPageStripScroller(host.view), "\(context) keeps horizontal scrolling out of the page-number row")
        }
        let height = window.contentLayoutRect.height
        window.setContentSize(NSSize(width: 1500, height: height))
        store.library = library
        store.folderID = topic
        store.sheetID = pages[9]
        try wait("fourteen pages fit in the wide footer") {
            numbersOnScreen().count == pages.count && !visible(next)
        }
        try checkNumbers("Fourteen pages at wide width")
        window.setContentSize(NSSize(width: 880, height: height))
        try wait("the same topic shows navigation arrows after narrowing the window") {
            visible(previous) && visible(next) && numbersOnScreen().count < pages.count
        }
        try checkNumbers("Fourteen pages at narrow width")

        pages += try (15...104).map { _ in try library.create(kind: .sheet, parentID: topic) }
        store.library = library
        store.sheetID = pages[84]
        try wait("an external selection brings page 85 into the bounded strip") {
            button(dot(84))?.value == "Current page" && button(next)?.isEnabled == true
        }
        try checkNumbers("104-page topic")
        try click(next)
        try wait("the forward control navigates to a later visible group") {
            guard let selected = pages.firstIndex(where: { $0 == store.sheetID }) else { return false }
            return selected > 84 && button(dot(selected))?.value == "Current page"
        }
        let forward = store.sheetID
        try click(previous)
        try wait("the backward control navigates to an earlier group") {
            guard let before = forward.flatMap({ pages.firstIndex(of: $0) }),
                  let now = pages.firstIndex(where: { $0 == store.sheetID }) else { return false }
            return now < before && button(dot(now))?.value == "Current page"
        }
        for (index, disabled) in [(0, previous), (103, next)] {
            store.sheetID = pages[index]
            try wait("external selection exposes page \(index + 1) and disables its outward arrow") {
                button(dot(index))?.value == "Current page" && button(disabled)?.isEnabled == false
            }
            try click(disabled, enabled: false)
            try wait("clicking the disabled range arrow leaves page \(index + 1) selected") { store.sheetID == pages[index] }
            try checkNumbers("Page \(index + 1) at the range boundary")
        }
        try click(zoomIn)
        try wait("the zoom button works beside triple-digit pages") { currentScroll()?.zoomSetting == .scale(1.8) || abs((currentScroll()?.magnification ?? 0) - 1.8) < 0.000001 }
        try press("page-carousel-add")
        try wait("Add appends page 105 and exposes its selected numbered button") {
            guard let added = store.selectedSheet, added.parentID == topic, added.sheetNumber == 105 else { return false }
            return button("page-carousel-\(added.id.uuidString)")?.value == "Current page"
        }
        // An empty custom ring still opens its editor. Preferences apply to the
        // mounted window immediately and the next page uses the same choices.
        let catalog = FloatingToolbarChoice.all
        let factory = FloatingToolbarChoice.visibleIDs(in: FloatingToolbarChoice.factory)
        try check(Set(catalog.map(\.id)).count == catalog.count &&
                  factory.contains("fill") && factory.contains("textSize") && !factory.contains("selection"),
                  "each configurable button has a stable ID and the default ring includes Fill and Text size")
        let preference = FloatingToolbarChoice.preferenceKey
        defaults.set("", forKey: preference)
        defaults.set("floating", forKey: "fullScreenToolbarMode")
        presentation.fullPage = true
        try wait("a custom empty floating toolbar keeps its bubble") {
            visible("floating.bubble") && !visible("floating.pen") && currentScroll() != nil
        }
        let customPage = find(UnifiedMacPageView.self, in: host.view)
        let customUndo = customPage?.textView.undoManager
        let customZoom = currentScroll()?.zoomSetting
        try press("floating.bubble")
        func sheetControl(_ name: String) -> WorkspaceDiagnosticControls.Control? {
            // SwiftUI can host this presentation in a separate panel. Only this
            // fixture's view hierarchy receives its diagnostic registry.
            button("floating.choice." + name)
        }
        for id in ["draw.pen", "fill", "selection"] {
            try wait("the empty ring opens the customization checkbox for \(id)") { sheetControl(id)?.value == "Off" }
            try check(sheetControl(id)?.perform() == true, "enable \(id) in the mounted customization sheet")
            try wait("the checked \(id) button is persisted") {
                sheetControl(id)?.value == "On" && FloatingToolbarChoice.visibleIDs(in: defaults.string(forKey: preference) ?? "").contains(id)
            }
        }
        try check(sheetControl("draw.pen")?.perform() == true, "remove Pen using its checked control")
        try wait("only the two chosen buttons are saved") {
            FloatingToolbarChoice.visibleIDs(in: defaults.string(forKey: preference) ?? "") == ["fill", "selection"]
        }
        try check(sheetControl("done")?.perform() == true, "Done dismisses the mounted customizer")
        try wait("the customization sheet closes") { sheetControl("done") == nil }
        try press("floating.bubble")
        try wait("the ring shows the two chosen controls and hides Pen, Undo and Exit") {
            button("floating.overlay")?.value == "2" && !visible("floating.pen") &&
            !visible("floating.undo") && !visible("floating.exitWorkspace")
        }
        try check(find(UnifiedMacPageView.self, in: host.view) === customPage &&
                  customPage?.textView.undoManager === customUndo && currentScroll()?.zoomSetting == customZoom,
                  "customizing the floating controls preserves the editor, history and zoom")
        defaults.set("", forKey: preference)
        try wait("removing the last button closes the ring") { button("floating.bubble")?.value == "collapsed" }
        try press("floating.bubble")
        try wait("Restore defaults remains accessible with every control removed") { sheetControl("restore") != nil }
        try check(sheetControl("restore")?.perform() == true, "Restore defaults uses the original button set")
        try wait("the factory preference and checked controls return") {
            defaults.string(forKey: preference) == FloatingToolbarChoice.factory &&
            sheetControl("draw.pen")?.value == "On" && sheetControl("selection")?.value == "Off"
        }
        try check(sheetControl("done")?.perform() == true, "Done dismisses the mounted customizer")
        try wait("the restored customizer closes") { sheetControl("done") == nil }
        try openRing()
        return checks
    }
}
#endif
