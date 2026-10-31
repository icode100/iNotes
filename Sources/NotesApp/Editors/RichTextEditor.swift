import SwiftUI
import NotesCore

enum RichTextCommand: String, CaseIterable {
    case bold, italic, underline, heading, body, bullet, checklist
}

#if os(macOS)
import AppKit

/// An AppKit text system keeps typing, selection, spelling and undo native.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    var theme: PageTheme = .light
    var onChange: ((String, Data?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let editor = Self.makeNativeTextView()
        editor.delegate = context.coordinator
        editor.isEditable = context.environment.isEnabled
        scrollView.documentView = editor
        context.coordinator.load(text: text, rtf: rtfData, into: editor)
        return scrollView
    }

    static func makeNativeTextView() -> NotesTextView {
        let editor = NotesTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.isAutomaticLinkDetectionEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.usesFindPanel = true
        editor.usesFontPanel = true
        editor.usesRuler = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 30, height: 26)
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.usesAdaptiveColorMappingForDarkAppearance = false
        editor.setAccessibilityLabel("Sheet text")
        editor.setAccessibilityHelp("Rich text editor. Use the Format menu to style selected text.")
        return editor
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView else { return }
        editor.isEditable = context.environment.isEnabled
        if context.coordinator.lastText != text || context.coordinator.lastRTF != rtfData || context.coordinator.lastTheme != theme {
            let contentChanged = context.coordinator.lastText != text || context.coordinator.lastRTF != rtfData
            context.coordinator.load(text: text, rtf: rtfData, into: editor)
            if contentChanged { editor.undoManager?.removeAllActions() }
        }
    }

    static func perform(_ command: RichTextCommand) {
        // Toolbar controls can temporarily hold focus; remember only our editor,
        // never a title/search field's shared Cocoa field editor.
        let firstResponder = NSApp.keyWindow?.firstResponder
        if let fieldEditor = firstResponder as? NSTextView, !(fieldEditor is NotesTextView) { return }
        guard let editor = firstResponder as? NotesTextView ?? NotesTextView.activeEditor,
              editor.isEditable, editor.window != nil, !editor.isHiddenOrHasHiddenAncestor,
              NSApp.keyWindow == nil || editor.window === NSApp.keyWindow else { return }
        switch command {
        case .bold, .italic:
            let manager = NSFontManager.shared
            let range = editor.selectedRange()
            let font: NSFont
            if range.location < editor.attributedString().length,
               let selectedFont = editor.attributedString().attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                font = selectedFont
            } else {
                font = editor.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 16)
            }
            manager.setSelectedFont(font, isMultiple: range.length > 0)
            let trait: NSFontTraitMask = command == .bold ? .boldFontMask : .italicFontMask
            let sender = NSMenuItem()
            sender.tag = Int(trait.rawValue)
            let previousTarget = manager.target
            let previousAction = manager.action
            manager.target = editor
            manager.action = #selector(NSTextView.changeFont(_:))
            defer { manager.target = previousTarget; manager.action = previousAction }
            if manager.traits(of: font).contains(trait) {
                manager.removeFontTrait(sender)
            } else {
                manager.addFontTrait(sender)
            }
        case .underline:
            editor.underline(nil)
        case .heading, .body:
            let font = command == .heading
                ? NSFont.systemFont(ofSize: 26, weight: .semibold)
                : NSFont.systemFont(ofSize: 16)
            let range = editor.selectedRange()
            if range.length > 0 {
                guard editor.shouldChangeText(in: range, replacementString: nil) else { return }
                editor.textStorage?.addAttribute(.font, value: font, range: range)
                editor.didChangeText()
            } else {
                editor.typingAttributes[.font] = font
            }
        case .bullet, .checklist:
            let string = editor.string as NSString
            let selected = editor.selectedRange()
            let lineRange = string.lineRange(for: NSRange(location: min(selected.location, string.length), length: 0))
            let line = string.substring(with: lineRange)
            if command == .checklist, line.hasPrefix("☐ ") || line.hasPrefix("☑ ") {
                let replacement = line.hasPrefix("☐ ") ? "☑ " : "☐ "
                editor.insertText(replacement, replacementRange: NSRange(location: lineRange.location, length: 2))
            } else {
                editor.insertText(command == .bullet ? "• " : "☐ ", replacementRange: NSRange(location: lineRange.location, length: 0))
            }
        }
        RuledTextLayout.refresh(editor)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastText: String?
        var lastRTF: Data?
        var lastTheme: PageTheme?
        private var isLoading = false
        private weak var editor: NSTextView?
        private var undoObservers: [NSObjectProtocol] = []

        init(_ parent: RichTextEditor) {
            self.parent = parent
            super.init()
            // Cocoa can replay an undo directly into text storage without
            // delivering NSTextViewDelegate.textDidChange on every SDK.
            for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let editor = self.editor,
                              let manager = notification.object as? UndoManager,
                              manager === editor.undoManager else { return }
                        self.persist(editor)
                    }
                })
            }
        }

        deinit {
            for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        }

        func load(text: String, rtf: Data?, into editor: NSTextView) {
            self.editor = editor
            isLoading = true
            defer { isLoading = false }
            let selected = editor.selectedRange()
            let canonical: NSAttributedString
            if let rtf,
               let richText = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               richText.string == text {
                canonical = richText
            } else {
                canonical = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)
                ])
            }
            editor.appearance = NSAppearance(named: parent.theme == .dark ? .darkAqua : .aqua)
            editor.backgroundColor = ThemeTextAttributes.color(parent.theme.paperHex)
            editor.textStorage?.setAttributedString(ThemeTextAttributes.display(canonical, theme: parent.theme))
            editor.setSelectedRange(ThemeTextAttributes.clipped(selected, length: (text as NSString).length))
            editor.typingAttributes[.foregroundColor] = ThemeTextAttributes.color(parent.theme.resolvedInkHex(PageTheme.light.textHex))
            editor.typingAttributes[ThemeTextAttributes.canonicalColorKey] = ThemeTextAttributes.color(PageTheme.light.textHex)
            lastText = text
            lastRTF = rtf
            lastTheme = parent.theme
            RuledTextLayout.refresh(editor)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let editor = notification.object as? NSTextView else { return }
            persist(editor)
        }

        private func persist(_ editor: NSTextView) {
            guard !isLoading else { return }
            let text = editor.string
            let canonical = ThemeTextAttributes.canonical(editor.attributedString(), theme: parent.theme)
            let rtf = try? canonical.data(
                from: NSRange(location: 0, length: (text as NSString).length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            guard text != lastText || rtf != lastRTF else { return }
            let display = ThemeTextAttributes.display(canonical, theme: parent.theme)
            if !editor.attributedString().isEqual(to: display) {
                isLoading = true
                let selected = editor.selectedRange()
                let undo = editor.undoManager
                let registering = undo?.isUndoRegistrationEnabled == true
                if registering { undo?.disableUndoRegistration() }
                if let storage = editor.textStorage { ThemeTextAttributes.applyDisplayAttributes(display, to: storage) }
                editor.setSelectedRange(ThemeTextAttributes.clipped(selected, length: display.length))
                if registering { undo?.enableUndoRegistration() }
                isLoading = false
            }
            lastText = text
            lastRTF = rtf
            if let onChange = parent.onChange {
                onChange(text, rtf)
            } else {
                parent.text = text
                parent.rtfData = rtf
            }
        }
    }
}

