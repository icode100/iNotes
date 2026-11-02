import Foundation

/// A positioned PNG beneath text and ink. Pixel bytes are canonical, not themed.
public struct PageImage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var imageData: Data

    public init(id: UUID = UUID(), x: Double = 40, y: Double = 40,
                width: Double = 400, height: Double = 300, imageData: Data) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
        self.imageData = imageData
    }
}

/// Portable preflight limits apply before any native image decoder is invoked.
public enum PageImageLimits {
    public static let maximumBytes = 10 * 1_024 * 1_024
    public static let maximumPixelDimension = 8_192
    public static let maximumPixels = 16_000_000
    public static let maximumPagePixels = 64_000_000
    public static let maximumImagesPerPage = 100

    public static func validate(_ images: [PageImage]) throws {
        guard images.count <= maximumImagesPerPage else { throw LibraryError.tooLarge }
        guard Set(images.map(\.id)).count == images.count else { throw LibraryError.duplicateID }
        var pixels = 0
        for image in images {
            guard image.x.isFinite, image.y.isFinite, image.width.isFinite, image.height.isFinite,
                  (0...100_000).contains(image.x), (0...100_000).contains(image.y),
                  (1...10_000).contains(image.width), (1...10_000).contains(image.height) else {
                throw LibraryError.invalidData("An image has invalid page coordinates or size.")
            }
            let size = try pngDimensions(image.imageData)
            pixels += size.width * size.height
            guard pixels <= maximumPagePixels else { throw LibraryError.tooLarge }
        }
    }

    /// Checks the PNG container and declared dimensions without decoding pixels.
    /// Native rendering must still handle corrupt compressed image data safely.
    public static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count <= maximumBytes else { throw LibraryError.tooLarge }
        let malformed = LibraryError.invalidData("A page image must contain a valid PNG.")
        guard data.count >= 45 else { throw malformed }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func uint32(_ offset: Int) -> Int {
                (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            }
            let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
            guard signature.indices.allSatisfy({ bytes[$0] == signature[$0] }),
                  uint32(8) == 13, uint32(12) == 0x49484452 else { throw malformed }
            let width = uint32(16), height = uint32(20)
            guard width > 0, height > 0, width <= maximumPixelDimension,
                  height <= maximumPixelDimension, width * height <= maximumPixels else {
                throw LibraryError.tooLarge
            }
            let depth = bytes[24], color = bytes[25]
            let validDepth: Bool
            switch color {
            case 0: validDepth = [1, 2, 4, 8, 16].contains(depth)
            case 2, 4, 6: validDepth = [8, 16].contains(depth)
            case 3: validDepth = [1, 2, 4, 8].contains(depth)
            default: validDepth = false
            }
            guard validDepth, bytes[26] == 0, bytes[27] == 0, bytes[28] <= 1 else { throw malformed }
            var offset = 33, sawPixels = false
            while offset <= bytes.count - 12 {
                let length = uint32(offset), type = uint32(offset + 4)
                guard length <= bytes.count - offset - 12 else { throw malformed }
                // Canonical page images are static; animation cannot multiply work.
                guard type != 0x49484452, type != 0x6163544C else { throw malformed }
                if type == 0x49444154 { sawPixels = sawPixels || length > 0 }
                if type == 0x49454E44 {
                    guard length == 0, sawPixels, offset + 12 == bytes.count else { throw malformed }
                    return (width, height)
                }
                offset += length + 12
            }
            throw malformed
        }
    }
}

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
}

extension NoteNode {
    public var plainTextExport: String {
        ([body] + textBoxes.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.map(\.text)
         + equations.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.map { "$$\n\($0.latex)\n$$" })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var pageContent: PageContent {
        get { PageContent(text: body, rtfData: richTextRTF, strokes: strokes,
                          pencilKitData: pencilKitData, textBoxes: textBoxes, equations: equations, images: images) }
        set {
            body = newValue.text; richTextRTF = newValue.rtfData; strokes = newValue.strokes
            pencilKitData = newValue.pencilKitData; textBoxes = newValue.textBoxes; equations = newValue.equations
            images = newValue.images
        }
    }
}
