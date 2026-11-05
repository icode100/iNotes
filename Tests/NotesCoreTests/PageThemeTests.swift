import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class PageThemeTests: XCTestCase {
    private let palette = ["#30343B", "#314D43", "#3869B2", "#B14D55", "#E2B84D"]

    func testGlobalPaperPreferenceAndVintageContrast() {
        XCTAssertEqual(PageColorScheme.system.resolved(isDark: false), .light)
        XCTAssertEqual(PageColorScheme.system.resolved(isDark: true), .dark)
        XCTAssertEqual(PageColorScheme.vintage.resolved(isDark: false), .vintage)
        XCTAssertEqual(PageColorScheme.vintage.resolved(isDark: true), .vintage)
        XCTAssertTrue(contrast(PageTheme.vintage.textHex, PageTheme.vintage.paperHex) >= 7)
        XCTAssertTrue(contrast(PageTheme.vintage.ruleHex, PageTheme.vintage.paperHex) >= 2.3)
        for theme in PageTheme.allCases {
            XCTAssertTrue(contrast(theme.templateHex, theme.paperHex) >= 3)
        }
        for color in palette {
            XCTAssertEqual(PageTheme.vintage.resolvedInkHex(color), color)
            XCTAssertEqual(PageTheme.vintage.canonicalInkHex(color), color)
        }
        XCTAssertEqual(PageTheme.vintage.resolvedInkHex("invalid"), PageTheme.vintage.textHex)
    }

    func testMatchingPaperFollowsSceneryAndLegacyForestPreference() {
        let scenery = ["classic", "coast", "alpine", "arctic", "open-skyscape", "ruby-hills", "nature"]
        let light = scenery.map { PageColorScheme.system.resolved(isDark: false, scenery: $0) }
        let dark = scenery.map { PageColorScheme.system.resolved(isDark: true, scenery: $0) }
        XCTAssertEqual(Set(light.map(\.paperHex)).count, scenery.count)
        XCTAssertEqual(Set(dark.map(\.paperHex)).count, scenery.count)
        for index in scenery.indices {
            XCTAssertFalse(light[index].isDark)
            XCTAssertTrue(dark[index].isDark)
            XCTAssertNotEqual(light[index], dark[index])
        }
        let ruby = channels(PageColorScheme.system.resolved(isDark: true, scenery: "ruby-hills").paperHex)
        XCTAssertTrue(ruby.red > ruby.blue && ruby.blue > ruby.green)
        let nature = channels(PageColorScheme.system.resolved(isDark: true, scenery: "nature").paperHex)
        XCTAssertTrue(nature.green > nature.red && nature.green > nature.blue)
        for isDark in [false, true] {
            XCTAssertEqual(PageColorScheme.system.resolved(isDark: isDark, scenery: "forest"),
                           PageColorScheme.system.resolved(isDark: isDark, scenery: "nature"))
            XCTAssertEqual(PageColorScheme.system.resolved(isDark: isDark, scenery: "unknown"),
                           PageColorScheme.system.resolved(isDark: isDark))
        }
    }

    func testExplicitPaperChoicesStayFixedAndPitchGuidesAreNeutral() {
        XCTAssertEqual(PageColorScheme(rawValue: "vintage"), .vintage)
        for choice in PageColorScheme.allCases where choice != .system {
            let expected = choice.resolved(isDark: false)
            for isDark in [false, true] {
                for scenery in ["classic", "ruby-hills", "forest", "open-skyscape"] {
                    XCTAssertEqual(choice.resolved(isDark: isDark, scenery: scenery), expected)
                }
            }
        }
        XCTAssertEqual(PageTheme.pitchBlack.paperHex, "#000000")
        XCTAssertEqual(PageTheme.pitchWhite.paperHex, "#FFFFFF")
        for theme in [PageTheme.pitchBlack, .pitchWhite] {
            let guide = channels(theme.ruleHex)
            XCTAssertEqual(guide.red, guide.green)
            XCTAssertEqual(guide.green, guide.blue)
            XCTAssertNotEqual(theme.ruleHex, theme.paperHex)
        }
        let pastels: [PageTheme] = [.pastelPeach, .pastelRose, .pastelLavender, .pastelMint, .pastelSky]
        XCTAssertEqual(Set(pastels.map(\.paperHex)).count, pastels.count)
        for pastel in pastels {
            XCTAssertFalse(pastel.isDark)
            XCTAssertNotEqual(pastel.paperHex, PageTheme.light.paperHex)
        }
    }

    func testEveryPaperHasReadableTextGuidesAndTemplate() {
        for theme in PageTheme.allCases {
            XCTAssertTrue(contrast(theme.textHex, theme.paperHex) >= 7)
            XCTAssertTrue(contrast(theme.ruleHex, theme.paperHex) >= 2.3)
            XCTAssertTrue(contrast(theme.templateHex, theme.paperHex) >= 3)
            XCTAssertEqual(theme.resolvedInkHex("invalid"), theme.textHex)
        }
    }

    func testAllDarkPapersAdaptPaletteAndCustomInkWithoutLosingCanonicalColors() {
        for theme in PageTheme.allCases where theme.isDark {
            for canonical in palette {
                let displayed = theme.resolvedInkHex(canonical)
                XCTAssertTrue(contrast(displayed, theme.paperHex) >= 4.5)
                XCTAssertEqual(theme.canonicalInkHex(displayed), canonical)
            }
            for custom in ["#102040", "#330F35", "#174B20", "#6A3200", "#1100FF", "#880000"] {
                let displayed = theme.resolvedInkHex(custom)
                XCTAssertTrue(contrast(displayed, theme.paperHex) >= 4.5)
                // Lifting is deliberately not reversed into an approximate
                // original; native text/ink metadata retains the exact source.
                XCTAssertEqual(theme.canonicalInkHex(displayed), displayed)
            }
            XCTAssertEqual(theme.resolvedInkHex("#FFFF00"), "#FFFF00")
            XCTAssertEqual(theme.resolvedInkHex("#FFFFFF"), "#FFFFFF")
        }
    }

    func testDefaultTextAndDarkInkContrast() {
        XCTAssertTrue(contrast(PageTheme.dark.textHex, PageTheme.dark.paperHex) >= 7)
        XCTAssertTrue(contrast(PageTheme.light.textHex, PageTheme.light.paperHex) >= 7)
        for color in palette {
            XCTAssertTrue(contrast(PageTheme.dark.resolvedInkHex(color), PageTheme.dark.paperHex) >= 3)
        }
        XCTAssertNotEqual(PageTheme.dark.paperHex, PageTheme.light.paperHex)
        XCTAssertNotEqual(PageTheme.dark.ruleHex, PageTheme.dark.paperHex)
        XCTAssertNotEqual(PageTheme.light.ruleHex, PageTheme.light.paperHex)
        XCTAssertTrue(contrast(PageTheme.light.ruleHex, PageTheme.light.paperHex) >= 2.4)
        XCTAssertTrue(contrast(PageTheme.dark.ruleHex, PageTheme.dark.paperHex) >= 2.8)
        XCTAssertEqual(PageTheme.dark.resolvedInkHex("#20242A"), PageTheme.dark.textHex)
    }

    func testKnownPaletteRoundTripsBetweenDisplayAndStorage() {
        for canonical in palette {
            XCTAssertEqual(PageTheme.light.resolvedInkHex(canonical), canonical)
            let displayed = PageTheme.dark.resolvedInkHex(canonical)
            XCTAssertNotEqual(displayed, canonical)
            XCTAssertEqual(PageTheme.dark.canonicalInkHex(displayed), canonical)
        }
        XCTAssertEqual(PageTheme.dark.resolvedInkHex("#000000"), PageTheme.dark.textHex)
        XCTAssertEqual(PageTheme.dark.resolvedInkHex("#202020"), PageTheme.dark.textHex)
    }

    func testCustomDarkHuesLightenButBrightColorsStayUnchanged() {
        let navy = PageTheme.dark.resolvedInkHex("#102040")
        let components = channels(navy)
        XCTAssertTrue(components.blue > components.green && components.green > components.red)
        XCTAssertTrue(contrast(navy, PageTheme.dark.paperHex) >= 4.5)
        XCTAssertEqual(PageTheme.dark.resolvedInkHex("#FFFF00"), "#FFFF00")
        XCTAssertEqual(PageTheme.dark.resolvedInkHex("#FFFFFF"), "#FFFFFF")
        XCTAssertEqual(PageTheme.light.resolvedInkHex("#102040"), "#102040")
        // A renderer must retain custom canonical values rather than trying to
        // undo an inherently lossy lightness transform.
        XCTAssertEqual(PageTheme.dark.canonicalInkHex(navy), navy)
    }

    func testHexNormalizationAndInvalidInputHaveReadableFallbacks() {
        XCTAssertEqual(PageTheme.light.resolvedInkHex("  abc  "), "#AABBCC")
        XCTAssertEqual(PageTheme.light.resolvedInkHex("#f0e1d2"), "#F0E1D2")
        for invalid in ["", "#", "#12", "#GGGGGG", "#12345678", "#12 456", "nan"] {
            XCTAssertEqual(PageTheme.light.resolvedInkHex(invalid), PageTheme.light.textHex)
            XCTAssertEqual(PageTheme.dark.resolvedInkHex(invalid), PageTheme.dark.textHex)
        }
    }

    func testThemeResolutionNeverRewritesArchivedStrokes() throws {
        var library = NoteLibrary.sample()
        var note = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        note.strokes = palette.enumerated().map { index, hex in
            InkStroke(points: [InkPoint(x: Double(index * 10), y: 20, pressure: 0.7)], colorHex: hex, style: .pen)
        }
        try library.update(note)
        let before = try LibraryArchive.encode(library)
        for _ in 0..<20 {
            for stroke in note.strokes {
                for theme in PageTheme.allCases {
                    _ = theme.resolvedInkHex(stroke.colorHex)
                }
            }
        }
        let after = try LibraryArchive.encode(library)
        XCTAssertEqual(before, after)
        XCTAssertEqual(try LibraryArchive.decode(after).node(id: note.id)?.strokes, note.strokes)
    }

    private func channels(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }

    private func contrast(_ first: String, _ second: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let rgb = channels(hex)
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
