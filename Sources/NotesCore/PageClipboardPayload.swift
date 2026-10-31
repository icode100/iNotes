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
    public init(text: String = "", rtfData: Data? = nil, strokes: [InkStroke] = [],
                pencilKitData: Data? = nil, textBoxes: [PageTextBox] = [], equations: [NoteEquation] = []) {
        self.text = text; self.rtfData = rtfData; self.strokes = strokes
        self.pencilKitData = pencilKitData; self.textBoxes = textBoxes; self.equations = equations
    }

    public static let pasteboardType = "io.inotes.page-selection"
    public static let maximumBytes = 16 * 1_024 * 1_024

    public static func decodeValidated(_ data: Data) throws -> PageClipboardPayload {
        guard data.count <= maximumBytes else { throw LibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.strokes.count <= 10_000, value.textBoxes.count <= 10_000,
              value.equations.count <= 10_000,
              value.strokes.reduce(0, { $0 + $1.points.count }) <= 1_000_000 else { throw LibraryError.tooLarge }
        guard value.strokes.allSatisfy({ stroke in
            stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }
        }) else { throw LibraryError.invalidData("Clipboard ink lies outside the supported page area.") }
        var library = NoteLibrary()
        let workbook = try library.create(kind: .workbook, title: "Clipboard")
        let chapter = try library.create(kind: .chapter, title: "Clipboard", parentID: workbook)
        let id = try library.create(kind: .sheet, title: "Clipboard", parentID: chapter)
        var node = library.node(id: id)!
        node.pageContent = PageContent(text: value.text, rtfData: value.rtfData, strokes: value.strokes,
                                       pencilKitData: value.pencilKitData, textBoxes: value.textBoxes, equations: value.equations)
        try library.update(node)
        return value
    }
}