@MainActor
final class NotesTextView: NSTextView {
    // Native text tracking still receives cursor updates underneath the ink
    // layer. Follow the page's active tool without disabling native editing.
    var pageCursorProvider: (() -> NSCursor?)?

    override func resetCursorRects() {
        // The ink/selection layer covers the page in these modes. Avoid an
        // overlapping text rectangle that could cache an old nib width/zoom.
        if pageCursorProvider?() == nil { super.resetCursorRects() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = pageCursorProvider?() { cursor.set() }
        else { super.cursorUpdate(with: event) }
    }

    var usesRuledPaper = false
    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        // Vertically resizable text views otherwise subtract the first used
        // fragment's padding, cancelling its page-aligned baseline phase.
        if usesRuledPaper { origin.y = textContainerInset.height }
        return origin
    }
    static weak var activeEditor: NotesTextView?
    var pageUndoManager: UndoManager?
    override var undoManager: UndoManager? { pageUndoManager ?? super.undoManager }
    var onTabletProximity: ((NSEvent) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { Self.activeEditor = self }
        return accepted
    }

    override func tabletProximity(with event: NSEvent) {
        onTabletProximity?(event)
    }
}

#elseif os(iOS)
import UIKit

struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    var theme: PageTheme = .light
    var onChange: ((String, Data?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let editor = UITextView()
        editor.delegate = context.coordinator
        editor.isEditable = context.environment.isEnabled
        editor.allowsEditingTextAttributes = true
        editor.alwaysBounceVertical = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.textContainerInset = UIEdgeInsets(top: 24, left: 24, bottom: 32, right: 24)
        editor.backgroundColor = .systemBackground
        editor.accessibilityLabel = "Sheet text"
        context.coordinator.load(text: text, rtf: rtfData, into: editor)
        return editor
    }

    func updateUIView(_ editor: UITextView, context: Context) {
        context.coordinator.parent = self
        editor.isEditable = context.environment.isEnabled
        if context.coordinator.lastText != text || context.coordinator.lastRTF != rtfData || context.coordinator.lastTheme != theme {
            context.coordinator.load(text: text, rtf: rtfData, into: editor)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        var lastText: String?
        var lastRTF: Data?
        var lastTheme: PageTheme?
        private var isLoading = false
        private weak var editor: UITextView?
        private var undoObservers: [NSObjectProtocol] = []

        init(_ parent: RichTextEditor) {
            self.parent = parent
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let editor = self.editor,
                              let manager = notification.object as? UndoManager,
                              manager === editor.undoManager else { return }
                        self.textViewDidChange(editor)
                    }
                })
            }
        }

        deinit {
            for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        }

        func load(text: String, rtf: Data?, into editor: UITextView) {
            self.editor = editor
            isLoading = true
            defer { isLoading = false }
            let selected = editor.selectedRange
            let canonical: NSAttributedString
            if let rtf,
               let richText = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               richText.string == text {
                canonical = richText
            } else {
                canonical = NSAttributedString(string: text, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)
                ])
            }
            editor.overrideUserInterfaceStyle = parent.theme == .dark ? .dark : .light
            editor.attributedText = ThemeTextAttributes.display(canonical, theme: parent.theme)
            editor.selectedRange = ThemeTextAttributes.clipped(selected, length: canonical.length)
            editor.typingAttributes[.foregroundColor] = ThemeTextAttributes.color(parent.theme.resolvedInkHex(PageTheme.light.textHex))
            editor.typingAttributes[ThemeTextAttributes.canonicalColorKey] = ThemeTextAttributes.color(PageTheme.light.textHex)
            lastText = text
            lastRTF = rtf
            lastTheme = parent.theme
            RuledTextLayout.refresh(editor)
        }

        func textViewDidChange(_ editor: UITextView) {
            guard !isLoading else { return }
            let text = editor.text ?? ""
            let canonical = ThemeTextAttributes.canonical(editor.attributedText, theme: parent.theme)
            let rtf = try? canonical.data(
                from: NSRange(location: 0, length: (text as NSString).length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            guard text != lastText || rtf != lastRTF else { return }
            let display = ThemeTextAttributes.display(canonical, theme: parent.theme)
            if !editor.attributedText.isEqual(to: display) {
                isLoading = true
                let selected = editor.selectedRange
                let undo = editor.undoManager
                let registering = undo?.isUndoRegistrationEnabled == true
                if registering { undo?.disableUndoRegistration() }
                ThemeTextAttributes.applyDisplayAttributes(display, to: editor.textStorage)
                editor.selectedRange = ThemeTextAttributes.clipped(selected, length: display.length)
                if registering { undo?.enableUndoRegistration() }
                isLoading = false
            }
            lastText = text
            lastRTF = rtf
            if let onChange = parent.onChange {
                onChange(text, rtf)
            } else {
                parent.text = text
                parent.rtfData = rtf
            }
        }
    }
}
#endif

