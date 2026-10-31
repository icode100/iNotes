import Foundation

/// Editable LaTeX math positioned in the same page coordinate space as text and ink.
public struct NoteEquation: Identifiable, Codable, Equatable, Sendable {
    public static let maximumSourceLength = 16_384
    public var id: UUID
    public var latex: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var fontSize: Double

    public init(id: UUID = UUID(), latex: String = "E=mc^2", x: Double = 40, y: Double = 80,
                width: Double = 300, height: Double = 100, fontSize: Double = 24) {
        self.id = id
        self.latex = latex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fontSize = fontSize
    }
}
