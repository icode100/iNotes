import SwiftUI
import NotesCore

/// Source-based editing with a live native preview, shared by Mac and iPad.
struct EquationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: NoteEquation
    let theme: PageTheme
    let onSave: (NoteEquation) -> Void

    init(equation: NoteEquation = NoteEquation(), theme: PageTheme = .light,
         onSave: @escaping (NoteEquation) -> Void) {
        _draft = SwiftUI.State(initialValue: equation)
        self.theme = theme
        self.onSave = onSave
    }

    private var error: String? { EquationDisplayView.validationError(latex: draft.latex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Equation").font(.title2.bold())
            Text("Type LaTeX math. Your equation is rendered on this device and stays editable.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $draft.latex)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 150)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel("LaTeX source")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    example("Fraction", #"\frac{a}{b}"#)
                    example("Root", #"\sqrt{x}"#)
                    example("Power", #"x^{2}"#)
                    example("Integral", #"\int_0^1 x^2\,dx"#)
                    example("Matrix", #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#)
                    example("Greek", #"\alpha + \beta = \gamma"#)
                }
            }
            HStack {
                Text("Size")
                Slider(value: $draft.fontSize, in: 8...120, step: 1)
                Text("\(Int(draft.fontSize)) pt").monospacedDigit().frame(width: 50)
            }
            Text("Preview").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                let size = EquationDisplayView.measuredSize(latex: draft.latex, fontSize: draft.fontSize)
                EquationPreview(equation: draft, theme: theme)
                    .frame(width: max(260, size.width), height: max(100, size.height))
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(Color(hex: theme.paperHex))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityLabel("Equation error: \(error)") }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Equation") {
                    let size = EquationDisplayView.measuredSize(latex: draft.latex, fontSize: draft.fontSize)
                    draft.width = size.width
                    draft.height = size.height
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(error != nil)
            }
        }
        .padding(22)
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 760)
    }

    private func example(_ title: String, _ latex: String) -> some View {
        Button(title) { draft.latex = latex }.buttonStyle(.bordered)
    }
}

#if os(macOS)
private struct EquationPreview: NSViewRepresentable {
    let equation: NoteEquation
    let theme: PageTheme
    func makeNSView(context: Context) -> EquationDisplayView { EquationDisplayView(frame: .zero) }
    func updateNSView(_ view: EquationDisplayView, context: Context) { view.configure(equation: equation, theme: theme) }
}
#else
private struct EquationPreview: UIViewRepresentable {
    let equation: NoteEquation
    let theme: PageTheme
    func makeUIView(context: Context) -> EquationDisplayView { EquationDisplayView(frame: .zero) }
    func updateUIView(_ view: EquationDisplayView, context: Context) { view.configure(equation: equation, theme: theme) }
}
#endif
