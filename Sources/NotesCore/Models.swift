import Foundation

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case workbook, chapter, topic, sheet

    public var displayName: String { rawValue.capitalized }
    public var canContainChildren: Bool { self != .sheet }
}

public struct InkPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double
    public init(x: Double, y: Double, pressure: Double = 1) {
        self.x = x; self.y = y; self.pressure = pressure
    }
}

public enum InkStyle: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, highlighter
}

public enum PaperStyle: String, Codable, CaseIterable, Sendable {
    case blank, ruled, dotted, grid
}

public struct InkStroke: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var points: [InkPoint]
    public var colorHex: String
    public var width: Double
    public var style: InkStyle
    public init(id: UUID = UUID(), points: [InkPoint], colorHex: String = "#202020", width: Double = 2.5, style: InkStyle = .pen) {
        self.id = id; self.points = points; self.colorHex = colorHex; self.width = width; self.style = style
    }

    private enum CodingKeys: String, CodingKey { case id, points, colorHex, width, style }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        points = try values.decode([InkPoint].self, forKey: .points)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        width = try values.decode(Double.self, forKey: .width)
        // Format v1 archives from the first release contain pen paths without a style field.
        style = try values.decodeIfPresent(InkStyle.self, forKey: .style) ?? .pen
    }
}

public struct NoteAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var mediaType: String
    public var data: Data
    public init(id: UUID = UUID(), filename: String, mediaType: String = "application/octet-stream", data: Data) {
        self.id = id; self.filename = filename; self.mediaType = mediaType; self.data = data
    }
}

public struct NoteNode: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var kind: NoteKind
    public var title: String
    public var body: String
    public var richTextRTF: Data?
    public var strokes: [InkStroke]
    public var pencilKitData: Data?
    public var attachments: [NoteAttachment]
    public var tags: [String]
    public var isFavorite: Bool
    public var isTrashed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var order: Int
    public var paperStyle: PaperStyle
    public var textBoxes: [PageTextBox]
    public var equations: [NoteEquation]

    public init(id: UUID = UUID(), parentID: UUID? = nil, kind: NoteKind, title: String,
                body: String = "", richTextRTF: Data? = nil, strokes: [InkStroke] = [],
                pencilKitData: Data? = nil, attachments: [NoteAttachment] = [], tags: [String] = [],
                isFavorite: Bool = false, isTrashed: Bool = false,
                createdAt: Date = Date(), updatedAt: Date = Date(), order: Int = 0, paperStyle: PaperStyle = .dotted,
                textBoxes: [PageTextBox] = [], equations: [NoteEquation] = []) {
        self.id = id; self.parentID = parentID; self.kind = kind; self.title = title
        self.body = body; self.richTextRTF = richTextRTF; self.strokes = strokes
        self.pencilKitData = pencilKitData; self.attachments = attachments; self.tags = tags
        self.isFavorite = isFavorite; self.isTrashed = isTrashed
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.order = order; self.paperStyle = paperStyle
        self.textBoxes = textBoxes; self.equations = equations
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, kind, title, body, richTextRTF, strokes, pencilKitData, attachments
        case tags, isFavorite, isTrashed, createdAt, updatedAt, order, paperStyle
        case textBoxes, equations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        kind = try values.decode(NoteKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        richTextRTF = try values.decodeIfPresent(Data.self, forKey: .richTextRTF)
        strokes = try values.decode([InkStroke].self, forKey: .strokes)
        pencilKitData = try values.decodeIfPresent(Data.self, forKey: .pencilKitData)
        attachments = try values.decode([NoteAttachment].self, forKey: .attachments)
        tags = try values.decode([String].self, forKey: .tags)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        isTrashed = try values.decode(Bool.self, forKey: .isTrashed)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        order = try values.decode(Int.self, forKey: .order)
        paperStyle = try values.decodeIfPresent(PaperStyle.self, forKey: .paperStyle) ?? .dotted
        textBoxes = try values.decodeIfPresent([PageTextBox].self, forKey: .textBoxes) ?? []
        equations = try values.decodeIfPresent([NoteEquation].self, forKey: .equations) ?? []
    }
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case nodeNotFound
    case invalidTitle
    case invalidParent
    case cycle
    case duplicateID
    case unsupportedVersion(Int)
    case invalidData(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound: "The note no longer exists."
        case .invalidTitle: "Use a title between 1 and 256 characters."
        case .invalidParent: "Workbooks belong at the top level, chapters in workbooks, and topics or sheets in chapters or topics."
        case .cycle: "A topic cannot be moved inside itself or one of its descendants."
        case .duplicateID: "The library contains duplicate identifiers."
        case .unsupportedVersion(let version): "This library uses format version \(version), which this app cannot open."
        case .invalidData(let detail): "Invalid library: \(detail)"
        case .tooLarge: "The library exceeds the 64 MiB archive limit."
        }
    }
}