#if os(macOS) || os(iOS)
#if os(macOS)
typealias NoteTextColor = NSColor
#else
typealias NoteTextColor = UIColor
#endif

/// Display colors carry their original foreground as transient metadata. Only
/// canonical colors enter RTF, so switching appearance never rewrites the note.
@MainActor
enum ThemeTextAttributes {
    static let canonicalColorKey = NSAttributedString.Key("io.inotes.canonicalForeground")

    /// Color projection must not replace characters: native typing undo tracks
    /// those edits, even when a replacement string happens to be identical.
    static func applyDisplayAttributes(_ display: NSAttributedString, to storage: NSMutableAttributedString) {
        guard display.string == storage.string else { return }
        storage.beginEditing()
        display.enumerateAttributes(in: NSRange(location: 0, length: display.length)) { attributes, range, _ in
            if let color = attributes[.foregroundColor] { storage.addAttribute(.foregroundColor, value: color, range: range) }
            if let canonical = attributes[canonicalColorKey] { storage.addAttribute(canonicalColorKey, value: canonical, range: range) }
        }
        storage.endEditing()
    }

    static func clipped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    static func color(_ hex: String) -> NoteTextColor {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 255) / 255
        let green = CGFloat((value >> 8) & 255) / 255
        let blue = CGFloat(value & 255) / 255
        #if os(macOS)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    static func hex(_ source: NoteTextColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        #if os(macOS)
        var resolved: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = source.usingColorSpace(.sRGB)
        }
        guard let resolved else { return PageTheme.light.textHex }
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        let resolved = source.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return PageTheme.light.textHex }
        #endif
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    static func display(_ source: NSAttributedString, theme: PageTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var original = attributes[canonicalColorKey] as? NoteTextColor
                ?? attributes[.foregroundColor] as? NoteTextColor
                ?? color(PageTheme.light.textHex)
            let originalHex = hex(original)
            // Older dark-editor archives could contain white default text.
            if ["#FFFFFF", "#FEFEFE", "#FDFDFD"].contains(originalHex) { original = color(PageTheme.light.textHex) }
            result.addAttribute(canonicalColorKey, value: original, range: range)
            result.addAttribute(.foregroundColor, value: color(theme.resolvedInkHex(hex(original))), range: range)
        }
        return result
    }

    static func canonical(_ source: NSAttributedString, theme: PageTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let displayed = attributes[.foregroundColor] as? NoteTextColor ?? color(theme.textHex)
            let original = attributes[canonicalColorKey] as? NoteTextColor
            let canonical: NoteTextColor
            if let original, hex(displayed) == theme.resolvedInkHex(hex(original)).uppercased() {
                canonical = original
            } else {
                canonical = color(theme == .dark ? theme.canonicalInkHex(hex(displayed)) : hex(displayed))
            }
            result.addAttribute(.foregroundColor, value: canonical, range: range)
            result.removeAttribute(canonicalColorKey, range: range)
        }
        return result
    }
}
#endif
