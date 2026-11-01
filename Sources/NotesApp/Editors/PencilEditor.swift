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
    /// Both archives and the clipboard cross this boundary before native ink is
    /// rendered or distance-sampled. The JSON byte limit alone cannot bound
    /// transformed geometry or the work required to convert native paths.
    static func validatedDrawing(_ data: Data?, fallback: [InkStroke]) throws -> PKDrawing {
        let value: PKDrawing
        if let data {
            guard data.count <= LibraryArchive.maximumBytes else { throw LibraryError.tooLarge }
            value = try PKDrawing(data: data)
        } else {
            try InkGeometryLimits.validate(fallback)
            value = try makeDrawing(from: fallback)
        }
        try validateNativeDrawing(value)
        return value
    }

    static func validatedClipboardDrawing(_ data: Data?, fallback: [InkStroke]) throws -> PKDrawing {
        try validatedDrawing(data, fallback: fallback)
    }

    static func validateNativeDrawing(_ value: PKDrawing) throws {
        guard value.strokes.count <= InkGeometryLimits.maximumStrokeCount else { throw LibraryError.tooLarge }
        var controlPoints = 0
        for stroke in value.strokes {
            guard !stroke.path.isEmpty, stroke.path.count <= InkGeometryLimits.maximumPointCount - controlPoints else {
                throw LibraryError.invalidData("A drawing contains empty or excessive native ink.")
            }
            controlPoints += stroke.path.count
        }
        var estimatedSamples = 0.0
        for stroke in value.strokes {
            let transform = stroke.transform
            guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                .allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else {
                throw LibraryError.invalidData("Native ink contains an invalid transform.")
            }
            var previous: CGPoint?
            var length = 0.0
            for point in stroke.path {
                guard [point.location.x, point.location.y].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
                      [point.size.width, point.size.height].allSatisfy({ $0.isFinite && (0...1_000).contains($0) }),
                      point.force.isFinite else { throw LibraryError.invalidData("Native ink contains invalid geometry.") }
                let position = point.location.applying(transform)
                guard [position.x, position.y].allSatisfy({ $0.isFinite && abs($0) <= InkGeometryLimits.maximumCoordinate }) else {
                    throw LibraryError.invalidData("Native ink lies outside the supported page area.")
                }
                if let previous { length += hypot(position.x - previous.x, position.y - previous.y) }
                previous = position
            }
            // Native paths have few control points, but distance-based portable
            // sampling can otherwise amplify a tiny clipboard into huge arrays.
            estimatedSamples += max(Double(stroke.path.count), Double(length) * 2 / 1.5 + 2)
            guard estimatedSamples.isFinite, estimatedSamples <= 1_000_000 else { throw LibraryError.tooLarge }
            let bounds = stroke.renderBounds
            guard bounds.isNull || (!bounds.isInfinite && [bounds.minX, bounds.maxX, bounds.minY, bounds.maxY]
                .allSatisfy({ $0.isFinite && abs($0) <= 110_000 })) else {
                throw LibraryError.invalidData("Native ink lies outside the supported page area.")
            }
        }
    }

    /// Nonthrowing conversion is retained for callers constructing trusted ink.
    /// Rejected expansion produces no drawing; untrusted loads use the throwing
    /// entry point above, and report the failure without overwriting stored data.
    static func drawing(from strokes: [InkStroke]) -> PKDrawing {
        (try? makeDrawing(from: strokes)) ?? PKDrawing()
    }

    private static func makeDrawing(from strokes: [InkStroke]) throws -> PKDrawing {
        var native: [PKStroke] = []
        for stroke in strokes {
            let fragments = try patternedFragments(stroke)
            guard fragments.count <= InkGeometryLimits.maximumStrokeCount - native.count else { throw LibraryError.tooLarge }
            for fragment in fragments {
                let points = fragment.enumerated().compactMap { index, point -> PKStrokePoint? in
                    guard point.x.isFinite, point.y.isFinite, point.pressure.isFinite else { return nil }
                    let pressure = max(0, min(1, point.pressure))
                    let width = max(0.5, min(100, stroke.width)) * stroke.style.widthMultiplier * (0.35 + 0.65 * pressure)
                    return PKStrokePoint(location: CGPoint(x: point.x, y: point.y), timeOffset: Double(index) / 120,
                                         size: CGSize(width: width, height: width), opacity: 1, force: pressure,
                                         azimuth: 0, altitude: .pi / 2)
                }
                guard !points.isEmpty else { continue }
                let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
                let nativeTool: PKInk.InkType = stroke.style == .pencil ? .pencil : stroke.style == .marker || stroke.style == .highlighter ? .marker : .pen
                let nativeColor = color(stroke.colorHex).withAlphaComponent(stroke.style == .highlighter ? 0.25 : 1)
                native.append(PKStroke(ink: PKInk(nativeTool, color: nativeColor), path: path))
            }
        }
        return PKDrawing(strokes: native)
    }

    /// PencilKit has no dashed stroke style. Store each visible dash as native
    /// geometry, so erasing, export and portable round trips retain the gaps.
    private static func patternedFragments(_ stroke: InkStroke) throws -> [[InkPoint]] {
        guard stroke.linePattern != .solid, stroke.points.count > 1 else { return [stroke.points] }
        let lengths = stroke.linePattern.dashLengths(width: stroke.width)
        let cycle = lengths[0] + lengths[1]
        var total = 0.0
        for index in 1..<stroke.points.count {
            total += hypot(stroke.points[index].x - stroke.points[index - 1].x, stroke.points[index].y - stroke.points[index - 1].y)
        }
        guard total.isFinite, total / cycle + 1 <= Double(InkGeometryLimits.maximumStrokeCount) else { throw LibraryError.tooLarge }
        var result: [[InkPoint]] = []
        var phase = 0.0
        for index in 1..<stroke.points.count {
            let a = stroke.points[index - 1], b = stroke.points[index]
            let distance = hypot(b.x - a.x, b.y - a.y)
            guard distance > 0 else { continue }
            var position = 0.0
            func point(_ along: Double) -> InkPoint {
                let t = along / distance
                return InkPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                                pressure: a.pressure + (b.pressure - a.pressure) * t)
            }
            while position < distance {
                let visible = phase < lengths[0]
                let remaining = (visible ? lengths[0] : cycle) - phase
                let step = min(distance - position, remaining)
                guard step > 0 else { break }
                if visible {
                    guard result.count < InkGeometryLimits.maximumStrokeCount else { throw LibraryError.tooLarge }
                    result.append([point(position), point(position + step)])
                }
                position += step
                phase += step
                if phase >= cycle - 0.000001 { phase = 0 }
            }
        }
        return result
    }

    static func strokes(from drawing: PKDrawing) -> [InkStroke] {
        (try? validatedStrokes(from: drawing)) ?? []
    }

    /// Conversion either returns every visible segment or fails. Truncating a
    /// long stroke would quietly lose ink when the notebook reaches another device.
    static func validatedStrokes(from drawing: PKDrawing) throws -> [InkStroke] {
        try validateNativeDrawing(drawing)
        var result: [InkStroke] = []
        var sampleCount = 0
        for stroke in drawing.strokes {
            let style: InkStyle = stroke.ink.inkType == .pencil ? .pencil : stroke.ink.inkType == .marker ? (stroke.ink.color.cgColor.alpha < 0.7 ? .highlighter : .marker) : .pen
            let ranges = stroke.mask == nil ? [CGFloat(0)...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
            let scale = sqrt(abs(stroke.transform.a * stroke.transform.d - stroke.transform.b * stroke.transform.c))
            for range in ranges {
                var points: [InkPoint] = []
                var accumulatedWidth = 0.0
                var pressureFactor = 0.0
                // Using visible ranges prevents partially erased ink from returning on Mac.
                for sample in stroke.path.interpolatedPoints(in: range, by: .distance(1.5)) {
                    guard sampleCount < InkGeometryLimits.maximumPointCount else { throw LibraryError.tooLarge }
                    let location = sample.location.applying(stroke.transform)
                    guard location.x.isFinite, location.y.isFinite,
                          abs(location.x) <= InkGeometryLimits.maximumCoordinate,
                          abs(location.y) <= InkGeometryLimits.maximumCoordinate else {
                        throw LibraryError.invalidData("Sampled ink lies outside the supported page area.")
                    }
                    sampleCount += 1
                    let pressure = sample.force.isFinite ? max(0, min(1, Double(sample.force))) : 1
                    points.append(InkPoint(x: location.x, y: location.y, pressure: pressure))
                    accumulatedWidth += Double(max(sample.size.width, sample.size.height) * scale)
                    pressureFactor += 0.35 + 0.65 * pressure
                }
                guard !points.isEmpty else { continue }
                guard result.count < InkGeometryLimits.maximumStrokeCount else { throw LibraryError.tooLarge }
                let width = pressureFactor > 0 ? accumulatedWidth / pressureFactor / style.widthMultiplier : 2.5
                result.append(InkStroke(points: points, colorHex: hex(stroke.ink.color), width: max(0.5, min(100, width)), style: style))
            }
        }
        return result
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
            canvas.drawing = (try? PortableInkConverter.validatedDrawing(data, fallback: strokes)) ?? PKDrawing()
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
            guard let portable = try? PortableInkConverter.validatedStrokes(from: canvasView.drawing) else {
                load(lastData, strokes: lastStrokes, into: canvasView)
                return
            }
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
