import Foundation
import PencilKit
import NotesCore
#if os(macOS)
import AppKit
private typealias InkPlatformColor = NSColor
#elseif os(iOS)
import UIKit
private typealias InkPlatformColor = UIColor
#endif

/// Basic ink is exchanged as sampled paths; the original PencilKit payload also
/// remains in the sheet so iPad retains textures, transparency and advanced tools.
@MainActor
enum PortableInkConverter {
    static func drawing(from strokes: [InkStroke]) -> PKDrawing {
        PKDrawing(strokes: strokes.compactMap { stroke -> PKStroke? in
            let points = stroke.points.enumerated().compactMap { index, point -> PKStrokePoint? in
                guard point.x.isFinite, point.y.isFinite, point.pressure.isFinite else { return nil }
                let pressure = max(0, min(1, point.pressure))
                let width = max(0.5, min(100, stroke.width)) * stroke.style.widthMultiplier * (0.35 + 0.65 * pressure)
                return PKStrokePoint(location: CGPoint(x: point.x, y: point.y), timeOffset: Double(index) / 120,
                                     size: CGSize(width: width, height: width), opacity: 1, force: pressure,
                                     azimuth: 0, altitude: .pi / 2)
            }
            guard !points.isEmpty else { return nil }
            let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
            let nativeTool: PKInk.InkType = stroke.style == .pencil ? .pencil : stroke.style == .marker || stroke.style == .highlighter ? .marker : .pen
            let nativeColor = color(stroke.colorHex).withAlphaComponent(stroke.style == .highlighter ? 0.25 : 1)
            return PKStroke(ink: PKInk(nativeTool, color: nativeColor), path: path)
        })
    }

    static func strokes(from drawing: PKDrawing) -> [InkStroke] {
        drawing.strokes.flatMap { stroke -> [InkStroke] in
            guard !stroke.path.isEmpty else { return [] }
            let style: InkStyle = stroke.ink.inkType == .pencil ? .pencil : stroke.ink.inkType == .marker ? (stroke.ink.color.cgColor.alpha < 0.7 ? .highlighter : .marker) : .pen
            let ranges = stroke.mask == nil ? [CGFloat(0)...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
            let scale = sqrt(abs(stroke.transform.a * stroke.transform.d - stroke.transform.b * stroke.transform.c))
            return ranges.compactMap { range -> InkStroke? in
                var points: [InkPoint] = []
                var accumulatedWidth = 0.0
                var pressureFactor = 0.0
                // Using visible ranges prevents partially erased ink from returning on Mac.
                for sample in stroke.path.interpolatedPoints(in: range, by: .distance(1.5)) {
                    if points.count >= 100_000 { break }
                    let location = sample.location.applying(stroke.transform)
                    guard location.x.isFinite, location.y.isFinite else { continue }
                    let pressure = sample.force.isFinite ? max(0, min(1, Double(sample.force))) : 1
                    points.append(InkPoint(x: location.x, y: location.y, pressure: pressure))
                    accumulatedWidth += Double(max(sample.size.width, sample.size.height) * scale)
                    pressureFactor += 0.35 + 0.65 * pressure
                }
                guard !points.isEmpty else { return nil }
                let width = pressureFactor > 0 ? accumulatedWidth / pressureFactor / style.widthMultiplier : 2.5
                return InkStroke(points: points, colorHex: hex(stroke.ink.color), width: max(0.5, min(100, width)), style: style)
            }
        }
    }

    private static func color(_ hex: String) -> InkPlatformColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .black }
        return InkPlatformColor(red: Double((value >> 16) & 255) / 255,
                                green: Double((value >> 8) & 255) / 255,
                                blue: Double(value & 255) / 255, alpha: 1)
    }

    private static func hex(_ color: InkPlatformColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        guard let color = color.usingColorSpace(.deviceRGB) else { return "#202020" }
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#202020" }
        #endif
        return String(format: "#%02X%02X%02X", Int((max(0, min(1, red)) * 255).rounded()),
                      Int((max(0, min(1, green)) * 255).rounded()), Int((max(0, min(1, blue)) * 255).rounded()))
    }
}

#if os(iOS)
import SwiftUI

/// The iPad uses the system PencilKit renderer, tool palette and palm rejection.
struct PencilEditor: UIViewRepresentable {
    @Binding var data: Data?
    @Binding var strokes: [InkStroke]
    var onChange: ((Data?, [InkStroke]) -> Void)? = nil
    var onInputChange: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PencilCanvasView()
        let coordinator = context.coordinator
        canvas.onAttachment = { [weak coordinator] canvas in coordinator?.showTools(on: canvas) }
        canvas.onInputChange = onInputChange
        canvas.delegate = context.coordinator
        canvas.isUserInteractionEnabled = context.environment.isEnabled
        canvas.drawingPolicy = .pencilOnly
        canvas.contentSize = CGSize(width: 1600, height: 2200)
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 4
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = true
        canvas.backgroundColor = .white
        canvas.accessibilityLabel = "Apple Pencil drawing canvas"
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        context.coordinator.load(data, strokes: strokes, into: canvas)
        context.coordinator.showTools(on: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        (canvas as? PencilCanvasView)?.onInputChange = onInputChange
        canvas.isUserInteractionEnabled = context.environment.isEnabled
        if context.coordinator.lastData != data || context.coordinator.lastStrokes != strokes {
            context.coordinator.load(data, strokes: strokes, into: canvas)
        }
        context.coordinator.showTools(on: canvas)
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.stopObserving(canvas)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilEditor
        var lastData: Data?
        var lastStrokes: [InkStroke] = []
        private var isLoading = false
        private let toolPicker = PKToolPicker()
        private weak var observedCanvas: PKCanvasView?
        private var isPickerShown = false

        init(_ parent: PencilEditor) { self.parent = parent }

        func load(_ data: Data?, strokes: [InkStroke], into canvas: PKCanvasView) {
            isLoading = true
            defer { isLoading = false }
            canvas.drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PortableInkConverter.drawing(from: strokes)
            lastData = data
            lastStrokes = strokes
        }

        func showTools(on canvas: PKCanvasView) {
            if observedCanvas !== canvas {
                if let oldCanvas = observedCanvas { toolPicker.removeObserver(oldCanvas) }
                toolPicker.addObserver(canvas)
                observedCanvas = canvas
            }
            if canvas.window != nil, !isPickerShown {
                isPickerShown = true
                toolPicker.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            }
        }

        func stopObserving(_ canvas: PKCanvasView) {
            toolPicker.setVisible(false, forFirstResponder: canvas)
            toolPicker.removeObserver(canvas)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading else { return }
            let value = canvasView.drawing.dataRepresentation()
            let portable = PortableInkConverter.strokes(from: canvasView.drawing)
            lastData = value
            lastStrokes = portable
            if let onChange = parent.onChange {
                onChange(value, portable)
            } else {
                parent.data = value
                parent.strokes = portable
            }
        }
    }
}

private final class PencilCanvasView: PKCanvasView {
    var onAttachment: ((PKCanvasView) -> Void)?
    var onInputChange: ((String) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttachment?(self) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .pencil }) { onInputChange?("Apple Pencil") }
        super.touchesBegan(touches, with: event)
    }
}
#endif
