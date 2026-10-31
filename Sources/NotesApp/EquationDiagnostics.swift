#if os(macOS)
import AppKit
import NotesCore

@MainActor
enum EquationDiagnostics {
    static func run() throws -> String {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "iNotes.EquationDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let examples = [
            #"E=mc^2"#,
            #"\frac{a+b}{c}"#,
            #"\sqrt{x^2+y^2}"#,
            #"\alpha+\beta=\gamma"#,
            #"\int_0^1 x^2\,dx"#,
            #"\sum_{n=1}^{\infty}\frac{1}{n^2}"#,
            #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#
        ]
        for latex in examples {
            try require(EquationDisplayView.validationError(latex: latex) == nil, "Native LaTeX parser must accept \(latex)")
            let size = EquationDisplayView.measuredSize(latex: latex)
            try require(size.width.isFinite && size.height.isFinite && size.width >= 48 && size.height >= 32, "Native equation must have finite measurable bounds")
        }
        for latex in ["", #"\unsupportedcommand{x}"#, #"\frac{a"#, #"\input{secret}"#,
                      String(repeating: "{", count: 65) + "x" + String(repeating: "}", count: 65),
                      String(repeating: #"\alpha "#, count: 257),
                      String(repeating: "x", count: NoteEquation.maximumSourceLength + 1)] {
            try require(EquationDisplayView.validationError(latex: latex) != nil, "Invalid or excessive LaTeX must report an error")
        }
        try require(EquationDisplayView.normalizedSource(#"$$\frac{a}{b}$$"#) == #"\frac{a}{b}"#, "Display delimiters must be accepted without altering stored source")
        let small = EquationDisplayView.measuredSize(latex: "x^2", fontSize: 24)
        let large = EquationDisplayView.measuredSize(latex: "x^2", fontSize: 100)
        try require(large.width > small.width * 2, "Imported large font sizes must preserve their geometry")

        let equation = NoteEquation(latex: #"\frac{\alpha^2}{\sqrt{x}}"#, width: 240, height: 140)
        let decoded = try JSONDecoder().decode(NoteEquation.self, from: JSONEncoder().encode(equation))
        try require(decoded == equation, "LaTeX source, identity, position and size must round-trip")
        let view = EquationDisplayView(frame: CGRect(x: 0, y: 0, width: 240, height: 140))
        for theme in [PageTheme.light, .dark] {
            view.configure(equation: equation, theme: theme)
            // Unrelated ink edits reconfigure the same equation repeatedly.
            // The retained native projection must still render in each theme.
            view.configure(equation: equation, theme: theme)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var visibleInk = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if theme == .dark ? brightness > 0.65 : brightness < 0.6 { visibleInk += 1 }
                }
            }
            try require(visibleInk > 20, "Native equation glyphs must render visibly for \(theme.rawValue) paper")
            let png = bitmap.representation(using: .png, properties: [:])
            try require((png?.count ?? 0) > 200, "Native equation PNG export must contain rendered content")
            let pdf = view.dataWithPDF(inside: view.bounds)
            try require(pdf.starts(with: Data("%PDF".utf8)) && pdf.count > 500, "Native equation PDF export must preserve rendered glyphs")
        }
        let previousSize = view.intrinsicContentSize
        var edited = equation
        edited.latex = #"\int_0^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#
        view.configure(equation: edited, theme: .dark)
        view.layoutSubtreeIfNeeded()
        try require(view.intrinsicContentSize.width > previousSize.width && equation == decoded,
                    "Changed source must update the native layout while appearance preserves stored LaTeX")
        return "\(checks) native equation checks passed (fractions, roots, powers, Greek, integrals, matrices, parse errors and bounds, source round-trip, light/dark glyphs, PNG/PDF)."
    }
}
#endif
