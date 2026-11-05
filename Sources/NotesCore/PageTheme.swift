import Foundation

/// One application-wide paper preference; notebook colors remain canonical.
public enum PageColorScheme: String, CaseIterable, Sendable {
    // Preserve the stored `vintage` value used by earlier releases.
    case system, vintage, vintageBlack, pitchBlack, pitchWhite
    case pastelPeach, pastelRose, pastelLavender, pastelMint, pastelSky

    public var displayName: String {
        switch self {
        case .system: return "Match scenery and appearance"
        case .vintage: return "Vintage White"
        case .vintageBlack: return "Vintage Black"
        case .pitchBlack: return "Pitch Black"
        case .pitchWhite: return "Pitch White"
        case .pastelPeach: return "Pastel Peach"
        case .pastelRose: return "Pastel Rose"
        case .pastelLavender: return "Pastel Lavender"
        case .pastelMint: return "Pastel Mint"
        case .pastelSky: return "Pastel Sky"
        }
    }

    /// Scenery affects only the matching choice. Explicit papers stay fixed
    /// through appearance/scenery changes, including the legacy vintage choice.
    public func resolved(isDark: Bool, scenery: String = "classic") -> PageTheme {
        switch self {
        case .system:
            switch scenery {
            case "coast": return isDark ? .coastDark : .coastLight
            case "alpine": return isDark ? .alpineDark : .alpineLight
            case "arctic": return isDark ? .arcticDark : .arcticLight
            case "open-skyscape": return isDark ? .skyscapeDark : .skyscapeLight
            case "ruby-hills": return isDark ? .rubyDark : .rubyLight
            case "nature", "forest": return isDark ? .natureDark : .natureLight
            default: return isDark ? .dark : .light
            }
        case .vintage: return .vintage
        case .vintageBlack: return .vintageBlack
        case .pitchBlack: return .pitchBlack
        case .pitchWhite: return .pitchWhite
        case .pastelPeach: return .pastelPeach
        case .pastelRose: return .pastelRose
        case .pastelLavender: return .pastelLavender
        case .pastelMint: return .pastelMint
        case .pastelSky: return .pastelSky
        }
    }
}

/// A display theme for paper and ink. Stored strokes keep their original colors;
/// callers resolve a color while drawing rather than rewriting a notebook.
public enum PageTheme: String, CaseIterable, Sendable {
    case light, dark, vintage, vintageBlack, pitchBlack, pitchWhite
    case coastLight, coastDark, alpineLight, alpineDark, arcticLight, arcticDark
    case skyscapeLight, skyscapeDark, rubyLight, rubyDark, natureLight, natureDark
    case pastelPeach, pastelRose, pastelLavender, pastelMint, pastelSky

    public var isDark: Bool {
        switch self {
        case .dark, .vintageBlack, .pitchBlack, .coastDark, .alpineDark,
             .arcticDark, .skyscapeDark, .rubyDark, .natureDark: return true
        default: return false
        }
    }

    public var paperHex: String {
        switch self {
        case .light, .pitchWhite: return "#FFFFFF"
        case .dark: return "#1B2027"
        case .vintage: return "#F3E9D2"
        case .vintageBlack: return "#26231E"
        case .pitchBlack: return "#000000"
        case .coastLight: return "#F0F7F8"
        case .coastDark: return "#18262B"
        case .alpineLight: return "#F3F0FA"
        case .alpineDark: return "#211F2C"
        case .arcticLight: return "#F0F8FA"
        case .arcticDark: return "#172831"
        case .skyscapeLight: return "#F0F6FC"
        case .skyscapeDark: return "#1C2635"
        case .rubyLight: return "#FAF0F1"
        case .rubyDark: return "#26191F"
        case .natureLight: return "#F3F6EB"
        case .natureDark: return "#20281D"
        case .pastelPeach: return "#FBE9DC"
        case .pastelRose: return "#F8E5ED"
        case .pastelLavender: return "#EDE7F8"
        case .pastelMint: return "#E4F3E9"
        case .pastelSky: return "#E4F0FA"
        }
    }

    public var ruleHex: String {
        switch self {
        case .light: return "#8E9FB3"
        case .dark: return "#63768A"
        case .vintage: return "#A59679"
        case .vintageBlack: return "#8D816C"
        case .pitchBlack: return "#777777"
        case .pitchWhite: return "#929292"
        case .coastLight: return "#829DA3"
        case .coastDark: return "#64858E"
        case .alpineLight: return "#9890AF"
        case .alpineDark: return "#81769D"
        case .arcticLight: return "#829DA8"
        case .arcticDark: return "#678B9E"
        case .skyscapeLight: return "#859BB4"
        case .skyscapeDark: return "#7087A7"
        case .rubyLight: return "#AA8B92"
        case .rubyDark: return "#946B78"
        case .natureLight: return "#909D7E"
        case .natureDark: return "#7A8A68"
        case .pastelPeach: return "#A98C77"
        case .pastelRose: return "#AB8596"
        case .pastelLavender: return "#9789AD"
        case .pastelMint: return "#809C89"
        case .pastelSky: return "#8199AF"
        }
    }

    public var textHex: String {
        self == .vintageBlack ? "#F0E7D5" : (isDark ? "#EDF1F5" : "#20242A")
    }

    public var templateHex: String {
        switch self {
        case .vintage: return "#995D47"
        case .vintageBlack: return "#D9B28C"
        case .pitchBlack: return "#A0A0A0"
        case .pitchWhite: return "#686868"
        default: return isDark ? "#E4A0AB" : "#9C4C57"
        }
    }

    private static let darkPalette: [String: String] = [
        "#30343B": "#EDF1F5",
        "#314D43": "#9BD5BF",
        "#3869B2": "#9CC5FF",
        "#B14D55": "#F4A7B1",
        "#E2B84D": "#F4D27D"
    ]

    /// Resolves canonical ink for the displayed paper. All dark papers use
    /// lighter palette colors and lift dark custom colors while retaining hue.
    public func resolvedInkHex(_ canonical: String) -> String {
        guard let rgb = RGB(hex: canonical) else { return textHex }
        let normalized = rgb.hex
        guard isDark else { return normalized }
        if normalized == "#30343B" { return textHex }
        if let semantic = Self.darkPalette[normalized] { return semantic }
        // Legacy pens commonly used these near-black values before the palette
        // settled on #30343B. A neutral default should always remain readable.
        if rgb.maximum - rgb.minimum < 0.10 && rgb.lightness < 0.45 { return textHex }
        let paper = RGB(hex: paperHex)!
        if rgb.contrast(with: paper) >= 4.5 { return normalized }
        let hsl = rgb.hsl
        var lifted = RGB(hue: hsl.hue, saturation: hsl.saturation, lightness: max(0.72, hsl.lightness))
        // Saturated blue can have low luminance despite a high HSL lightness.
        // Keep lifting its lightness, retaining hue and saturation, if needed.
        if lifted.contrast(with: paper) < 4.5 {
            lifted = RGB(hue: hsl.hue, saturation: hsl.saturation, lightness: max(0.82, hsl.lightness))
        }
        return lifted.hex
    }

    /// Reverses only the known display palette. Custom color lightening is not
    /// reversible: editors must retain canonical color metadata for those colors.
    public func canonicalInkHex(_ displayed: String) -> String {
        guard let rgb = RGB(hex: displayed) else { return isDark ? "#30343B" : textHex }
        let normalized = rgb.hex
        guard isDark else { return normalized }
        if normalized == textHex { return "#30343B" }
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
