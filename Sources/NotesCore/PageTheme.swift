import Foundation

/// One application-wide paper preference; notebook colors remain canonical.
public enum PageColorScheme: String, CaseIterable, Sendable {
    case system, vintage

    public var displayName: String { self == .system ? "System theme" : "Vintage" }

    public func resolved(isDark: Bool) -> PageTheme {
        self == .vintage ? .vintage : (isDark ? .dark : .light)
    }
}

/// A display theme for paper and ink. Stored strokes keep their original colors;
/// callers resolve a color while drawing rather than rewriting a notebook.
public enum PageTheme: String, CaseIterable, Sendable {
    case light, dark, vintage

    public var paperHex: String {
        switch self { case .light: "#FFFFFF"; case .dark: "#1B2027"; case .vintage: "#F3E9D2" }
    }
    public var ruleHex: String {
        switch self { case .light: "#8E9FB3"; case .dark: "#63768A"; case .vintage: "#A59679" }
    }
    public var textHex: String { self == .dark ? "#EDF1F5" : "#20242A" }
    public var templateHex: String {
        switch self { case .light: "#9C4C57"; case .dark: "#E4A0AB"; case .vintage: "#995D47" }
    }

    private static let darkPalette: [String: String] = [
        "#30343B": "#EDF1F5",
        "#314D43": "#9BD5BF",
        "#3869B2": "#9CC5FF",
        "#B14D55": "#F4A7B1",
        "#E2B84D": "#F4D27D"
    ]

    /// Resolves the canonical ink color for the displayed paper. Dark paper uses
    /// lighter versions of the palette and lifts dark custom colors by hue.
    public func resolvedInkHex(_ canonical: String) -> String {
        guard let rgb = RGB(hex: canonical) else { return textHex }
        let normalized = rgb.hex
        guard self == .dark else { return normalized }
        if let semantic = Self.darkPalette[normalized] { return semantic }
        // Legacy pens commonly used these near-black values before the palette
        // settled on #30343B. A neutral default should always remain readable.
        if rgb.maximum - rgb.minimum < 0.10 && rgb.lightness < 0.45 { return textHex }
        if rgb.contrast(with: RGB(hex: paperHex)!) >= 4.5 { return normalized }
        let hsl = rgb.hsl
        var lifted = RGB(hue: hsl.hue, saturation: hsl.saturation, lightness: max(0.72, hsl.lightness))
        // Saturated blue can have low luminance despite a high HSL lightness.
        // Keep lifting its lightness, retaining hue and saturation, if needed.
        if lifted.contrast(with: RGB(hex: paperHex)!) < 4.5 {
            lifted = RGB(hue: hsl.hue, saturation: hsl.saturation, lightness: max(0.82, hsl.lightness))
        }
        return lifted.hex
    }

    /// Reverses only the known display palette. Custom color lightening is not
    /// reversible: editors must retain canonical color metadata for those colors.
    public func canonicalInkHex(_ displayed: String) -> String {
        guard let rgb = RGB(hex: displayed) else { return self == .dark ? "#30343B" : textHex }
        let normalized = rgb.hex
        guard self == .dark else { return normalized }
        return Self.darkPalette.first(where: { $0.value == normalized })?.key ?? normalized
    }
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let number = UInt32(value, radix: 16) else { return nil }
        red = Double((number >> 16) & 0xFF) / 255
        green = Double((number >> 8) & 0xFF) / 255
        blue = Double(number & 0xFF) / 255
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = lightness - chroma / 2
        let components: (Double, Double, Double)
        switch sector {
        case 0..<1: components = (chroma, secondary, 0)
        case 1..<2: components = (secondary, chroma, 0)
        case 2..<3: components = (0, chroma, secondary)
        case 3..<4: components = (0, secondary, chroma)
        case 4..<5: components = (secondary, 0, chroma)
        default: components = (chroma, 0, secondary)
        }
        red = components.0 + offset
        green = components.1 + offset
        blue = components.2 + offset
    }

    var maximum: Double { max(red, green, blue) }
    var minimum: Double { min(red, green, blue) }
    var lightness: Double { (maximum + minimum) / 2 }

    var hex: String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, lightness) }
        let hue: Double
        if maximum == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if maximum == green { hue = (blue - red) / delta + 2 }
        else { hue = (red - green) / delta + 4 }
        let normalizedHue = hue < 0 ? hue / 6 + 1 : hue / 6
        let saturation = delta / (1 - abs(2 * lightness - 1))
        return (normalizedHue, saturation, lightness)
    }

    var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: RGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}
