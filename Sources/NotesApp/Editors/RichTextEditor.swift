import SwiftUI

enum RichTextCommand: String, CaseIterable {
    case bold, italic, underline, heading, body, bullet, checklist
}

#if os(macOS)
import AppKit

/// An AppKit text system keeps typing, selection, spelling and undo native.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
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
        editor.usesAdaptiveColorMappingForDarkAppearance = true
        editor.setAccessibilityLabel("Sheet text")
        editor.setAccessibilityHelp("Rich text editor. Use the Format menu to style selected text.")
        return editor
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView else { return }
        editor.isEditable = context.environment.isEnabled
        if context.coordinator.lastText != text || context.coordinator.lastRTF != rtfData {
            context.coordinator.load(text: text, rtf: rtfData, into: editor)
            editor.undoManager?.removeAllActions()
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
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastText: String?
        var lastRTF: Data?
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
            if let rtf,
               let richText = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               richText.string == text {
                editor.textStorage?.setAttributedString(richText)
            } else {
                editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor
                ]))
            }
            editor.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
            lastText = text
            lastRTF = rtf
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let editor = notification.object as? NSTextView else { return }
            persist(editor)
        }

        private func persist(_ editor: NSTextView) {
            guard !isLoading else { return }
            let text = editor.string
            let rtf = try? editor.attributedString().data(
                from: NSRange(location: 0, length: (text as NSString).length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            guard text != lastText || rtf != lastRTF else { return }
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
    static weak var activeEditor: NotesTextView?
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
        if context.coordinator.lastText != text || context.coordinator.lastRTF != rtfData {
            context.coordinator.load(text: text, rtf: rtfData, into: editor)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        var lastText: String?
        var lastRTF: Data?
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
            if let rtf,
               let richText = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               richText.string == text {
                editor.attributedText = richText
            } else {
                editor.attributedText = NSAttributedString(string: text, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label
                ])
            }
            lastText = text
            lastRTF = rtf
        }

        func textViewDidChange(_ editor: UITextView) {
            guard !isLoading else { return }
            let text = editor.text ?? ""
            let rtf = try? editor.attributedText.data(
                from: NSRange(location: 0, length: (text as NSString).length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            guard text != lastText || rtf != lastRTF else { return }
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
