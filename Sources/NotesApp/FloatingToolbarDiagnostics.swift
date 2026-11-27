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
        func hoverNavigation(_ type: NSEvent.EventType, bottomOffset: CGFloat, windowX: CGFloat? = nil) throws {
            let content = window.contentLayoutRect
            let location = NSPoint(x: windowX ?? content.midX, y: content.minY + bottomOffset)
            guard let tracker = find(PageNavigationHoverRegion.TrackingView.self, in: host.view),
                  let event = NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
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
                        abs(rect.minY - content.minY) <= 1 && abs(rect.height - height) <= 1
                            && rect.contains(NSPoint(x: content.minX + 24, y: content.minY + 3))
                            && rect.contains(NSPoint(x: content.maxX - 24, y: content.minY + height - 3))
                    }
                }
                try check(coversBottom(16) && coversBottom(50)
                          && rectangles.allSatisfy { !$0.contains(NSPoint(x: content.midX, y: content.minY + 135)) },
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
        try check(defaults.object(forKey: "pageNavigationMode") == nil,
                  "the page-navigation fixture starts without a saved mode")
        for mode in ["windowed", "Full Page", "native full screen"] {
            presentation.fullPage = mode == "Full Page"
            if mode == "native full screen" {
                NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
            }
            try wait("\(mode) exposes the collapsed bottom navigation after native transitions") {
                navigationSettled() && visible(handleID) && !visible("page-carousel") && !visible(reservationID)
            }
            let base = reference()
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
            let bottomEdge = host.view.isFlipped ? revealed.maxY : revealed.minY
            try check(abs((host.view.isFlipped ? bar.maxY : bar.minY) - bottomEdge) <= 2,
                      "\(mode) anchors the revealed carousel at the bottom of the page viewport")
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
        _ = try enterZoomText("75")
        window.makeFirstResponder(nil)
        try wait("losing focus commits a valid percentage without a percent sign") { currentScroll()?.zoomSetting == .scale(0.75) }
        try press("page-zoom-fit-width")
        try wait("Fit Width on the footer fits the new page and marks the button selected") {
            currentScroll()?.fitsPageWidth == true && button("page-zoom-fit-width")?.value == "Selected"
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
        return checks
    }
}
#endif
