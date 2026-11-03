#if os(macOS)
import AppKit
import SwiftUI
import NotesCore
import ImageIO
import UniformTypeIdentifiers

/// Movable text remains a native rich-text editor; it is layered beneath ink on
/// the same paper and selected together with handwriting by the page overlay.
@MainActor
final class MacPageTextBoxView: NSView {
    let editor = RichTextEditor.makeNativeTextView()
    private var coordinator: RichTextEditor.Coordinator?
    private var lastBox: PageTextBox?
    private var lastTheme: PageTheme?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        addSubview(editor)
        setAccessibilityLabel("Movable page text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ box: PageTextBox, theme: PageTheme, paper: InkPaper, editable: Bool, onChange: @escaping (String, Data?) -> Void) {
        frame.origin = CGPoint(x: box.x, y: box.y)
        setFrameSize(CGSize(width: box.width, height: max(24, frame.height)))
        let rich = RichTextEditor(text: .constant(box.text), rtfData: .constant(box.rtfData), theme: theme, onChange: onChange)
        if coordinator == nil { coordinator = RichTextEditor.Coordinator(rich); editor.delegate = coordinator }
        coordinator?.parent = rich
        editor.frame = bounds
        editor.textContainer?.containerSize = CGSize(width: box.width, height: .greatestFiniteMagnitude)
        RuledTextLayout.attach(to: editor, paper: paper, pageOriginY: box.y + editor.frame.minY)
        if lastBox?.text != box.text || lastBox?.rtfData != box.rtfData || lastTheme != theme {
            coordinator?.load(text: box.text, rtf: box.rtfData, into: editor)
        }
        lastBox = box; lastTheme = theme
        editor.isEditable = editable; editor.isSelectable = editable
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let used = editor.textContainer.flatMap { editor.layoutManager?.usedRect(for: $0).maxY } ?? 0
        let extra = editor.layoutManager?.extraLineFragmentRect.maxY ?? 0
        let natural = editor.attributedString().boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let fallback = paper == .ruled && used == 0 ? ceil(natural / RuledTextLayout.spacing) * RuledTextLayout.spacing + RuledTextLayout.spacing : natural
        let measured = max(used, extra, fallback)
        setFrameSize(CGSize(width: box.width, height: max(24, ceil(measured) + 8)))
        editor.frame = bounds
        editor.textContainer?.containerSize = CGSize(width: box.width, height: .greatestFiniteMagnitude)
    }
}

extension UnifiedMacPageView {
    func displayObjects(textBoxes: [PageTextBox], equations: [NoteEquation], images: [PageImage] = [], editable: Bool,
                        onTextBoxChange: @escaping (UUID, String, Data?) -> Void,
                        onEquationEdit: ((NoteEquation) -> Void)?) {
        let imageIDs = Set(images.map(\.id))
        for id in Array(imageViews.keys) where !imageIDs.contains(id) { imageViews.removeValue(forKey: id)?.removeFromSuperview() }
        // Stable views, ordered behind every native text and ink layer.
        for image in images {
            let view = imageViews[image.id] ?? MacPageImageView(frame: .zero)
            if view.superview == nil { imageViews[image.id] = view }
            addSubview(view, positioned: .below, relativeTo: textView)
            view.configure(image)
        }
        let boxIDs = Set(textBoxes.map(\.id)), equationIDs = Set(equations.map(\.id))
        for id in Array(textBoxViews.keys) where !boxIDs.contains(id) { textBoxViews.removeValue(forKey: id)?.removeFromSuperview() }
        for id in Array(equationViews.keys) where !equationIDs.contains(id) { equationViews.removeValue(forKey: id)?.removeFromSuperview() }
        for box in textBoxes {
            let view = textBoxViews[box.id] ?? MacPageTextBoxView(frame: .zero)
            view.editor.pageUndoManager = selectionController?.history
            if view.superview == nil {
                view.editor.pageCursorProvider = { [weak self] in self?.activePageCursor }
                view.editor.onPagePaste = { [weak self] in self?.handlePagePaste() ?? false }
                view.editor.canPastePage = { [weak self] in self?.canPastePage() ?? false }
                view.editor.onPageSelectAll = { [weak self] in self?.selectAllPageContent() ?? false }
                view.editor.canSelectAllPage = { [weak self] in self?.inkView.isInputEnabled == true && self?.selectionController != nil }
                view.editor.allowsPageTextUndo = { [weak self] in self?.inkView.isInputEnabled == true }
                addSubview(view, positioned: .below, relativeTo: inkView)
                textBoxViews[box.id] = view
            }
            view.configure(box, theme: theme, paper: paperView.paper, editable: editable && activeTool == .text, onChange: { onTextBoxChange(box.id, $0, $1) })
        }
        for equation in equations {
            let view = equationViews[equation.id] ?? EquationDisplayView(frame: .zero)
            if view.superview == nil { addSubview(view, positioned: .below, relativeTo: inkView); equationViews[equation.id] = view }
            view.frame = CGRect(x: equation.x, y: equation.y, width: equation.width, height: equation.height)
            view.configure(equation: equation, theme: theme, onRequestEdit: { if editable { onEquationEdit?(equation) } })
        }
    }
}

/// Decode only bounded raster sources. Metadata is checked before pixel allocation;
/// normalized PNGs keep clipboard encodings and orientation out of saved pages.
@MainActor
enum MacPageImageCodec {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static let cache = NSCache<NSData, NSImage>()

