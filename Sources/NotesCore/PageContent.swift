import Foundation

/// A movable rich-text container on the same paper as handwriting.
public struct PageTextBox: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var width: Double
    public var text: String
    public var rtfData: Data?

    public init(id: UUID = UUID(), x: Double = 40, y: Double = 40, width: Double = 400,
                text: String = "", rtfData: Data? = nil) {
        self.id = id; self.x = x; self.y = y; self.width = width
        self.text = text; self.rtfData = rtfData
    }
}

/// One transaction and undo snapshot for operations spanning text and ink.
public struct PageContent: Codable, Equatable, Sendable {
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
}

extension NoteNode {
    public var plainTextExport: String {
        ([body] + textBoxes.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.map(\.text)
         + equations.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.map { "$$\n\($0.latex)\n$$" })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var pageContent: PageContent {
        get { PageContent(text: body, rtfData: richTextRTF, strokes: strokes,
                          pencilKitData: pencilKitData, textBoxes: textBoxes, equations: equations) }
        set {
            body = newValue.text; richTextRTF = newValue.rtfData; strokes = newValue.strokes
            pencilKitData = newValue.pencilKitData; textBoxes = newValue.textBoxes; equations = newValue.equations
        }
    }
}
