import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class PageThemeTests: XCTestCase {
    private let palette = ["#30343B", "#314D43", "#3869B2", "#B14D55", "#E2B84D"]

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
                _ = PageTheme.dark.resolvedInkHex(stroke.colorHex)
                _ = PageTheme.light.resolvedInkHex(stroke.colorHex)
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