    private static func source(_ data: Data) throws -> CGImageSource {
        guard !data.isEmpty, data.count <= PageImageLimits.maximumBytes else {
            throw Failure(message: "Images must be no larger than 10 MiB.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue >= 1, height.doubleValue >= 1,
              width.doubleValue <= Double(PageImageLimits.maximumPixelDimension),
              height.doubleValue <= Double(PageImageLimits.maximumPixelDimension),
              width.doubleValue * height.doubleValue <= Double(PageImageLimits.maximumPixels) else {
            throw Failure(message: "This image is unsupported or too large. Use a raster image up to 16 megapixels and 8192 pixels per side.")
        }
        return source
    }

    static func normalize(_ data: Data) throws -> Data {
        let source = try source(data)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PageImageLimits.maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure(message: "The copied image could not be decoded.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "The copied image could not be converted to PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= PageImageLimits.maximumBytes else {
            throw Failure(message: "The image is larger than 10 MiB when saved. Try a smaller image.")
        }
        let result = output as Data
        _ = try PageImageLimits.pngDimensions(result)
        return result
    }

    static func decode(_ data: Data) -> CGImage? {
        guard (try? PageImageLimits.pngDimensions(data)) != nil,
              let source = try? source(data) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func displayImage(_ data: Data) -> NSImage? {
        cache.countLimit = 16
        cache.totalCostLimit = 64 * 1024 * 1024
        let key = data as NSData
        if let image = cache.object(forKey: key) { return image }
        guard let cgImage = decode(data) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height + data.count)
        return image
    }

    static let rasterTypes: [NSPasteboard.PasteboardType] = [.png, .tiff,
        .init(UTType.jpeg.identifier), .init(UTType.heic.identifier), .init(UTType.gif.identifier), .init(UTType.bmp.identifier)]

    static func canRead(_ board: NSPasteboard) -> Bool {
        board.availableType(from: rasterTypes + [.fileURL]) != nil
    }

    static func clipboardPNG(_ board: NSPasteboard) throws -> Data {
        if let type = board.availableType(from: rasterTypes), let data = board.data(forType: type) {
            return try normalize(data)
        }
        if let value = board.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try normalize(BoundedFileReader.read(from: url, maximumBytes: PageImageLimits.maximumBytes))
        }
        throw Failure(message: "Copy an image or an image file, then paste it onto the sheet.")
    }
}

@MainActor
final class MacPageImageView: NSView {
    private var imageData = Data()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ image: PageImage) {
        frame = NSRect(x: image.x, y: image.y, width: image.width, height: image.height)
        if imageData != image.imageData { imageData = image.imageData; needsDisplay = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Pasted page image")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = MacPageImageCodec.displayImage(imageData) else { return }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
    }
}

extension UnifiedMacPageView {
    func canPastePage() -> Bool {
        let board = NSPasteboard.general
        let types = [PageClipboardPayload.pasteboardType, PageClipboardPayload.legacyPasteboardType].map { NSPasteboard.PasteboardType($0) }
        return inkView.isInputEnabled && (board.availableType(from: types) != nil || MacPageImageCodec.canRead(board))
    }

    /// Only page payloads/images leave NSTextView's normal rich-text paste path.
    func handlePagePaste() -> Bool {
        let board = NSPasteboard.general
        let types = [PageClipboardPayload.pasteboardType, PageClipboardPayload.legacyPasteboardType].map { NSPasteboard.PasteboardType($0) }
        guard let controller = selectionController, inkView.isInputEnabled,
              board.availableType(from: types) != nil || MacPageImageCodec.canRead(board) else { return false }
        if let type = board.availableType(from: types), let data = board.data(forType: type),
           let payload = try? PageClipboardPayload.decodeValidated(data), payload.images.isEmpty {
            // Keep rich text copied from a selection on NSTextView's caret path.
            return false
        }
        controller.perform(.paste)
        return true
    }
}

extension MacPageSelectionController {
    @discardableResult
    func pasteImage(from board: NSPasteboard) -> Bool {
        let payloadTypes = [PageClipboardPayload.pasteboardType, PageClipboardPayload.legacyPasteboardType].map { NSPasteboard.PasteboardType($0) }
        guard board.availableType(from: payloadTypes) == nil, MacPageImageCodec.canRead(board) else { return false }
        guard let page, page.inkView.isInputEnabled else { return true }
        do {
            let data = try MacPageImageCodec.clipboardPNG(board)
            let size = try PageImageLimits.pngDimensions(data)
            let visible = page.visibleRect.intersection(page.bounds)
            let availableWidth = max(40, min(600, page.bounds.width - 80))
            let scale = min(1, availableWidth / Double(size.width), 700 / Double(size.height))
            let width = Double(size.width) * scale, height = Double(size.height) * scale
            let x = max(0, min(page.bounds.width - width, visible.isEmpty ? 40 : visible.minX + 40))
            let y = max(0, min(100_000, visible.isEmpty ? 40 : visible.minY + 40))
            let image = PageImage(x: x, y: y, width: width, height: height, imageData: data)
            paste(PageClipboardPayload(images: [image]), offset: 0, action: "Paste Image")
        } catch {
            onPasteError?(error.localizedDescription)
            NSSound.beep()
        }
        return true
    }
}
#endif
