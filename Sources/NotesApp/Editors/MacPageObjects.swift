#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

/// Movable text remains a native rich-text editor; it is layered beneath ink on
/// the same paper and selected together with handwriting by the page overlay.
@MainActor
final class MacPageTextBoxView: NSView {
    let editor = RichTextEditor.makeNativeTextView()
    private var coordinator: RichTextEditor.Coordinator?
    private var lastBox: PageTextBox?
    private var lastTheme: PageTheme?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        addSubview(editor)
        setAccessibilityLabel("Movable page text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ box: PageTextBox, theme: PageTheme, paper: InkPaper, editable: Bool, onChange: @escaping (String, Data?) -> Void) {
        frame.origin = CGPoint(x: box.x, y: box.y)
        setFrameSize(CGSize(width: box.width, height: max(24, frame.height)))
        let rich = RichTextEditor(text: .constant(box.text), rtfData: .constant(box.rtfData), theme: theme, onChange: onChange)
        if coordinator == nil { coordinator = RichTextEditor.Coordinator(rich); editor.delegate = coordinator }
        coordinator?.parent = rich
        editor.frame = bounds
        editor.textContainer?.containerSize = CGSize(width: box.width, height: .greatestFiniteMagnitude)
        RuledTextLayout.attach(to: editor, paper: paper, pageOriginY: box.y + editor.frame.minY)
        if lastBox?.text != box.text || lastBox?.rtfData != box.rtfData || lastTheme != theme {
            coordinator?.load(text: box.text, rtf: box.rtfData, into: editor)
        }
        lastBox = box; lastTheme = theme
        editor.isEditable = editable; editor.isSelectable = editable
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let used = editor.textContainer.flatMap { editor.layoutManager?.usedRect(for: $0).maxY } ?? 0
        let extra = editor.layoutManager?.extraLineFragmentRect.maxY ?? 0
        let natural = editor.attributedString().boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let fallback = paper == .ruled && used == 0 ? ceil(natural / RuledTextLayout.spacing) * RuledTextLayout.spacing + RuledTextLayout.spacing : natural
        let measured = max(used, extra, fallback)
        setFrameSize(CGSize(width: box.width, height: max(24, ceil(measured) + 8)))
        editor.frame = bounds
        editor.textContainer?.containerSize = CGSize(width: box.width, height: .greatestFiniteMagnitude)
    }
}

extension UnifiedMacPageView {
    func displayObjects(textBoxes: [PageTextBox], equations: [NoteEquation], editable: Bool,
                        onTextBoxChange: @escaping (UUID, String, Data?) -> Void,
                        onEquationEdit: ((NoteEquation) -> Void)?) {
        let boxIDs = Set(textBoxes.map(\.id)), equationIDs = Set(equations.map(\.id))
        for id in Array(textBoxViews.keys) where !boxIDs.contains(id) { textBoxViews.removeValue(forKey: id)?.removeFromSuperview() }
        for id in Array(equationViews.keys) where !equationIDs.contains(id) { equationViews.removeValue(forKey: id)?.removeFromSuperview() }
        for box in textBoxes {
            let view = textBoxViews[box.id] ?? MacPageTextBoxView(frame: .zero)
            view.editor.pageUndoManager = selectionController?.history
            if view.superview == nil { addSubview(view, positioned: .below, relativeTo: inkView); textBoxViews[box.id] = view }
            view.configure(box, theme: theme, paper: paperView.paper, editable: editable, onChange: { onTextBoxChange(box.id, $0, $1) })
        }
        for equation in equations {
            let view = equationViews[equation.id] ?? EquationDisplayView(frame: .zero)
            if view.superview == nil { addSubview(view, positioned: .below, relativeTo: inkView); equationViews[equation.id] = view }
            view.frame = CGRect(x: equation.x, y: equation.y, width: equation.width, height: equation.height)
            view.configure(equation: equation, theme: theme, onRequestEdit: { if editable { onEquationEdit?(equation) } })
        }
    }
}
#endif
