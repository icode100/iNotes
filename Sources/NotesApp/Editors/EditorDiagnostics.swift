#if os(macOS)
import AppKit
import SwiftUI
import NotesCore
import PencilKit
import PDFKit

/// Models a key window with a local pointer position for stationary-cursor
/// tests without activating this offscreen app or moving the user's pointer.
private final class EditorDiagnosticWindow: NSWindow {
    var testPointerLocation: NSPoint?
    override var isKeyWindow: Bool { testPointerLocation != nil || super.isKeyWindow }
    override var mouseLocationOutsideOfEventStream: NSPoint {
        testPointerLocation ?? super.mouseLocationOutsideOfEventStream
    }
}

/// Explicitly invoked by --self-test. No global input events or user files are used.
@MainActor
enum EditorDiagnostics {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws -> String {
        guard Bundle.main.bundleIdentifier != nil else {
            throw Failure(description: "Run --editor-test from the packaged iNotes.app; PencilKit requires an application bundle identifier.")
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: "Editor diagnostic failed: \(message)") }
            checks += 1
        }

        _ = NSApplication.shared
        var text = "Native editing — café 日本語 📝"
        var rtf: Data?
        let richEditor = RichTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            rtfData: Binding(get: { rtf }, set: { rtf = $0 })
        )
        let hosting = NSHostingView(rootView: richEditor)
        let window = EditorDiagnosticWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        func findTextView(_ view: NSView) -> NSTextView? {
            if let result = view as? NSTextView { return result }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        guard let editor = findTextView(hosting) else { throw Failure(description: "Rich text view was not mounted") }
        try check(editor.isEditable && editor.isSelectable && editor.allowsUndo, "native editing and undo enabled")
        try check(editor.bounds.width > 100 && (editor.textContainer?.containerSize.width ?? 0) > 100,
                  "editor has usable text width after layout (view: \(editor.bounds.width), container: \(editor.textContainer?.containerSize.width ?? 0))")
        try check(editor.string == text, "initial Unicode text")
        try check(window.makeFirstResponder(editor), "editor accepts keyboard focus")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("\nSecond line", replacementRange: editor.selectedRange())
        try check(text.hasSuffix("Second line"), "native typing updates binding")
        guard let encodedRTF = rtf else { throw Failure(description: "Native typing did not serialize RTF") }
        let decoded = try NSAttributedString(data: encodedRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        try check(decoded.string == text, "rich text Unicode roundtrip")

        editor.setSelectedRange(NSRange(location: 0, length: 6))
        RichTextEditor.perform(.heading)
        let headingFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check(headingFont?.pointSize == 26, "heading formatting")
        RichTextEditor.perform(.body)
        let bodyFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check(bodyFont?.pointSize == 16, "body formatting")
        RichTextEditor.perform(.bold)
        let boldFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "bold formatting")
        RichTextEditor.perform(.bold)
        let normalFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check(normalFont.map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "bold toggles off")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        RichTextEditor.perform(.checklist)
        try check(text.hasSuffix("☐ Second line"), "checklist insertion")
        // Each toolbar click normally arrives in its own AppKit event. These
        // synthetic calls share one event, so isolate the toggle's undo history.
        editor.breakUndoCoalescing()
        guard let textUndo = editor.undoManager else { throw Failure(description: "Native text undo manager is unavailable") }
        textUndo.removeAllActions()
        textUndo.beginUndoGrouping()
        RichTextEditor.perform(.checklist)
        editor.breakUndoCoalescing()
        textUndo.endUndoGrouping()
        try check(text.hasSuffix("☑ Second line"), "checklist toggle")
        try check(textUndo.canUndo, "checklist toggle registers native undo")
        textUndo.undo()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        try check(text.hasSuffix("☐ Second line"), "native text undo (binding: \(text); view: \(editor.string); redo: \(textUndo.canRedo))")
        textUndo.redo()
        try check(text.hasSuffix("☑ Second line") && editor.string == text, "native text redo updates model and view")

        let canvas = InkDocumentView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        canvas.tool = .pen; canvas.lineWidth = 6; canvas.colorHex = "#30343B"
        let penCursor = canvas.tipCursor(magnification: 1)
        let zoomedCursor = canvas.tipCursor(magnification: 2)
        guard let penCursorTIFF = penCursor.image.tiffRepresentation, let penCursorBitmap = NSBitmapImageRep(data: penCursorTIFF),
              let zoomCursorTIFF = zoomedCursor.image.tiffRepresentation, let zoomCursorBitmap = NSBitmapImageRep(data: zoomCursorTIFF) else {
            throw Failure(description: "Cannot render the native pen-tip cursor")
        }
        func cursorAlphaBounds(_ bitmap: NSBitmapImageRep) -> NSRect {
            var result = NSRect.null
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 { result = result.union(NSRect(x: x, y: y, width: 1, height: 1)) }
            } }
            return result
        }
        let tipBounds = cursorAlphaBounds(penCursorBitmap), zoomTipBounds = cursorAlphaBounds(zoomCursorBitmap)
        try check(!tipBounds.isNull && penCursorBitmap.colorAt(x: penCursorBitmap.pixelsWide / 2, y: penCursorBitmap.pixelsHigh / 2)!.alphaComponent > 0.9
                  && penCursorBitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0, "pen pointer renders a filled dot with transparent corners rather than crosshairs")
        try check(zoomTipBounds.width >= tipBounds.width * 1.6 && zoomTipBounds.width <= tipBounds.width * 2.4, "native pen-tip artwork grows with actual page magnification")
        try check(penCursor.hotSpot == NSPoint(x: penCursor.image.size.width / 2, y: penCursor.image.size.height / 2)
                  && canvas.tipCursor(magnification: 1) === penCursor, "native pen cursor keeps the ink point centered and reuses cached artwork")
        canvas.lineWidth = 3; canvas.tool = .highlighter
        guard let highlighterCursorTIFF = canvas.tipCursor(magnification: 1).image.tiffRepresentation,
              let highlighterCursorBitmap = NSBitmapImageRep(data: highlighterCursorTIFF) else { throw Failure(description: "Cannot render native chisel-tip cursor") }
        let cx = highlighterCursorBitmap.pixelsWide / 2, cy = highlighterCursorBitmap.pixelsHigh / 2
        let offset = max(2, highlighterCursorBitmap.pixelsWide / 6)
        let diagonalA = highlighterCursorBitmap.colorAt(x: cx + offset, y: cy - offset)?.alphaComponent ?? 0
        let diagonalB = highlighterCursorBitmap.colorAt(x: cx + offset, y: cy + offset)?.alphaComponent ?? 0
        try check(max(diagonalA, diagonalB) > 0.5 && min(diagonalA, diagonalB) < 0.25,
                  "highlighter pointer renders a slanted chisel tip instead of a dot")
        canvas.tool = .pen; canvas.lineWidth = 2.5
        var committed: [InkStroke] = []
        canvas.onChange = { committed = $0 }
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, pressure: Float, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers,
                                                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                clickCount: 1, pressure: pressure) else {
                throw Failure(description: "Cannot construct local canvas event")
            }
            return event
        }
        // Feed local tablet-tagged NSEvents directly to the view. No events are
        // posted globally and this does not claim physical tablet verification.
        func tabletEvent(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, pressure: Float) throws -> NSEvent {
            guard let cgEvent = try event(type == .tabletPoint ? .leftMouseDragged : type, x: x, y: y, pressure: pressure).cgEvent else {
                throw Failure(description: "Cannot construct local tablet event")
            }
            if type == .tabletPoint { cgEvent.type = .tabletPointer }
            cgEvent.setIntegerValueField(.mouseEventSubtype, value: 1)
            cgEvent.setIntegerValueField(.tabletEventDeviceID, value: 17)
            cgEvent.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
            cgEvent.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
            guard let result = NSEvent(cgEvent: cgEvent), result.isPenPointEvent else {
                throw Failure(description: "Local tablet event lost its tablet subtype")
            }
            return result
        }
        let down = try event(.leftMouseDown, x: 100, y: 100, pressure: 0.2)
        let drag = try event(.leftMouseDragged, x: 180, y: 150, pressure: 0.8)
        let up = try event(.leftMouseUp, x: 180, y: 150, pressure: 0)
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)
        try check(committed.count == 1 && committed[0].points.count == 2, "mouse gesture saves one stroke")
        try check(committed[0].pressureResponse == .baseWidth && committed[0].points.allSatisfy { $0.pressure == 0 }
                  && committed[0].points.allSatisfy { committed[0].renderedWidth(at: $0) == 2.5 },
                  "ordinary mouse drawing stays at the selected base width despite synthesized mouse pressure")
        canvas.undo(nil)
        try check(committed.isEmpty && canvas.strokes.isEmpty, "drawing undo")
        canvas.redo(nil)
        try check(committed.count == 1 && canvas.strokes.count == 1, "drawing redo")
        canvas.tool = .eraser
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: up)
        try check(committed.isEmpty, "stroke eraser")
        canvas.undo(nil)
        try check(committed.count == 1, "eraser undo")
        let pressureCanvas = InkDocumentView(frame: canvas.frame)
        pressureCanvas.tool = .pen; pressureCanvas.lineWidth = 6
        let tabletDown = try tabletEvent(.leftMouseDown, x: 100, y: 200, pressure: 0)
        let tabletMid = try tabletEvent(.leftMouseDragged, x: 200, y: 200, pressure: 0.25)
        let tabletHard = try tabletEvent(.leftMouseDragged, x: 300, y: 200, pressure: 1)
        pressureCanvas.mouseDown(with: tabletDown)
        pressureCanvas.mouseDragged(with: tabletMid)
        pressureCanvas.mouseDragged(with: tabletHard)
        pressureCanvas.mouseUp(with: try tabletEvent(.leftMouseUp, x: 300, y: 200, pressure: 0))
        let pressured = pressureCanvas.strokes[0]
        try check(pressured.points.map(\.pressure) == [tabletDown, tabletMid, tabletHard].map(\.normalizedInkPressure),
                  "tablet event pressure preserves the actual zero, fractional and maximum source samples")
        try check(pressured.renderedWidth(at: pressured.points[0]) == 6
                  && abs(pressured.renderedWidth(at: pressured.points[1]) - 7.5) < 0.001
                  && pressured.renderedWidth(at: pressured.points[2]) == 12,
                  "tablet pressure grows from the selected nib without thinning below it")
        pressureCanvas.undo(nil); pressureCanvas.redo(nil)
        try check(pressureCanvas.strokes == [pressured], "pressure response and all samples survive native drawing undo and redo")
        let fineTabletDown = try tabletEvent(.leftMouseDown, x: 100, y: 240, pressure: 0.25)
        let fineTabletDrag = try tabletEvent(.leftMouseDragged, x: 100, y: 240, pressure: 0.250061)
        pressureCanvas.mouseDown(with: fineTabletDown)
        pressureCanvas.mouseDragged(with: fineTabletDrag)
        pressureCanvas.mouseUp(with: try tabletEvent(.leftMouseUp, x: 100, y: 240, pressure: 0))
        try check(pressureCanvas.strokes.last?.points.count == 1
                  && fineTabletDrag.normalizedInkPressure > fineTabletDown.normalizedInkPressure
                  && pressureCanvas.strokes.last?.points[0].pressure == fineTabletDrag.normalizedInkPressure,
                  "stationary tablet force refines the dot without losing hardware precision or accumulating duplicate positions")
        pressureCanvas.mouseDown(with: try tabletEvent(.leftMouseDown, x: 100, y: 280, pressure: 0.1))
        let standaloneTablet = try tabletEvent(.tabletPoint, x: 180, y: 280, pressure: 0.75321)
        pressureCanvas.tabletPoint(with: standaloneTablet)
        pressureCanvas.mouseUp(with: try tabletEvent(.leftMouseUp, x: 180, y: 280, pressure: 0))
        try check(standaloneTablet.type == .tabletPoint && pressureCanvas.strokes.last?.points.last?.pressure == standaloneTablet.normalizedInkPressure,
                  "standalone tablet-point events and tablet mouse subtypes share normalized pressure capture")
        let zeroCG = tabletDown.cgEvent!
        zeroCG.setDoubleValueField(.mouseEventPressure, value: 1)
        let authoritativeZero = NSEvent(cgEvent: zeroCG)!
        try check(authoritativeZero.safeInkPressure == 1 && authoritativeZero.normalizedInkPressure == 0,
                  "a genuine tablet zero overrides a stale full mouse-pressure field")
        let missingCG = try event(.leftMouseDragged, x: 100, y: 100, pressure: 0.8).cgEvent!
        missingCG.setIntegerValueField(.mouseEventSubtype, value: 1)
        let legacyTablet = NSEvent(cgEvent: missingCG)!
        try check(legacyTablet.normalizedInkPressure == Double(legacyTablet.safeInkPressure ?? 0)
                  && legacyTablet.normalizedInkPressure > 0,
                  "a legacy mouse-emulating driver without tablet record fields retains its fallback pressure")
        guard let png = InkExport.png(strokes: committed), let bitmap = NSBitmapImageRep(data: png) else {
            throw Failure(description: "Cannot render PNG")
        }
        try check(bitmap.pixelsWide == 1600 && bitmap.pixelsHigh == 2200, "PNG export dimensions")
        let pdf = InkExport.pdf(strokes: committed)
        try check(pdf.starts(with: Data("%PDF-".utf8)), "PDF export is a valid PDF stream")

        let source = InkStroke(points: [InkPoint(x: 10, y: 20, pressure: 0.5), InkPoint(x: 60, y: 40), InkPoint(x: 110, y: 20)],
                               colorHex: "#336699", width: 4)
        let pencilDrawing = PortableInkConverter.drawing(from: [source])
        try check(pencilDrawing.strokes.count == 1 && pencilDrawing.strokes[0].path.count == 3, "Mac ink constructs a PencilKit path")
        let nativeData = pencilDrawing.dataRepresentation()
        let nativeRoundtrip = try PKDrawing(data: nativeData)
        try check(nativeRoundtrip.strokes.count == 1, "PencilKit serialization")
        let transformed = nativeRoundtrip.transformed(using: CGAffineTransform(translationX: 40, y: 60))
        let returned = PortableInkConverter.strokes(from: transformed)
        try check(returned.count == 1 && (returned[0].points.count > 3), "PencilKit curve sampled into portable ink")
        try check(abs((returned.first?.points.first?.x ?? 0) - 50) < 2 && abs((returned.first?.points.first?.y ?? 0) - 80) < 2,
                  "PencilKit lasso translation is retained")
        try check(returned[0].colorHex == "#336699" && returned[0].width.isFinite && returned[0].width > 0,
                  "PencilKit color and width are retained")
        var maskedStroke = pencilDrawing.strokes[0]
        maskedStroke.mask = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 55, height: 100))
        let visible = PortableInkConverter.strokes(from: PKDrawing(strokes: [maskedStroke]))
        try check(!visible.isEmpty && visible.flatMap(\.points).allSatisfy { $0.x <= 56 }, "PencilKit erasure mask does not resurrect hidden ink")
        let dot = PortableInkConverter.drawing(from: [InkStroke(points: [InkPoint(x: 20, y: 30)])])
        try check(!PortableInkConverter.strokes(from: dot).flatMap(\.points).isEmpty, "PencilKit single point ink survives conversion")

        let nativePressurePoints = [0.3, 2.0, 4.0].enumerated().map { index, force in
            PKStrokePoint(location: CGPoint(x: 100 + index * 100, y: 100), timeOffset: Double(index) / 120,
                          size: CGSize(width: 3 + index * 3, height: 3 + index * 3), opacity: 0.8,
                          force: force, azimuth: 0.4, altitude: 0.9, secondaryScale: 1.2)
        }
        let nativePressure = PKStroke(ink: PKInk(.pen, color: .black),
                                     path: PKStrokePath(controlPoints: nativePressurePoints, creationDate: Date(timeIntervalSince1970: 123)),
                                     transform: CGAffineTransform(translationX: 5, y: 7),
                                     mask: NSBezierPath(rect: CGRect(x: 0, y: 0, width: 500, height: 500)), randomSeed: 42)
        let nativePortable = try PortableInkConverter.validatedStrokes(from: PKDrawing(strokes: [nativePressure]))
        let nativeWidths = nativePortable.flatMap(\.points).compactMap(\.renderedWidth)
        try check((nativeWidths.max() ?? 0) - (nativeWidths.min() ?? 0) > 5,
                  "native Pencil forces above average retain rendered thickness instead of saturating at force one")
        let nativePortableReload = try JSONDecoder().decode([InkStroke].self, from: JSONEncoder().encode(nativePortable))
        try check(nativePortableReload == nativePortable, "native rendered widths survive portable save and reload")
        let nativeRebuilt = try PortableInkConverter.validatedDrawing(nil, fallback: nativePortableReload)
        try check(abs((nativeRebuilt.strokes.first?.path.first?.size.width ?? 0) - (nativeWidths.first ?? 0)) < 0.001,
                  "native width metadata controls the reconstructed PencilKit nib")
        guard let flooredNative = PortableInkConverter.applyingMinimumWidth(5, to: nativePressure) else {
            throw Failure(description: "Native pressure minimum did not adjust thin points")
        }
        try check(flooredNative.path[0].size.width == 5 && flooredNative.path[1].size.width == 6
                  && flooredNative.path[2].size.width == 9 && nativePressure.path[0].size.width == 3,
                  "completed native pressure floor only thickens points below the chosen minimum")
        try check(flooredNative.randomSeed == nativePressure.randomSeed && flooredNative.transform == nativePressure.transform
                  && flooredNative.path.creationDate == nativePressure.path.creationDate && flooredNative.mask?.bounds == nativePressure.mask?.bounds
                  && flooredNative.path[0].force == nativePressure.path[0].force && flooredNative.path[0].opacity == nativePressure.path[0].opacity
                  && flooredNative.path[0].azimuth == nativePressure.path[0].azimuth
                  // Public point reconstruction re-quantizes tilt (~2.4e-5 rad)
                  // and secondary scale (~1.2e-8), measured on stored native paths.
                  && abs(flooredNative.path[0].altitude - nativePressure.path[0].altitude) < 0.00005
                  && abs(flooredNative.path[0].secondaryScale - nativePressure.path[0].secondaryScale) < 0.0000001,
                  "native pressure correction preserves transform, mask, seed, time, force, opacity and tilt")
        try check(PortableInkConverter.applyingMinimumWidth(5, to: flooredNative) == nil,
                  "native pressure floor is idempotent and avoids replacing unchanged drawings")

        for style in InkStyle.allCases {
            let styled = InkStroke(points: source.points, colorHex: source.colorHex, width: 5, style: style)
            let roundtrip = PortableInkConverter.strokes(from: PortableInkConverter.drawing(from: [styled]))
            try check(roundtrip.first?.style == style, "\(style.rawValue) survives PencilKit interchange")
            canvas.tool = InkTool(rawValue: style.rawValue) ?? .pen
            canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
            try check(canvas.strokes.last?.style == style, "\(style.rawValue) gesture saves its instrument")
        }
        let highlight = InkStroke(points: [InkPoint(x: 100, y: 100), InkPoint(x: 200, y: 100), InkPoint(x: 300, y: 100)],
                                  colorHex: "#000000", width: 6, style: .highlighter)
        guard let highlighterPNG = InkExport.png(strokes: [highlight], paper: .blank),
              let highlighterBitmap = NSBitmapImageRep(data: highlighterPNG),
              let gridPNG = InkExport.png(strokes: [], paper: .grid), let gridBitmap = NSBitmapImageRep(data: gridPNG) else {
            throw Failure(description: "Cannot render drawing instruments or grid paper")
        }
        func brightness(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
            let direct = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1
            let reflected = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - y - 1)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1
            return min(direct, reflected)
        }
        let highlightCenter = brightness(highlighterBitmap, x: 200, y: 100)
        let highlightSegment = brightness(highlighterBitmap, x: 150, y: 100)
        try check(highlightCenter > 0.6 && highlightCenter < 0.9, "highlighter is translucent")
        try check(abs(highlightCenter - highlightSegment) < 0.04, "highlighter joins do not accumulate dark seams")
        for style in InkStyle.allCases {
            let localPressure = InkStroke(points: [InkPoint(x: 100, y: 140, pressure: 0), InkPoint(x: 160, y: 140, pressure: 0),
                                                   InkPoint(x: 240, y: 140, pressure: 1), InkPoint(x: 300, y: 140, pressure: 1)],
                                          colorHex: "#000000", width: 8, style: style, pressureResponse: .baseWidth)
            guard let pressurePNG = InkExport.png(strokes: [localPressure], paper: .blank),
                  let pressureBitmap = NSBitmapImageRep(data: pressurePNG) else { throw Failure(description: "Cannot rasterize pressure response") }
            func thickness(at x: Int) -> Int { (65..<215).filter { brightness(pressureBitmap, x: x, y: $0) < 0.95 }.count }
            let light = thickness(at: 125), hard = thickness(at: 275)
            try check(light >= 8 && hard >= light * 17 / 10,
                      "\(style.rawValue) raster grows locally under pressure and never shrinks below the selected nib")
            if style == .highlighter {
                try check(abs(brightness(pressureBitmap, x: 240, y: 140) - brightness(pressureBitmap, x: 275, y: 140)) < 0.04,
                          "variable-pressure highlighter remains translucent without darker segment seams")
            }
        }
        let verticalRule = brightness(gridBitmap, x: 28, y: 50), horizontalRule = brightness(gridBitmap, x: 50, y: 28)
        try check(verticalRule < 0.995 && horizontalRule < 0.995,
                  "grid paper has vertical and horizontal ruling (\(verticalRule), \(horizontalRule))")

        var pageText = "Typed text and handwriting on one page"
        var pageRTF: Data?
        var pageStrokes = [InkStroke(points: [InkPoint(x: 100, y: 180), InkPoint(x: 300, y: 180)], width: 6)]
        var pageNativeInk: Data?
        let sharedEditor = UnifiedPageEditor(text: Binding(get: { pageText }, set: { pageText = $0 }),
                                             rtfData: Binding(get: { pageRTF }, set: { pageRTF = $0 }),
                                             strokes: Binding(get: { pageStrokes }, set: { pageStrokes = $0 }),
                                             pencilKitData: Binding(get: { pageNativeInk }, set: { pageNativeInk = $0 }),
                                             tool: .text, paper: .grid)
        let sharedHost = NSHostingView(rootView: sharedEditor)
        window.contentView = sharedHost
        sharedHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        func findPage(_ view: NSView) -> UnifiedMacPageView? {
            if let page = view as? UnifiedMacPageView { return page }
            return view.subviews.lazy.compactMap(findPage).first
        }
        guard let page = findPage(sharedHost) else { throw Failure(description: "Shared page did not mount") }
        guard let pageScroll = page.enclosingScrollView else { throw Failure(description: "Shared page scroll view did not mount") }
        try check(page.textView.string == pageText && page.inkView.strokes == pageStrokes, "text and ink mount on the same paper")
        try check(pageScroll.contentView is CenteredPageClipView, "shared page uses the centering clip without a replacement document hierarchy")
        pageScroll.magnification = 0.25
        pageScroll.contentView.scroll(to: .zero)
        pageScroll.layoutSubtreeIfNeeded()
        try check(abs(pageScroll.contentView.bounds.midX - page.frame.midX) < 1,
                  "zoomed-out paper is horizontally centered in its workspace")
        try check(pageScroll.documentView === page && page.textView.superview === page,
                  "centering preserves page input and text tracking owners")
        let constrained = pageScroll.contentView.constrainBoundsRect(NSRect(x: 0, y: 0, width: 2400, height: 2600))
        try check(abs(constrained.midX - page.frame.midX) < 1 && abs(constrained.midY - page.frame.midY) < 1,
                  "page centers in both dimensions whenever the whole sheet fits")
        pageScroll.magnification = 1
        pageScroll.contentView.scroll(to: .zero)
        try check(!page.textView.drawsBackground && !page.inkView.drawsPaper
                  && page.subviews.firstIndex(of: page.textView)! < page.subviews.firstIndex(of: page.inkView)!
                  && page.subviews.last === page.selectionView && !page.selectionView.isOpaque,
                  "transparent ink overlays typed text on the same paper")
        let textPoint = page.convert(NSPoint(x: 80, y: 80), to: page.superview)
        try check(page.hitTest(textPoint) === page.textView, "text tool routes mouse input to native rich text")
        var unrelatedEvents: [NSEvent] = []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                             isARepeat: false, keyCode: 0) else { throw Failure(description: "Cannot construct key regression event") }
            unrelatedEvents.append(key)
        }
        guard let cursor = NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil) else {
            throw Failure(description: "Cannot construct cursor-update regression event")
        }
        unrelatedEvents.append(cursor)
        for type in [NSEvent.EventType.appKitDefined, .systemDefined, .applicationDefined] {
            guard let other = NSEvent.otherEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: NSEvent.EventSubtype.tabletPoint.rawValue,
                                                 data1: 0, data2: 0) else { throw Failure(description: "Cannot construct menu/system regression event") }
            unrelatedEvents.append(other)
        }
        for unrelated in unrelatedEvents {
            try check(!unrelated.isPenPointEvent && !unrelated.isPenProximityEvent && unrelated.safeInkPressure == nil
                      && page.inputView(at: NSPoint(x: 80, y: 80), event: unrelated) === page.textView,
                      "key/cursor/menu event type \(unrelated.type.rawValue) routes safely without tablet-only getters")
        }
        // Exercise native cursor ownership, not just the generated artwork.
        // NSTextView can receive a late update after the toolbar changed tools.
        let cursorBox = PageTextBox(x: 200, y: 140, width: 200, text: "Cursor regression")
        page.displayObjects(textBoxes: [cursorBox], equations: [], editable: true,
                            onTextBoxChange: { _, _, _ in }, onEquationEdit: nil)
        guard let boxEditor = page.textBoxViews[cursorBox.id]?.editor else {
            throw Failure(description: "Cursor test text box did not mount")
        }
        defer { NSCursor.arrow.set() }
        for tool in [InkTool.pen, .pencil, .marker, .highlighter, .line, .eraser, .select, .lasso] {
            page.activeTool = tool
            try check(!page.textView.isEditable && !page.textView.isSelectable && !boxEditor.isEditable && !boxEditor.isSelectable,
                      "\(tool.rawValue) retires native text interaction and its internal hover tracking")
            let expected = page.activePageCursor!
            NSCursor.iBeam.set()
            page.cursorUpdate(with: cursor)
            try check(NSCursor.current === expected, "\(tool.rawValue) parent page owns cursor updates")
            NSCursor.iBeam.set()
            page.selectionView.cursorUpdate(with: cursor)
            try check(NSCursor.current === expected, "\(tool.rawValue) overlay cursor updates resolve through the page responder chain")
            try check(pageScroll.documentCursor === expected, "\(tool.rawValue) keeps the enclosing scroll document cursor synchronized")
            for nativeText in [page.textView, boxEditor] {
                NSCursor.iBeam.set()
                nativeText.cursorUpdate(with: cursor)
                try check(NSCursor.current === expected,
                          "\(tool.rawValue) replaces stale I-beam from native body and movable text cursor updates")
            }
            if page.inkView.showsTipCursor {
                NSCursor.iBeam.set()
                page.inkView.cursorUpdate(with: cursor)
                try check(NSCursor.current === expected, "\(tool.rawValue) ink tracking restores the live tip")
            }
        }
        page.activeTool = .pen
        page.inkView.updateTrackingAreas()
        try check(page.inkView.trackingAreas.contains { $0.options.contains([.cursorUpdate, .inVisibleRect, .activeInKeyWindow]) },
                  "ink has cursor tracking over the visible page")
        guard let entry = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                                 trackingNumber: 0, userData: nil) else { throw Failure(description: "Cannot create local entry event") }
        NSCursor.iBeam.set()
        page.inkView.mouseEntered(with: entry)
        try check(NSCursor.current === page.inkView.tipCursor(), "entering paper replaces the I-beam with the pen dot")
        window.testPointerLocation = page.convert(NSPoint(x: 80, y: 80), to: nil)
        NSCursor.iBeam.set()
        page.focus(tool: .pen)
        try check(NSCursor.current === page.inkView.tipCursor(), "reselecting unchanged Pen repairs a stationary stale I-beam (key: \(window.isKeyWindow), visible: \(page.visibleRect), point: \(page.convert(window.mouseLocationOutsideOfEventStream, from: nil)), hidden: \(page.isHiddenOrHasHiddenAncestor))")
        let thinCursor = page.inkView.tipCursor()
        page.inkView.lineWidth = 12
        page.textView.cursorUpdate(with: cursor)
        try check(NSCursor.current === page.inkView.tipCursor() && NSCursor.current !== thinCursor && pageScroll.documentCursor === NSCursor.current,
                  "text-layer cursor updates use the current pen width")
        pageScroll.magnification = 1.5
        boxEditor.cursorUpdate(with: cursor)
        try check(NSCursor.current === page.inkView.tipCursor() && pageScroll.documentCursor === NSCursor.current,
                  "textbox and document cursor updates follow page zoom")
        pageScroll.magnification = 1
        // Outside the clipped viewport, reselecting a tool must not replace a
        // toolbar/search cursor, even if the point is within the long page.
        window.testPointerLocation = page.convert(NSPoint(x: 80, y: 1800), to: nil)
        NSCursor.iBeam.set()
        page.focus(tool: .pen)
        try check(NSCursor.current === NSCursor.iBeam, "offscreen paper does not override cursors outside the viewport")
        window.testPointerLocation = nil
        page.inkView.lineWidth = 2.5
        page.activeTool = .text
        try check(page.textView.isEditable && page.textView.isSelectable && boxEditor.isEditable && boxEditor.isSelectable,
                  "Text restores native body and movable textbox interaction")
        try check(pageScroll.documentCursor === NSCursor.iBeam, "Text restores the enclosing document I-beam")
        for nativeText in [page.textView, boxEditor] {
            NSCursor.arrow.set()
            nativeText.cursorUpdate(with: cursor)
            try check(NSCursor.current === NSCursor.iBeam, "returning to Text restores the native I-beam")
        }
        try check(!page.inkView.showsTipCursor && !page.inkView.trackingAreas.contains { $0.options.contains(.cursorUpdate) },
                  "Text mode removes ink cursor tracking")
        page.displayObjects(textBoxes: [], equations: [], editable: true, onTextBoxChange: { _, _, _ in }, onEquationEdit: nil)
        try check(!UnifiedMacPageView.inputIsTablet(event: nil), "no current event is safe during view layout")
        try check(!down.isPenPointEvent && !down.isPenProximityEvent && down.safeInkPressure != nil,
                  "ordinary mouse input retains valid pressure sampling")
        let moved = try event(.mouseMoved, x: 100, y: 100, pressure: 0)
        try check(!moved.isPenPointEvent && !moved.isPenProximityEvent && moved.safeInkPressure == nil,
                  "mouse hover never reads the unsupported pressure getter")
        guard let tabletMouse = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .left) else {
            throw Failure(description: "Cannot construct local tablet mouse regression event")
        }
        tabletMouse.setIntegerValueField(.mouseEventSubtype, value: Int64(NSEvent.EventSubtype.tabletPoint.rawValue))
        guard let tabletMouseEvent = NSEvent(cgEvent: tabletMouse) else { throw Failure(description: "Cannot wrap local tablet mouse event") }
        try check(tabletMouseEvent.isPenPointEvent && !tabletMouseEvent.isPenProximityEvent
                  && page.inputView(at: NSPoint(x: 80, y: 80), event: tabletMouseEvent) === page.textView,
                  "Text tool routes actual tablet mouse subtype to the native caret")
        try check(page.inputView(at: NSPoint(x: 12, y: 12), event: tabletMouseEvent) === page.textView,
                  "Text tool keeps blank page margins on the native typing path")
        page.focus(tool: .text)
        let textBeforeHover = pageText, inkBeforeHover = pageStrokes
        for nativeType in [CGEventType.tabletPointer, .tabletProximity] {
            guard let native = CGEvent(source: nil) else { throw Failure(description: "Cannot construct local native tablet event") }
            native.type = nativeType
            if nativeType == .tabletProximity { native.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1) }
            guard let nativeEvent = NSEvent(cgEvent: native) else { throw Failure(description: "Cannot wrap native tablet event") }
            try check(UnifiedMacPageView.inputIsTablet(event: nativeEvent), "native tablet event type \(nativeType.rawValue) short-circuits subtype access")
            if nativeType == .tabletProximity { page.tabletProximity(with: nativeEvent) }
            else { page.inkView.tabletPoint(with: nativeEvent) }
        }
        try check(window.firstResponder === page.textView && pageText == textBeforeHover && pageStrokes == inkBeforeHover,
                  "tablet hover and proximity preserve Text keyboard focus and saved page content")
        page.textView.setSelectedRange(NSRange(location: (pageText as NSString).length, length: 0))
        page.textView.undoManager?.beginUndoGrouping()
        page.textView.insertText(" vlpbhet VLPBHET हिन्दी 日本語", replacementRange: page.textView.selectedRange())
        page.textView.undoManager?.endUndoGrouping()
        try check(pageText == textBeforeHover + " vlpbhet VLPBHET हिन्दी 日本語" && page.textView.string == pageText,
                  "native Text typing retains every tool letter and Unicode after tablet hover")
        page.textView.undoManager?.undo()
        window.makeFirstResponder(page.inkView)
        // The notification's key-window guard is exercised by live UI QA;
        // this command-line application has no foreground AppKit lifecycle.
        page.focus(tool: .text)
        try check(window.firstResponder === page.textView, "explicitly focusing the already active Text tool restores native typing focus")
        page.activeTool = .pencil
        try check(page.hitTest(textPoint) === page.inkView && window.firstResponder === page.inkView
                  && page.inputView(at: NSPoint(x: 80, y: 80), event: tabletMouseEvent) === page.inkView,
                  "pencil tool focuses ink and routes both mouse and tablet points to the same page")
        let combinedPDF = UnifiedPageExport.pdf(text: pageText, rtfData: pageRTF, strokes: pageStrokes, paper: .grid)
        let combinedDocument = PDFDocument(data: combinedPDF)
        try check(combinedDocument?.pageCount == 1 && combinedDocument?.string?.contains(pageText) == true,
                  "unified PDF keeps searchable text on the same page as ink")
        guard let combinedPNG = UnifiedPageExport.png(text: pageText, rtfData: pageRTF, strokes: pageStrokes, paper: .blank),
              let combinedBitmap = NSBitmapImageRep(data: combinedPNG) else { throw Failure(description: "Cannot export unified page PNG") }
        let exportScale = Double(combinedBitmap.pixelsWide) / 1600
        let inkBrightness = brightness(combinedBitmap, x: Int(200 * exportScale), y: Int(180 * exportScale))
        try check(inkBrightness < 0.4, "unified export includes ink at shared page coordinates (scale: \(exportScale), brightness: \(inkBrightness))")
        let colored = NSMutableAttributedString(string: "White red", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        colored.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 6, length: 3))
        let coloredRTF = try colored.data(from: NSRange(location: 0, length: colored.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let colorCoordinator = RichTextEditor.Coordinator(RichTextEditor(text: .constant(colored.string), rtfData: .constant(coloredRTF), theme: .light))
        colorCoordinator.load(text: colored.string, rtf: coloredRTF, into: page.textView)
        let normalizedBlack = page.textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let preservedRed = page.textView.attributedString().attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
        let lightText = InkRenderer.color(PageTheme.light.textHex)
        try check(normalizedBlack?.usingColorSpace(.sRGB)?.isEqual(lightText.usingColorSpace(.sRGB)) == true && preservedRed?.usingColorSpace(.sRGB)?.redComponent == 1,
                  "white paper normalizes invisible text while preserving user colors")
        page.textView.string = String(repeating: "Reachable long page line\n", count: 300)
        page.resizePaperToContent()
        try check(page.frame.height > 2200 && page.inkView.frame.height == page.frame.height && page.textView.frame.maxY <= page.frame.height,
                  "long typed notes extend the shared paper instead of clipping")
        let lineCanvas = InkDocumentView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        lineCanvas.tool = .line
        var committedLines: [InkStroke] = []
        lineCanvas.onChange = { committedLines = $0 }
        lineCanvas.mouseDown(with: try event(.leftMouseDown, x: 100, y: 100, pressure: 0.4))
        lineCanvas.mouseDragged(with: try event(.leftMouseDragged, x: 200, y: 350, pressure: 0.5))
        lineCanvas.mouseDragged(with: try event(.leftMouseDragged, x: 400, y: 245, pressure: 0.8))
        lineCanvas.mouseUp(with: try event(.leftMouseUp, x: 400, y: 245, pressure: 0))
        try check(committedLines.count == 1 && committedLines[0].points.count == 2 && committedLines[0].style == .pen,
                  "straight-line gesture discards wobble and stores two pen endpoints")
        try check(committedLines[0].points.allSatisfy { $0.pressure == 0 }, "mouse straight lines keep a stable selected nib")
        try check(committedLines[0].points[0].x != committedLines[0].points[1].x && committedLines[0].points[0].y != committedLines[0].points[1].y,
                  "arbitrary line angles remain available")
        lineCanvas.undo(nil)
        try check(committedLines.isEmpty, "straight-line undo is one gesture")
        lineCanvas.redo(nil)
        try check(committedLines.count == 1 && committedLines[0].points.count == 2, "straight-line redo retains endpoints")
        let tabletLine = InkDocumentView(frame: canvas.frame)
        tabletLine.tool = .line; tabletLine.lineWidth = 4
        tabletLine.mouseDown(with: try tabletEvent(.leftMouseDown, x: 100, y: 100, pressure: 0.2))
        tabletLine.mouseDragged(with: try tabletEvent(.leftMouseDragged, x: 300, y: 100, pressure: 0.8))
        tabletLine.mouseUp(with: try tabletEvent(.leftMouseUp, x: 300, y: 100, pressure: 0))
        try check(abs(tabletLine.strokes[0].points[1].pressure - 0.8) < 0.001
                  && tabletLine.strokes[0].points.allSatisfy { tabletLine.strokes[0].renderedWidth(at: $0) >= 4 },
                  "tablet straight-line release retains contact pressure and never thins below its base")
        lineCanvas.mouseDown(with: down)
        lineCanvas.mouseDragged(with: try event(.leftMouseDragged, x: 400, y: 120, pressure: 0.7))
        lineCanvas.mouseUp(with: try event(.leftMouseUp, x: 400, y: 120, pressure: 0))
        let horizontal = committedLines.last!.points
        try check(horizontal[0].y == horizontal[1].y && horizontal[0].x != horizontal[1].x, "table line auto-snaps near horizontal")
        lineCanvas.mouseDown(with: down)
        lineCanvas.mouseDragged(with: try event(.leftMouseDragged, x: 120, y: 400, pressure: 0.7))
        lineCanvas.mouseUp(with: try event(.leftMouseUp, x: 120, y: 400, pressure: 0))
        let vertical = committedLines.last!.points
        try check(vertical[0].x == vertical[1].x && vertical[0].y != vertical[1].y, "table line auto-snaps near vertical")
        lineCanvas.mouseDown(with: down)
        lineCanvas.mouseDragged(with: try event(.leftMouseDragged, x: 260, y: 200, pressure: 0.7, modifiers: .shift))
        lineCanvas.mouseUp(with: try event(.leftMouseUp, x: 260, y: 200, pressure: 0, modifiers: .shift))
        let shifted = committedLines.last!.points
        try check(shifted[0].y == shifted[1].y, "Shift forces the closest table axis")
        lineCanvas.linePattern = .dashed
        lineCanvas.mouseDown(with: down)
        lineCanvas.mouseUp(with: try event(.leftMouseUp, x: 400, y: 100, pressure: 0))
        try check(committedLines.last?.linePattern == .dashed, "straight lines retain the selected dash pattern")
        lineCanvas.undo(nil)
        try check(committedLines.last?.linePattern == .solid, "patterned-line undo restores prior lines")
        lineCanvas.redo(nil)
        try check(committedLines.last?.linePattern == .dashed, "patterned-line redo preserves dash metadata")
        lineCanvas.tool = .pen
        lineCanvas.mouseDown(with: down); lineCanvas.mouseUp(with: up)
        try check(committedLines.last?.linePattern == .solid, "line pattern selection does not unexpectedly dash freehand pen strokes")
        let malformedCanvas = InkDocumentView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        // Create the legitimate dot through native input so its page point
        // follows AppKit's flipped-coordinate conversion on an unattached view.
        malformedCanvas.tool = .pen
        malformedCanvas.mouseDown(with: down); malformedCanvas.mouseUp(with: down)
        try check(malformedCanvas.strokes.count == 1 && malformedCanvas.strokes[0].points.count == 1,
                  "one-point pen gesture remains a valid visible dot")
        malformedCanvas.strokes.insert(InkStroke(points: []), at: 0)
        malformedCanvas.tool = .eraser
        malformedCanvas.mouseDown(with: down); malformedCanvas.mouseUp(with: down)
        try check(malformedCanvas.strokes.isEmpty, "eraser safely removes a legacy empty stroke and a valid one-point dot without constructing an invalid range")
        let boundedPage = UnifiedMacPageView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        boundedPage.inkView.strokes = [InkStroke(points: [InkPoint(x: 20, y: 1e12)])]
        boundedPage.resizePaperToContent()
        try check(boundedPage.bounds.height == InkGeometryLimits.maximumPageDimension,
                  "in-memory extreme geometry cannot create an unbounded Mac page or export")

        func renderAppearanceSample(strokes: [InkStroke] = [], paper: InkPaper = .blank,
                                    theme: PageTheme = .light, template: PageTemplate = .none,
                                    pattern: LinePattern = .solid) -> NSBitmapImageRep? {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let region = NSRect(x: 0, y: 0, width: 320, height: 240)
            graphics.cgContext.clip(to: region)
            InkRenderer.draw(strokes: strokes, paper: paper, in: region, theme: theme,
                             pageTemplate: template, templateLinePattern: pattern, pageBounds: region)
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return NSBitmapImageRep(data: data)
        }
        func pixelDistance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
            guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return 0 }
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        let excessivePattern = InkStroke(points: (0..<1_000).map {
            InkPoint(x: $0.isMultiple(of: 2) ? 100 : 1500, y: 100)
        }, width: 0.5, linePattern: .dotted)
        guard let rejectedPattern = renderAppearanceSample(strokes: [excessivePattern]),
              let emptyPattern = renderAppearanceSample() else { throw Failure(description: "Pattern budget sample did not render") }
        try check(rejectedPattern.representation(using: .png, properties: [:]) == emptyPattern.representation(using: .png, properties: [:]),
                  "renderer rejects excessive patterned work before constructing or stroking its native path")
        var lineCoverage: [LinePattern: Int] = [:]
        for pattern in LinePattern.allCases {
            let stroke = InkStroke(points: [InkPoint(x: 20, y: 120), InkPoint(x: 300, y: 120)],
                                   colorHex: "#30343B", width: 4, linePattern: pattern)
            guard let sample = renderAppearanceSample(strokes: [stroke]) else { throw Failure(description: "Line pattern did not render") }
            lineCoverage[pattern] = (25..<295).filter { x in
                pixelDistance(sample.colorAt(x: x, y: 119), sample.colorAt(x: x, y: 110)) > 0.5
            }.count
        }
        try check(lineCoverage[.solid]! > 260 && lineCoverage[.dashed]! > 80 && lineCoverage[.dashed]! < 250
                  && lineCoverage[.dotted]! > 30 && lineCoverage[.dotted]! < lineCoverage[.dashed]!,
                  "solid, dashed and dotted strokes render continuous, dashed and round-dot coverage respectively")
        for theme in PageTheme.allCases {
            for paper in InkPaper.allCases {
                for pattern in LinePattern.allCases {
                    guard let sample = renderAppearanceSample(paper: paper, theme: theme, template: .centerDivider, pattern: pattern) else {
                        throw Failure(description: "Template sample did not render")
                    }
                    let distinctPixels = (2..<238).filter { y in
                        pixelDistance(sample.colorAt(x: 160, y: y), sample.colorAt(x: 165, y: y)) > 0.15
                    }.count
                    try check(distinctPixels > 20, "\(theme.rawValue) \(paper.rawValue) paper has a visible \(pattern.rawValue) central divider")
                }
            }
            for paper in InkPaper.allCases {
                guard let sample = renderAppearanceSample(paper: paper, theme: theme, template: .leftMargin),
                      let plain = renderAppearanceSample(paper: paper, theme: theme) else { throw Failure(description: "Margin sample did not render") }
                let changedPixels = (2..<238).filter { y in
                    pixelDistance(sample.colorAt(x: 80, y: y), plain.colorAt(x: 80, y: y)) > 0.15
                }.count
                try check((paper == .blank || paper == .ruled) ? changedPixels > 20 : changedPixels == 0,
                          "left margin is restricted to ruled and plain paper in \(theme.rawValue)")
            }
        }
        guard let vintageSample = renderAppearanceSample(theme: .vintage) else { throw Failure(description: "Vintage paper did not render") }
        let vintagePixel = vintageSample.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!
        try check(vintagePixel.redComponent > 0.9 && vintagePixel.blueComponent < 0.9,
                  "vintage paper renders off-white independently of the system appearance")
        // Theme rendering is a view transformation: all original pen colors,
        // geometry, and undo snapshots stay canonical when the paper changes.
        let canonicalThemeStrokes = [InkStroke(points: [InkPoint(x: 100, y: 180), InkPoint(x: 300, y: 180)], colorHex: "#30343B", width: 6)]
        guard let darkPNG = InkExport.png(strokes: canonicalThemeStrokes, paper: .blank, theme: .dark),
              let darkBitmap = NSBitmapImageRep(data: darkPNG),
              let darkGridPNG = InkExport.png(strokes: [], paper: .grid, theme: .dark),
              let darkGridBitmap = NSBitmapImageRep(data: darkGridPNG),
              let lightGridPNG = InkExport.png(strokes: [], paper: .grid, theme: .light),
              let lightGridBitmap = NSBitmapImageRep(data: lightGridPNG),
              let darkDotPNG = InkExport.png(strokes: [], paper: .dotted, theme: .dark),
              let darkDotBitmap = NSBitmapImageRep(data: darkDotPNG) else {
            throw Failure(description: "Cannot render dark and light page themes")
        }
        func red(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
            Double(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 0)
        }
        func strongestRed(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
            max(red(bitmap, x: x, y: y), red(bitmap, x: x, y: bitmap.pixelsHigh - y - 1))
        }
        let darkPaperRed = red(darkBitmap, x: 900, y: 900)
        try check(darkPaperRed < 0.2, "dark page exports a dark paper background")
        try check(strongestRed(darkBitmap, x: 200, y: 180) > 0.75, "canonical dark pen renders light and readable on dark paper")
        let lightPaperRed = red(lightGridBitmap, x: 45, y: 45)
        let lightRuleRed = brightness(lightGridBitmap, x: 28, y: 45)
        let darkRuleRed = strongestRed(darkGridBitmap, x: 28, y: 45)
        try check(lightPaperRed - lightRuleRed > 0.25, "light grid ruling has visible contrast")
        try check(darkRuleRed - darkPaperRed > 0.2, "dark grid ruling has visible contrast")
        try check(strongestRed(darkDotBitmap, x: 28, y: 28) - darkPaperRed > 0.2, "dark dotted paper remains visible")
        page.inkView.strokes = canonicalThemeStrokes
        page.theme = .dark
        try check(page.inkView.theme == .dark && page.paperView.theme == .dark, "shared page applies the same theme to ink and paper")
        page.theme = .light
        try check(page.inkView.strokes == canonicalThemeStrokes && canonicalThemeStrokes[0].colorHex == "#30343B", "switching paper themes preserves canonical ink data")
        guard let themedPagePNG = UnifiedPageExport.png(text: "Shared dark page", rtfData: nil, strokes: canonicalThemeStrokes, paper: .grid, theme: .dark),
              let themedPageBitmap = NSBitmapImageRep(data: themedPagePNG) else { throw Failure(description: "Cannot export themed shared page") }
        try check(red(themedPageBitmap, x: 900, y: 900) < 0.2, "combined page PNG preserves the selected dark theme")
        let themedPDF = PDFDocument(data: UnifiedPageExport.pdf(text: "Shared dark page", rtfData: nil, strokes: canonicalThemeStrokes, paper: .grid, theme: .dark))
        try check(themedPDF?.string?.contains("Shared dark page") == true, "dark shared-page PDF keeps searchable text")
        func clippedPaper(_ requested: NSRect) -> NSBitmapImageRep? {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.cgContext.clip(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            InkRenderer.draw(strokes: [], paper: .grid, in: requested, theme: .dark)
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return NSBitmapImageRep(data: png)
        }
        guard let unboundedPaper = clippedPaper(.infinite),
              let oversizedPaper = clippedPaper(NSRect(x: -1_000_000_000, y: -1_000_000_000, width: 2_000_000_000, height: 2_000_000_000)) else {
            throw Failure(description: "Cannot render clipped paper regressions")
        }
        try check(abs(red(unboundedPaper, x: 12, y: 12) - darkPaperRed) < 0.01, "infinite AppKit dirty rectangles clip to the actual bitmap (actual: \(red(unboundedPaper, x: 12, y: 12)), expected: \(darkPaperRed))")
        try check(abs(red(oversizedPaper, x: 12, y: 12) - darkPaperRed) < 0.01, "oversized paper requests build only the visible grid")
        var themedBody = "Default custom"
        let canonicalText = NSMutableAttributedString(string: themedBody, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: ThemeTextAttributes.color("#30343B")
        ])
        canonicalText.addAttribute(.foregroundColor, value: ThemeTextAttributes.color("#102040"), range: NSRange(location: 8, length: 6))
        var themedRTF: Data? = try canonicalText.data(from: NSRange(location: 0, length: canonicalText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let originalRTF = themedRTF
        var textCallbacks = 0
        func themeEditor(_ theme: PageTheme) -> RichTextEditor {
            RichTextEditor(text: Binding(get: { themedBody }, set: { themedBody = $0 }),
                           rtfData: Binding(get: { themedRTF }, set: { themedRTF = $0 }), theme: theme,
                           onChange: { text, data in textCallbacks += 1; themedBody = text; themedRTF = data })
        }
        let themeCoordinator = RichTextEditor.Coordinator(themeEditor(.dark))
        let themeTextView = RichTextEditor.makeNativeTextView()
        themeTextView.delegate = themeCoordinator
        let themeScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        themeScroll.documentView = themeTextView
        window.contentView = themeScroll
        themeCoordinator.load(text: themedBody, rtf: themedRTF, into: themeTextView)
        let displayedCustom = themeTextView.attributedString().attribute(.foregroundColor, at: 8, effectiveRange: nil) as! NSColor
        try check(ThemeTextAttributes.hex(displayedCustom) == PageTheme.dark.resolvedInkHex("#102040"), "dark text lifts custom ink for readability")
        let canonicalCopy = ThemeTextAttributes.canonical(themeTextView.attributedString(), theme: .dark)
        let restoredCustom = canonicalCopy.attribute(.foregroundColor, at: 8, effectiveRange: nil) as! NSColor
        try check(ThemeTextAttributes.hex(restoredCustom) == "#102040", "custom rich-text ink restores its exact canonical color")
        themeCoordinator.parent = themeEditor(.light)
        themeCoordinator.load(text: themedBody, rtf: themedRTF, into: themeTextView)
        themeCoordinator.parent = themeEditor(.dark)
        themeCoordinator.load(text: themedBody, rtf: themedRTF, into: themeTextView)
        try check(textCallbacks == 0 && themedRTF == originalRTF, "theme-only rich-text switches never write notes or change stored RTF bytes")
        _ = window.makeFirstResponder(themeTextView)
        themeTextView.setSelectedRange(NSRange(location: (themedBody as NSString).length, length: 0))
        themeTextView.breakUndoCoalescing()
        guard let themeUndo = themeTextView.undoManager else { throw Failure(description: "Themed text undo is unavailable") }
        themeUndo.removeAllActions()
        themeUndo.beginUndoGrouping()
        themeTextView.insertText("!", replacementRange: themeTextView.selectedRange())
        themeTextView.breakUndoCoalescing()
        themeUndo.endUndoGrouping()
        try check(themedBody.hasSuffix("!") && textCallbacks > 0, "native dark-page typing updates the canonical model")
        guard let savedDarkRTF = themedRTF else { throw Failure(description: "Themed typing did not save rich text") }
        let savedDarkText = try NSAttributedString(data: savedDarkRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let savedCustom = savedDarkText.attribute(.foregroundColor, at: 8, effectiveRange: nil) as! NSColor
        try check(ThemeTextAttributes.hex(savedCustom) == "#102040" && savedDarkText.attribute(ThemeTextAttributes.canonicalColorKey, at: 8, effectiveRange: nil) == nil,
                  "dark-page edits persist original ink rather than the display pastel or private metadata")
        themeUndo.undo()
        try check(themedBody == "Default custom" && themeTextView.string == themedBody, "dark-page text undo keeps the model and view synchronized")
        themeUndo.redo()
        try check(themedBody == "Default custom!" && themeTextView.string == themedBody, "dark-page text redo keeps the model and view synchronized")
        let selectionPage = UnifiedMacPageView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        let selector = MacPageSelectionController()
        selector.history.groupsByEvent = false // diagnostics drive separate gestures without a run-loop boundary
        selector.page = selectionPage; selectionPage.selectionController = selector; selectionPage.selectionView.controller = selector
        selectionPage.textView.pageUndoManager = selector.history
        selectionPage.inkView.pageSelectionHistory = selector.history
        selectionPage.activeTool = .lasso
        let selectionBody = NSAttributedString(string: "Alpha Beta", attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: ThemeTextAttributes.color("#102040")])
        let selectionRTF = try selectionBody.data(from: NSRange(location: 0, length: selectionBody.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let selectionRich = RichTextEditor.Coordinator(RichTextEditor(text: .constant(selectionBody.string), rtfData: .constant(selectionRTF)))
        selectionRich.load(text: selectionBody.string, rtf: selectionRTF, into: selectionPage.textView)
        let alphaRange = NSRange(location: 0, length: 5)
        guard let alphaRect = selector.bodyRect(range: alphaRange) else { throw Failure(description: "Cannot lay out native selection glyphs") }
        let selectedInk = InkStroke(points: [InkPoint(x: alphaRect.minX - 10, y: alphaRect.midY), InkPoint(x: alphaRect.maxX + 10, y: alphaRect.midY)], colorHex: "#102040", width: 2)
        let untouchedInk = InkStroke(points: [InkPoint(x: 600, y: 400), InkPoint(x: 650, y: 440)], colorHex: "#B14D55", width: 3)
        let originalSelectionContent = PageContent(text: selectionBody.string, rtfData: selectionRTF, strokes: [selectedInk, untouchedInk])
        selector.load(originalSelectionContent)
        var selectionWrites = 0
        selector.onRender = { value in
            selectionRich.load(text: value.text, rtf: value.rtfData, into: selectionPage.textView)
            selectionPage.inkView.strokes = value.strokes
            selectionPage.displayObjects(textBoxes: value.textBoxes, equations: value.equations, editable: false, onTextBoxChange: { _,_,_ in }, onEquationEdit: nil)
            selectionPage.resizePaperToContent()
        }
        selector.onCommit = { _ in selectionWrites += 1 }
        selector.onRender?(originalSelectionContent)
        let lassoBounds = alphaRect.insetBy(dx: 0.3, dy: 0.3)
        selector.select(polygon: PageSelectionGeometry.rectangle(from: InkPoint(x: lassoBounds.minX, y: lassoBounds.minY), to: InkPoint(x: lassoBounds.maxX, y: lassoBounds.maxY)))
        try check(selector.selection.strokes.contains(selectedInk.id) && selector.selection.textRanges == [alphaRange], "one lasso selects crossing ink and native typed glyphs together")
        try check(!selector.selection.strokes.contains(untouchedInk.id), "lasso excludes unrelated handwriting")
        let selectionClipboard = selector.clipboardPayload()
        try check(selectionClipboard?.textBoxes.first?.text == "Alpha" && selectionClipboard?.strokes.count == 1, "mixed copy includes rich typed text and handwriting")
        let promoted = selector.promotedContent()
        let movedSelectionContent = selector.translated(promoted.0, selection: promoted.1, dx: 80, dy: 120)
        selector.preview(movedSelectionContent)
        try check(selector.content == originalSelectionContent && selectionWrites == 0, "drag preview never persists partial mixed edits")
        selector.cancelPreview()
        try check(selectionPage.textView.string == originalSelectionContent.text && selectionWrites == 0, "cancelled selection drag restores the shared page without a write")
        selector.selection = promoted.1
        selector.commit(movedSelectionContent, action: "Move Selection")
        try check(selectionWrites == 1 && selector.content.text == " Beta" && selector.content.textBoxes.first?.text == "Alpha", "moving mixed selection promotes only its typed range in one atomic write")
        try check(selector.content.strokes[0].points[0].x == selectedInk.points[0].x + 80 && selector.content.strokes[1] == untouchedInk, "mixed move translates selected ink and leaves unselected ink exact")
        guard let movedTextRTF = selector.content.textBoxes.first?.rtfData else { throw Failure(description: "Moved typed text lost RTF") }
        let movedRich = try NSAttributedString(data: movedTextRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        try check(ThemeTextAttributes.hex(movedRich.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor) == "#102040", "moving typed text preserves canonical rich-text color")
        selector.history.undo()
        try check(selector.content == originalSelectionContent, "one undo restores exact pre-lasso body, RTF and ink")
        selector.history.redo()
        try check(selector.content == movedSelectionContent, "one redo restores the complete mixed selection move")
        selector.perform(.delete)
        try check(selector.content.textBoxes.isEmpty && selector.content.strokes == [untouchedInk], "Delete removes selected typed objects and ink together")
        selector.history.undo()
        try check(selector.content == movedSelectionContent, "mixed delete is fully undoable")

        let equation = NoteEquation(latex: "\\frac{a}{b}", x: 60, y: 500, width: 180, height: 80)
        selector.load(PageContent(equations: [equation]))
        selector.selection = MacPageSelection(equations: [equation.id])
        selector.perform(.duplicate)
        try check(selector.content.equations.count == 2 && selector.content.textBoxes.isEmpty, "equation-only paste duplicates the equation without an extra LaTeX text box")
        try check(selector.content.equations[0].id != selector.content.equations[1].id, "duplicated equation receives a distinct object identity")
        selector.history.undo()
        try check(selector.content.equations == [equation], "equation duplication has one atomic undo")

        var maskedNative = PortableInkConverter.drawing(from: [selectedInk]).strokes[0]
        maskedNative.mask = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 800))
        let nativeSelection = PKDrawing(strokes: [maskedNative])
        let nativeSelectionContent = PageContent(strokes: PortableInkConverter.strokes(from: nativeSelection), pencilKitData: nativeSelection.dataRepresentation())
        selector.load(nativeSelectionContent)
        selector.selection = MacPageSelection(strokes: Set(nativeSelectionContent.strokes.map(\.id)), nativeStrokes: [0])
        selector.perform(.duplicate)
        guard let nativeDuplicateData = selector.content.pencilKitData else { throw Failure(description: "Native copied ink lost its archive") }
        let nativeDuplicate = try PKDrawing(data: nativeDuplicateData)
        try check(nativeDuplicate.strokes.count == 2 && nativeDuplicate.strokes[1].mask != nil && nativeDuplicate.strokes[1].randomSeed == maskedNative.randomSeed, "native ink copy retains mask and texture seed")
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            try check(nativeDuplicate.strokes[0].id != nativeDuplicate.strokes[1].id, "native ink paste allocates a fresh stroke identity")
        }
        #endif
        selector.history.undo()
        try check(selector.content.pencilKitData == nativeSelectionContent.pencilKitData, "native duplicate undo restores original archived bytes")

        let savedNativeContent = selector.content
        let writesBeforeInvalid = selectionWrites
        selector.history.removeAllActions()
        var invalidNative = PortableInkConverter.drawing(from: [untouchedInk]).strokes[0]
        invalidNative.transform = CGAffineTransform(translationX: 200_000, y: 0)
        let malformedNativeContent = PageContent(strokes: [untouchedInk], pencilKitData: PKDrawing(strokes: [invalidNative]).dataRepresentation())
        selector.commit(malformedNativeContent, action: "Invalid Native Import")
        try check(selector.content == savedNativeContent && selectionWrites == writesBeforeInvalid && !selector.history.canUndo,
                  "rejected native geometry cannot alter selection content, persisted writes or undo history")
        selector.load(malformedNativeContent)
        selector.selection = MacPageSelection(strokes: [untouchedInk.id], nativeStrokes: [0])
        let rejectedMove = selector.translated(malformedNativeContent, selection: selector.selection, dx: 10, dy: 10)
        try check(rejectedMove == malformedNativeContent && selector.clipboardPayload() == nil,
                  "invalid native selection cannot be silently converted into empty portable ink on move or copy")
        selector.perform(.delete)
        try check(selector.content == malformedNativeContent && selectionWrites == writesBeforeInvalid,
                  "invalid native delete leaves the original stored page intact")
        selector.load(savedNativeContent)

        // Native typing, native ink and spatial page edits must share one
        // chronology even after switching tools and first responders.
        selector.history.removeAllActions()
        selector.load(PageContent(text: "Chronology"))
        selector.onRender?(selector.content)
        selectionPage.textView.delegate = selectionRich
        selectionRich.parent.onChange = { text, rtf in selector.content.text = text; selector.content.rtfData = rtf }
        selectionPage.inkView.onChange = { strokes in selector.content.strokes = strokes; selector.content.pencilKitData = nil }
        window.contentView = selectionPage
        func nativeDot(x: CGFloat, y: CGFloat) throws {
            let location = selectionPage.inkView.convert(NSPoint(x: x, y: y), to: nil)
            selectionPage.inkView.mouseDown(with: try event(.leftMouseDown, x: Double(location.x), y: Double(location.y), pressure: 1))
            selectionPage.inkView.mouseUp(with: try event(.leftMouseUp, x: Double(location.x), y: Double(location.y), pressure: 0))
        }
        selectionPage.activeTool = .pen
        try nativeDot(x: 500, y: 500)
        let afterNativeInk = selector.content
        selectionPage.activeTool = .text
        window.makeFirstResponder(selectionPage.textView)
        selector.history.beginUndoGrouping()
        selectionPage.textView.setSelectedRange(NSRange(location: (selectionPage.textView.string as NSString).length, length: 0))
        selectionPage.textView.insertText("!", replacementRange: selectionPage.textView.selectedRange())
        selectionPage.textView.breakUndoCoalescing()
        selector.history.endUndoGrouping()
        let afterNativeTyping = selector.content
        selectionPage.activeTool = .lasso
        selector.perform(.selectAll)
        let allPromoted = selector.promotedContent()
        selector.selection = allPromoted.1
        selector.commit(selector.translated(allPromoted.0, selection: allPromoted.1, dx: 20, dy: 30), action: "Move Selection")
        let afterChronologicalMove = selector.content
        selectionPage.activeTool = .pen
        try nativeDot(x: 700, y: 700)
        selectionPage.inkView.undo(nil)
        try check(selector.content == afterChronologicalMove, "pen undo removes the newest stroke while preserving the preceding mixed move")
        selectionPage.inkView.undo(nil)
        try check(selector.content == afterNativeTyping, "pen undo reaches the preceding mixed text-and-ink move")
        selectionPage.textView.undoManager?.undo()
        try check(selector.content.text == afterNativeInk.text && selector.content.strokes == afterNativeInk.strokes, "native text undo retains the earlier ink across tool switches")
        selectionPage.inkView.undo(nil)
        try check(selector.content.strokes.isEmpty && selector.content.text == "Chronology", "old native ink undo follows the same shared chronological history")
        selectionPage.paperView.paper = .ruled
        let ruledMoved = selector.translated(promoted.0, selection: promoted.1, dx: 5, dy: 45)
        try check(ruledMoved.textBoxes[0].y - promoted.0.textBoxes[0].y == 56
                  && ruledMoved.strokes[0].points[0].y - promoted.0.strokes[0].points[0].y == 56,
                  "ruled mixed selection snaps the entire text-and-ink group to the same row delta")
        selectionPage.paperView.paper = .grid
        let freeMoved = selector.translated(promoted.0, selection: promoted.1, dx: 5, dy: 45)
        try check(freeMoved.textBoxes[0].y - promoted.0.textBoxes[0].y == 45
                  && freeMoved.strokes[0].points[0].y - promoted.0.strokes[0].points[0].y == 45,
                  "grid mixed selection retains free spatial movement")
        selectionPage.paperView.paper = .ruled
        let ruledBox = PageTextBox(x: 200, y: 117, width: 300, text: "Movable ruled text\nSecond row")
        let ruledContent = PageContent(text: "Main ruled text", strokes: [selectedInk], textBoxes: [ruledBox])
        selector.load(ruledContent); selector.onRender?(ruledContent)
        selectionPage.resizePaperToContent()
        func firstBaseline(_ view: NSTextView, pageY: CGFloat) -> CGFloat {
            guard let manager = view.layoutManager, let container = view.textContainer else { return -1 }
            manager.ensureLayout(for: container)
            return pageY + view.textContainerOrigin.y + manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + manager.location(forGlyphAt: 0).y
        }
        let mainBaseline = firstBaseline(selectionPage.textView, pageY: selectionPage.textView.frame.minY)
        guard let ruledBoxView = selectionPage.textBoxViews[ruledBox.id] else { throw Failure(description: "Ruled text box did not render") }
        let boxBaseline = firstBaseline(ruledBoxView.editor, pageY: ruledBoxView.frame.minY + ruledBoxView.editor.frame.minY)
        try check(abs((mainBaseline + 1).truncatingRemainder(dividingBy: 28)) < 0.01
                  && abs((boxBaseline + 1).truncatingRemainder(dividingBy: 28)) < 0.01,
                  "main text and a moved text box share the page's absolute ruled baselines")
        selector.selection = MacPageSelection(strokes: [selectedInk.id], textBoxes: [ruledBox.id])
        selector.perform(.duplicate)
        try check(selector.content.textBoxes.last!.y - ruledBox.y == 28
                  && selector.content.strokes.last!.points[0].y - selectedInk.points[0].y == 28,
                  "ruled text-and-ink paste uses one row offset for both layers")
        selector.load(PageContent(text: "Top\nBottom")); selector.onRender?(selector.content)
        selector.selection = MacPageSelection(textRanges: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 6)])
        try check(selector.clipboardPayload()?.text == "Top\nBottom", "multi-line selected text copies in page reading order")
        selectionPage.paperView.paper = .grid
        let edgeBox = PageTextBox(x: 1450, y: 100, width: 150, text: "Right edge")
        let edgeEquation = NoteEquation(latex: "x", x: 1400, y: 200, width: 80, height: 40)
        let edgeInk = InkStroke(points: [InkPoint(x: 1420, y: 130), InkPoint(x: 1500, y: 130)], width: 10)
        let edgeContent = PageContent(strokes: [edgeInk], textBoxes: [edgeBox], equations: [edgeEquation])
        selector.load(edgeContent); selector.onRender?(edgeContent)
        let edgeSelection = MacPageSelection(strokes: [edgeInk.id], textBoxes: [edgeBox.id], equations: [edgeEquation.id])
        let edgeMoved = selector.translated(edgeContent, selection: edgeSelection, dx: 500, dy: 20)
        try check(edgeMoved.textBoxes[0].x + edgeMoved.textBoxes[0].width <= 1600
                  && edgeMoved.textBoxes[0].x == edgeBox.x && edgeMoved.equations[0].x == edgeEquation.x
                  && edgeMoved.strokes[0].points[0].x == edgeInk.points[0].x,
                  "right-edge mixed move clamps one horizontal delta using complete object widths")
        selector.selection = edgeSelection
        selector.perform(.duplicate)
        try check(selector.content.textBoxes.count == 2 && selector.content.textBoxes.last!.x == edgeBox.x
                  && selector.content.equations.last!.x == edgeEquation.x
                  && selector.content.strokes.last!.points[0].x == edgeInk.points[0].x
                  && selector.content.textBoxes.last!.width == edgeBox.width,
                  "right-edge mixed paste preserves group spacing and text width instead of clipping or reflowing")
        let nibEdge = InkStroke(points: [InkPoint(x: 1590, y: 300), InkPoint(x: 1598, y: 310)], width: 12)
        let nibContent = PageContent(strokes: [nibEdge])
        selector.load(nibContent)
        let nibMoved = selector.translated(nibContent, selection: MacPageSelection(strokes: [nibEdge.id]), dx: 20, dy: 0)
        try check((InkRenderer.bounds(of: nibMoved.strokes[0])?.maxX ?? .infinity) <= 1600.001,
                  "horizontal ink movement includes the visible nib extent")
        let oversized = PageContent(textBoxes: [PageTextBox(x: 100, y: 100, width: 2000, text: "Imported wide text")])
        let writesBeforeOversize = selectionWrites
        selector.load(oversized); selector.onRender?(oversized)
        selector.selection = MacPageSelection(textBoxes: [oversized.textBoxes[0].id])
        selector.perform(.duplicate)
        try check(selector.content == oversized && selectionWrites == writesBeforeOversize
                  && selectionPage.textBoxViews[oversized.textBoxes[0].id]?.frame.width == 2000
                  && !selector.canMoveSelection(),
                  "oversized new paste is rejected while imported wide text retains its canonical width and position")
        let invalidClipboard = PageClipboardPayload(textBoxes: [PageTextBox(x: -1, y: 20, width: 400, text: "invalid")])
        let invalidClipboardData = try JSONEncoder().encode(invalidClipboard)
        try check((try? PageClipboardPayload.decodeValidated(invalidClipboardData)) == nil, "clipboard validation rejects invalid page coordinates")
        let sparseLongDrawing = PortableInkConverter.drawing(from: (0..<10).map { index in
            InkStroke(points: [InkPoint(x: 0, y: Double(index)), InkPoint(x: 100_000, y: Double(index))])
        })
        var samplingBudgetRejected = false
        do { _ = try PortableInkConverter.validatedClipboardDrawing(sparseLongDrawing.dataRepresentation(), fallback: []) }
        catch let error as LibraryError { samplingBudgetRejected = error == .tooLarge }
        try check(samplingBudgetRejected, "sparse long native clipboard paths are rejected before portable resampling amplifies their point count")
        var editableBox = PageTextBox(x: 100, y: 100, width: 200, text: "Edit me")
        selector.load(PageContent(textBoxes: [editableBox]))
        func renderEditableBox() {
            selectionPage.displayObjects(textBoxes: [editableBox], equations: [], editable: true,
                                         onTextBoxChange: { _, text, rtf in editableBox.text = text; editableBox.rtfData = rtf },
                                         onEquationEdit: nil)
        }
        renderEditableBox()
        selectionPage.activeTool = .select
        let editScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        editScroll.documentView = selectionPage
        window.contentView = editScroll
        let editPoint = selectionPage.convert(NSPoint(x: 110, y: 110), to: nil)
        guard let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: editPoint, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 0),
              let editableView = selectionPage.textBoxViews[editableBox.id]?.editor else {
            throw Failure(description: "Cannot prepare textbox double-click regression")
        }
        selectionPage.selectionView.mouseDown(with: doubleClick)
        try check(selectionPage.activeTool == .text && editableView.isEditable && window.firstResponder === editableView,
                  "double-clicking a selected textbox enters Text and focuses its native editor")
        selector.history.beginUndoGrouping()
        editableView.insertText("Changed", replacementRange: editableView.selectedRange())
        selector.history.endUndoGrouping()
        renderEditableBox()
        selector.history.beginUndoGrouping()
        editableView.insertText(" again", replacementRange: editableView.selectedRange())
        selector.history.endUndoGrouping()
        try check(editableBox.text == "Changed again" && editableView.isEditable,
                  "textbox editing continues after a model refresh in Text mode")
        return "\(checks) native editor integration checks passed (shared text/ink page, straight lines, formatting, pressure, dark/light, searchable export, mixed text/ink lasso, atomic move/delete/undo, canonical rich text, native PencilKit masks and clipboard validation)."
    }
}
#endif
