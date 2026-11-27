#if os(macOS)
import AppKit
import CoreText
import NotesCore

/// Typesets the pages and headings added to a single workbook PDF. All text
/// is drawn into the PDF context so it stays searchable at any zoom.
@MainActor
enum WorkbookPDFPage {
    static func begin(in context: CGContext, bounds: CGRect) {
        var box = bounds
        let data = withUnsafeBytes(of: &box) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
    }

    static func drawTitle(_ title: String, chapterNumber: Int?, into context: CGContext) throws {
        let box = CGRect(origin: .zero, size: InkExport.paperSize)
        let inset = box.width * 0.09
        let width = box.width - 2 * inset
        let chapter = try chapterNumber.map {
            try TextBlock("Chapter \($0)", font: .systemFont(ofSize: 40, weight: .medium),
                          gray: 0.32, width: width)
        }
        let labelHeight = chapter.map { $0.height + 26 } ?? 0
        var size: CGFloat = 112
        var name = try TextBlock(title, font: serif(size), gray: 0.12, width: width)
        // A valid title can be 256 full-width characters or one long word.
        // Wrap it first, then reduce type just enough to fit the title page.
        while name.height + labelHeight > box.height * 0.75 && size > 32 {
            size = max(32, size * 0.85)
            name = try TextBlock(title, font: serif(size), gray: 0.12, width: width)
        }
        let groupHeight = name.height + labelHeight
        guard groupHeight <= box.height * 0.9 else { throw GroupedPageExport.ExportError.renderingFailed }
        let top = box.maxY - (box.height - groupHeight) * 0.40
        begin(in: context, bounds: box)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        chapter?.draw(x: inset, top: top, into: context)
        name.draw(x: inset, top: top - labelHeight, into: context)
        context.endPDFPage()
    }

    @MainActor struct TopicHeader {
        private let ancestors: TextBlock?
        private let topic: TextBlock
        private let inset: CGFloat
        let height: CGFloat

        init?(titles: [String], paperWidth: CGFloat) throws {
            guard let current = titles.last else { return nil }
            inset = paperWidth * 0.035
            let textWidth = paperWidth - 2 * inset
            // When a topic has no direct pages, its title shares its first
            // descendant's header. Subsequent pages do not repeat that chain.
            if titles.count > 1 {
                ancestors = try TextBlock(titles.dropLast().joined(separator: "  ›  "),
                    font: .systemFont(ofSize: 28, weight: .medium), gray: 0.34, width: textWidth)
            } else {
                ancestors = nil
            }
            topic = try TextBlock(current, font: WorkbookPDFPage.serif(50), gray: 0.12, width: textWidth)
            height = 30 + (ancestors.map { $0.height + 9 } ?? 0) + topic.height + 22
            guard height.isFinite, height <= InkGeometryLimits.maximumPageDimension else {
                throw GroupedPageExport.ExportError.renderingFailed
            }
        }

        func draw(above paper: CGRect, into context: CGContext) {
            let band = CGRect(x: paper.minX, y: paper.maxY, width: paper.width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(band)
            let x = band.minX + inset
            let top = band.maxY - 30
            ancestors?.draw(x: x, top: top, into: context)
            topic.draw(x: x, top: top - (ancestors.map { $0.height + 9 } ?? 0), into: context)
            context.setFillColor(gray: 0.76, alpha: 1)
            context.fill(CGRect(x: x, y: band.minY, width: band.width - 2 * inset, height: 1))
        }
    }

    private static func serif(_ size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    /// Core Text measures and draws the same frame. The extra leading also
    /// accommodates ascenders and descenders from fallback fonts.
    private struct TextBlock {
        let frame: CTFrame
        let height: CGFloat

        init(_ title: String, font: NSFont, gray: CGFloat, width: CGFloat) throws {
            let text = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(deviceWhite: gray, alpha: 1)
            ])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let range = CFRange(location: 0, length: attributed.length)
            let maxHeight = CGFloat(InkGeometryLimits.maximumPageDimension)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, range, nil,
                CGSize(width: width, height: maxHeight), nil)
            height = ceil(size.height) + ceil(font.pointSize * 0.15)
            guard width > 0, height.isFinite, height > 0, height <= maxHeight else {
                throw GroupedPageExport.ExportError.renderingFailed
            }
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
            frame = CTFramesetterCreateFrame(setter, range, path, nil)
            guard CTFrameGetVisibleStringRange(frame).length == attributed.length else {
                throw GroupedPageExport.ExportError.renderingFailed
            }
        }

        func draw(x: CGFloat, top: CGFloat, into context: CGContext) {
            context.saveGState()
            context.translateBy(x: x, y: top - height)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
    }
}
#endif
