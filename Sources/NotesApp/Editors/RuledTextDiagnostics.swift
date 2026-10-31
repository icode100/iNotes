#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

@MainActor
enum RuledTextDiagnostics {
    static func run() throws -> String {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
            guard condition() else { throw NSError(domain: "iNotes.RuledTextDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
            checks += 1
        }
        func baselines(_ view: NSTextView, origin: CGFloat) -> [CGFloat] {
            guard let layout = view.layoutManager, let container = view.textContainer else { return [] }
            layout.ensureLayout(for: container)
            var result: [CGFloat] = [], index = 0
            while index < layout.numberOfGlyphs {
                var range = NSRange()
                let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
                result.append(origin + view.textContainerOrigin.y + rect.minY + layout.location(forGlyphAt: index).y)
                index = NSMaxRange(range)
            }
            return result
        }
        func onGrid(_ values: [CGFloat]) -> Bool {
            !values.isEmpty && values.allSatisfy { abs(($0 + 1) / 28 - (($0 + 1) / 28).rounded()) < 0.001 }
        }
        let view = RichTextEditor.makeNativeTextView()
        view.frame = CGRect(x: 40, y: 40, width: 200, height: 900)
        view.textContainerInset = NSSize(width: 0, height: 12)
        view.textContainer?.containerSize = NSSize(width: 200, height: 10_000)
        view.textContainer?.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: 16)
        view.string = "A\nB\nC"
        RuledTextLayout.attach(to: view, paper: .ruled, pageOriginY: 40)
        let body = baselines(view, origin: 40)
        try require(body.count == 3 && onGrid(body), "Body baselines must sit one point above page rules: \(body); container \(String(describing: view.textContainer?.containerSize)), inset \(view.textContainerOrigin)")
        try require(zip(body, body.dropFirst()).allSatisfy { abs($0.1 - $0.0 - 28) < 0.01 }, "16pt body paragraphs must advance exactly one ruled row")

        let text = "Wrapped Unicode café नमस्ते 👋 continues over several lines without skipping a body row."
        let canonical = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)])
        view.textStorage?.setAttributedString(canonical)
        let wrapped = baselines(view, origin: 40)
        try require(wrapped.count >= 3 && onGrid(wrapped), "Wrapped Unicode baselines must align to the paper")
        try require(zip(wrapped, wrapped.dropFirst()).allSatisfy { abs($0.1 - $0.0 - 28) < 0.01 }, "Fallback glyphs must not double body line spacing")
        // Native NSTextStorage adds Hindi/emoji fallback-font runs during any
        // layout. Establish that native baseline before comparing ruled RTF.
        RuledTextLayout.attach(to: view, paper: .blank, pageOriginY: 40)
        _ = baselines(view, origin: 40)
        let nativeCanonical = ThemeTextAttributes.canonical(view.attributedString(), theme: .light)
        let before = try nativeCanonical.data(from: NSRange(location: 0, length: nativeCanonical.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        var writes = 0
        let coordinator = RichTextEditor.Coordinator(RichTextEditor(text: .constant(text), rtfData: .constant(before), onChange: { _,_ in writes += 1 }))
        view.delegate = coordinator
        coordinator.load(text: text, rtf: before, into: view)
        _ = baselines(view, origin: 40)
        let loadedCanonical = ThemeTextAttributes.canonical(view.attributedString(), theme: .light)
        let loadedBefore = try loadedCanonical.data(from: NSRange(location: 0, length: loadedCanonical.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        RuledTextLayout.attach(to: view, paper: .ruled, pageOriginY: 40)
        coordinator.parent.theme = .dark
        coordinator.load(text: text, rtf: before, into: view)
        try require(onGrid(baselines(view, origin: 40)) && writes == 0, "A theme-only layout update must stay aligned without saving")
        let recovered = ThemeTextAttributes.canonical(view.attributedString(), theme: .dark)
        let after = try recovered.data(from: NSRange(location: 0, length: recovered.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try require(after == loadedBefore && coordinator.lastRTF == before,
                    "Ruled display must preserve canonical RTF, font and color. Natural loaded RTF: \(String(decoding: loadedBefore, as: UTF8.self)); ruled RTF: \(String(decoding: after, as: UTF8.self))")

        view.textStorage?.setAttributedString(NSAttributedString(string: "Heading\nSecond heading", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        let heading = baselines(view, origin: 40)
        try require(onGrid(heading) && zip(heading, heading.dropFirst()).allSatisfy {
            let distance = $0.1 - $0.0
            return distance >= 28 && abs(distance / 28 - (distance / 28).rounded()) < 0.001
        }, "Heading advances must use whole ruled rows")

        view.string = ""
        view.font = .systemFont(ofSize: 16)
        view.typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
        view.textContainerInset = .zero
        RuledTextLayout.attach(to: view, paper: .ruled, pageOriginY: 101)
        guard let layout = view.layoutManager, let container = view.textContainer else { throw CocoaError(.fileReadUnknown) }
        layout.ensureLayout(for: container)
        let caret = 101 + view.textContainerOrigin.y + layout.extraLineFragmentRect.minY + layout.defaultBaselineOffset(for: view.font!)
        try require(onGrid([caret]), "An empty positioned text box must align its typing baseline: \(caret), extra \(layout.extraLineFragmentRect), origin \(view.textContainerOrigin)")
        view.string = "First typed character"
        let typed = baselines(view, origin: 101)
        try require(abs((typed.first ?? 0) - caret) < 0.01, "The first typed line must keep the empty caret's ruled baseline")

        for paper in [InkPaper.blank, .grid, .dotted] {
            RuledTextLayout.attach(to: view, paper: paper, pageOriginY: 101)
            try require(layout.delegate == nil && !onGrid(baselines(view, origin: 101)), "\(paper.rawValue) paper must restore natural native text layout")
            RuledTextLayout.attach(to: view, paper: .ruled, pageOriginY: 101)
        }
        return "\(checks) native ruled-text checks passed (28pt body/wrap spacing, Unicode, headings, empty typing, positioned boxes, canonical RTF, theme without saves and natural non-ruled layout)."
    }
}
#endif
