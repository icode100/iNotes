import Foundation
import SwiftMath
import NotesCore
#if os(macOS)
import AppKit
typealias EquationPlatformView = NSView
#else
import UIKit
typealias EquationPlatformView = UIView
#endif

/// Native, offline LaTeX math. The source remains separate from its rendered view.
@MainActor
final class EquationDisplayView: EquationPlatformView {
    private let math = MTMathUILabel(frame: .zero)
    private var onRequestEdit: (() -> Void)?
    private struct RenderSignature: Equatable {
        let latex: String
        let fontSize: Double
        let theme: PageTheme
    }
    private var renderSignature: RenderSignature?

    override init(frame: CGRect) {
        super.init(frame: frame)
        math.displayErrorInline = true
        math.font = MTFontManager.manager.latinModernFont(withSize: 24)
        math.textAlignment = .left
        math.labelMode = .display
        addSubview(math)
        #if os(macOS)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        #else
        isAccessibilityElement = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(editEquation))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(equation: NoteEquation, theme: PageTheme, onRequestEdit: (() -> Void)? = nil) {
        self.onRequestEdit = onRequestEdit
        // Page updates arrive during handwriting. Geometry and edit routing may
        // change independently of the math; keep those fresh without reparsing.
        #if os(macOS)
        needsLayout = true
        #else
        setNeedsLayout()
        #endif
        let fontSize = max(8, min(120, equation.fontSize.isFinite ? equation.fontSize : 24))
        let signature = RenderSignature(latex: equation.latex, fontSize: fontSize, theme: theme)
        guard signature != renderSignature else { return }
        renderSignature = signature
        math.fontSize = CGFloat(fontSize)
        math.textColor = ThemeTextAttributes.color(theme.textHex)
        // Reject excessive complexity before invoking the recursive LaTeX parser.
        if let error = Self.sourceLimitError(equation.latex) {
            math.latex = ""
            #if os(macOS)
            math.errorLabel?.stringValue = error
            #else
            math.errorLabel?.text = error
            #endif
            math.errorLabel?.isHidden = false
        } else {
            math.latex = Self.normalizedSource(equation.latex)
        }
        #if os(macOS)
        setAccessibilityLabel("Equation: \(equation.latex)")
        setAccessibilityHelp("Double-click to edit the LaTeX source.")
        needsLayout = true
        needsDisplay = true
        #else
        accessibilityLabel = "Equation: \(equation.latex)"
        accessibilityHint = "Double-tap to edit the LaTeX source."
        setNeedsLayout()
        setNeedsDisplay()
        #endif
        invalidateIntrinsicContentSize()
    }

    static func measuredSize(latex: String, fontSize: Double = 24) -> CGSize {
        guard validationError(latex: latex) == nil else { return CGSize(width: 240, height: 60) }
        let label = MTMathUILabel(frame: .zero)
        label.font = MTFontManager.manager.latinModernFont(withSize: CGFloat(max(8, min(120, fontSize.isFinite ? fontSize : 24))))
        label.fontSize = CGFloat(max(8, min(120, fontSize.isFinite ? fontSize : 24)))
        label.latex = normalizedSource(latex)
        #if os(macOS)
        let size = label.fittingSize
        #else
        let size = label.intrinsicContentSize
        #endif
        return CGSize(width: max(48, min(8_000, ceil(size.width) + 16)),
                      height: max(32, min(8_000, ceil(size.height) + 16)))
    }

    static func validationError(latex: String) -> String? {
        if let error = sourceLimitError(latex) { return error }
        let source = normalizedSource(latex)
        guard !source.isEmpty else { return "Enter a LaTeX equation." }
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: source, error: &error)
        if let error { return error.localizedDescription }
        return list == nil ? "This equation could not be parsed." : nil
    }

    static func normalizedSource(_ latex: String) -> String {
        var source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] {
            if source.count >= open.count + close.count, source.hasPrefix(open), source.hasSuffix(close) {
                source = String(source.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return source
    }

    private static func sourceLimitError(_ source: String) -> String? {
        guard source.count <= NoteEquation.maximumSourceLength else { return "Use at most \(NoteEquation.maximumSourceLength) characters per equation." }
        var depth = 0
        var commands = 0
        var escaped = false
        for character in source {
            if character == "\\" {
                commands += 1
                if commands > 256 { return "Split this expression into smaller equations (at most 256 commands each)." }
                escaped.toggle()
                continue
            }
            if !escaped {
                if character == "{" { depth += 1 }
                else if character == "}" { depth = max(0, depth - 1) }
                if depth > 64 { return "Split this expression into smaller equations (at most 64 nested groups)." }
            }
            escaped = false
        }
        return nil
    }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let size = math.fittingSize
        return NSSize(width: max(48, ceil(size.width) + 16), height: max(32, ceil(size.height) + 16))
    }
    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: 8, dy: 8)
        if math.frame != frame { math.frame = frame }
        math.layoutSubtreeIfNeeded()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRequestEdit?() }
        else { super.mouseDown(with: event) }
    }
    #else
    override var intrinsicContentSize: CGSize {
        let size = math.intrinsicContentSize
        return CGSize(width: max(48, ceil(size.width) + 16), height: max(32, ceil(size.height) + 16))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = bounds.insetBy(dx: 8, dy: 8)
        if math.frame != frame { math.frame = frame }
        math.layoutIfNeeded()
    }
    @objc private func editEquation() { onRequestEdit?() }
    #endif
}
