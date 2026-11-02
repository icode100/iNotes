import Foundation

/// Canonical page objects are copied together, without display-theme colors.
/// The native ink archive retains PencilKit masks, textures and tool metadata.
public struct PageClipboardPayload: Codable, Equatable, Sendable {
    public var text: String
    public var rtfData: Data?
    public var strokes: [InkStroke]
    public var pencilKitData: Data?
    public var textBoxes: [PageTextBox]
    public var equations: [NoteEquation]
    public var images: [PageImage]
    public init(text: String = "", rtfData: Data? = nil, strokes: [InkStroke] = [],
                pencilKitData: Data? = nil, textBoxes: [PageTextBox] = [], equations: [NoteEquation] = [],
                images: [PageImage] = []) {
        self.text = text; self.rtfData = rtfData; self.strokes = strokes
        self.pencilKitData = pencilKitData; self.textBoxes = textBoxes; self.equations = equations
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case text, rtfData, strokes, pencilKitData, textBoxes, equations, images
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        rtfData = try values.decodeIfPresent(Data.self, forKey: .rtfData)
        strokes = try values.decode([InkStroke].self, forKey: .strokes)
        pencilKitData = try values.decodeIfPresent(Data.self, forKey: .pencilKitData)
        textBoxes = try values.decodeIfPresent([PageTextBox].self, forKey: .textBoxes) ?? []
        equations = try values.decodeIfPresent([NoteEquation].self, forKey: .equations) ?? []
        images = try values.decodeIfPresent([PageImage].self, forKey: .images) ?? []
    }

    // A distinct type prevents older apps silently dropping images from a mixed paste.
    public static let pasteboardType = "io.inotes.page-selection.v3"
    public static let legacyPasteboardType = "io.inotes.page-selection"
    public static let maximumBytes = 16 * 1_024 * 1_024

    public static func decodeValidated(_ data: Data) throws -> PageClipboardPayload {
        guard data.count <= maximumBytes else { throw LibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validatePageContent()
        return value
    }

    /// A resulting page may exceed the single clipboard transfer budget, but it
    /// must fit the archive budget and obey all aggregate geometry/pixel limits.
    public func validatePageContent() throws {
        guard textBoxes.count <= 10_000, equations.count <= 10_000 else { throw LibraryError.tooLarge }
        try InkGeometryLimits.validate(strokes)
        var library = NoteLibrary()
        let workbook = try library.create(kind: .workbook, title: "Clipboard")
        let chapter = try library.create(kind: .chapter, title: "Clipboard", parentID: workbook)
        let id = try library.create(kind: .sheet, title: "Clipboard", parentID: chapter)
        var node = library.node(id: id)!
        node.pageContent = PageContent(text: text, rtfData: rtfData, strokes: strokes,
                                       pencilKitData: pencilKitData, textBoxes: textBoxes,
                                       equations: equations, images: images)
        try library.update(node)
        _ = try LibraryArchive.encode(library)
    }
}
