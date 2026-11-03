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

public enum LinePattern: String, Codable, CaseIterable, Sendable {
    case solid, dashed, dotted

    public var displayName: String { rawValue.capitalized }

    /// Page-space lengths, scaled with the nib rather than the current zoom.
    /// Dotted paths use round line caps to make each short segment a dot.
    public func dashLengths(width: Double) -> [Double] {
        let safeWidth = width.isFinite ? min(100, max(0.5, width)) : 2.5
        switch self {
        case .solid: return []
        case .dashed: return [safeWidth * 6, safeWidth * 3]
        case .dotted: return [0.01, safeWidth * 3]
        }
    }
}

public enum PageTemplate: String, Codable, CaseIterable, Sendable {
    case none, centerDivider, leftMargin

    public var displayName: String {
        switch self {
        case .none: return "No template"
        case .centerDivider: return "Center divider"
        case .leftMargin: return "Left margin"
        }
    }

    public func isSupported(on paper: PaperStyle) -> Bool {
        self != .leftMargin || paper == .blank || paper == .ruled
    }

    /// Retain the chosen template in storage when changing paper; unsupported
    /// combinations simply have no overlay until compatible paper is selected.
    public func effective(on paper: PaperStyle) -> PageTemplate {
        isSupported(on: paper) ? self : .none
    }
}

public struct InkStroke: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var points: [InkPoint]
    public var colorHex: String
    public var width: Double
    public var style: InkStyle
    public var linePattern: LinePattern
    public init(id: UUID = UUID(), points: [InkPoint], colorHex: String = "#202020", width: Double = 2.5, style: InkStyle = .pen,
                linePattern: LinePattern = .solid) {
        self.id = id; self.points = points; self.colorHex = colorHex; self.width = width; self.style = style
        self.linePattern = linePattern
    }

    private enum CodingKeys: String, CodingKey { case id, points, colorHex, width, style, linePattern }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        points = try values.decode([InkPoint].self, forKey: .points)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        width = try values.decode(Double.self, forKey: .width)
        // Format v1 archives from the first release contain pen paths without a style field.
        style = try values.decodeIfPresent(InkStyle.self, forKey: .style) ?? .pen
        linePattern = try values.decodeIfPresent(LinePattern.self, forKey: .linePattern) ?? .solid
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
    /// One-based page position among active sheets in the immediate chapter/topic.
    public var sheetNumber: Int?
    /// Compatibility upper bound for active and Trash numbers, not the next page-number source.
    public var lastSheetNumber: Int
    public var order: Int
    public var paperStyle: PaperStyle
    public var pageTemplate: PageTemplate
    public var templateLinePattern: LinePattern
    public var textBoxes: [PageTextBox]
    public var equations: [NoteEquation]
    public var images: [PageImage]

    public init(id: UUID = UUID(), parentID: UUID? = nil, kind: NoteKind, title: String,
                body: String = "", richTextRTF: Data? = nil, strokes: [InkStroke] = [],
                pencilKitData: Data? = nil, attachments: [NoteAttachment] = [], tags: [String] = [],
                isFavorite: Bool = false, isTrashed: Bool = false,
                createdAt: Date = Date(), updatedAt: Date = Date(), order: Int = 0, paperStyle: PaperStyle = .dotted,
                textBoxes: [PageTextBox] = [], equations: [NoteEquation] = [],
                pageTemplate: PageTemplate = .none, templateLinePattern: LinePattern = .solid,
                sheetNumber: Int? = nil, lastSheetNumber: Int = 0, images: [PageImage] = []) {
        self.id = id; self.parentID = parentID; self.kind = kind; self.title = title
        self.body = body; self.richTextRTF = richTextRTF; self.strokes = strokes
        self.pencilKitData = pencilKitData; self.attachments = attachments; self.tags = tags
        self.isFavorite = isFavorite; self.isTrashed = isTrashed
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.order = order; self.paperStyle = paperStyle
        self.sheetNumber = sheetNumber; self.lastSheetNumber = lastSheetNumber
        self.textBoxes = textBoxes; self.equations = equations
        self.images = images
        self.pageTemplate = pageTemplate; self.templateLinePattern = templateLinePattern
    }

    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return sheetNumber.map { "Sheet \($0)" } ?? "Untitled sheet"
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, kind, title, body, richTextRTF, strokes, pencilKitData, attachments
        case tags, isFavorite, isTrashed, createdAt, updatedAt, order, paperStyle
        case textBoxes, equations, images, pageTemplate, templateLinePattern, sheetNumber, lastSheetNumber
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
        sheetNumber = try values.decodeIfPresent(Int.self, forKey: .sheetNumber)
        lastSheetNumber = try values.decodeIfPresent(Int.self, forKey: .lastSheetNumber) ?? 0
        order = try values.decode(Int.self, forKey: .order)
        paperStyle = try values.decodeIfPresent(PaperStyle.self, forKey: .paperStyle) ?? .dotted
        textBoxes = try values.decodeIfPresent([PageTextBox].self, forKey: .textBoxes) ?? []
        equations = try values.decodeIfPresent([NoteEquation].self, forKey: .equations) ?? []
        images = try values.decodeIfPresent([PageImage].self, forKey: .images) ?? []
        pageTemplate = try values.decodeIfPresent(PageTemplate.self, forKey: .pageTemplate) ?? .none
        templateLinePattern = try values.decodeIfPresent(LinePattern.self, forKey: .templateLinePattern) ?? .solid
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
        case .invalidTitle: "Use up to 256 characters for a sheet title. Workbooks, chapters, and topics need a name."
        case .invalidParent: "Workbooks belong at the top level, chapters in workbooks, and topics or sheets in chapters or topics."
        case .cycle: "A topic cannot be moved inside itself or one of its descendants."
        case .duplicateID: "The library contains duplicate identifiers."
        case .unsupportedVersion(let version): "This library uses format version \(version), which this app cannot open."
        case .invalidData(let detail): "Invalid library: \(detail)"
        case .tooLarge: "The library exceeds the 64 MiB archive limit."
        }
    }
}
