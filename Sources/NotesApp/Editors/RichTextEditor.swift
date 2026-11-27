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
        editor.setAccessibilityLabel("Page text")
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
            editor.pageTextFormatting?.recordSize(Int(font.pointSize))
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
                        // The page manager also undoes objects and ink. Those
                        // actions must not serialize unchanged native text and
                        // materialize RTF for a legacy plain-text snapshot.
                        guard !self.matchesLastLoadedCanonicalText(editor) else { return }
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
               let richText = ThemeTextAttributes.readRTF(rtf, text: text) {
                canonical = richText
            } else {
                canonical = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)
                ])
            }
            editor.appearance = NSAppearance(named: parent.theme.isDark ? .darkAqua : .aqua)
            editor.backgroundColor = ThemeTextAttributes.color(parent.theme.paperHex)
            editor.textStorage?.setAttributedString(ThemeTextAttributes.display(canonical, theme: parent.theme))
            editor.setSelectedRange(ThemeTextAttributes.clipped(selected, length: (text as NSString).length))
            editor.typingAttributes[.foregroundColor] = ThemeTextAttributes.color(parent.theme.resolvedInkHex(PageTheme.light.textHex))
            editor.typingAttributes[ThemeTextAttributes.canonicalColorKey] = ThemeTextAttributes.color(PageTheme.light.textHex)
            (editor as? PageNativeTextView)?.formattingTheme = parent.theme
            lastText = text
            lastRTF = rtf
            lastTheme = parent.theme
            RuledTextLayout.refresh(editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NotesTextView)?.pageTextFormatting?.scheduleRefresh()
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let editor = notification.object as? NSTextView else { return }
            persist(editor)
        }

        private func matchesLastLoadedCanonicalText(_ editor: NSTextView) -> Bool {
            guard let lastText, editor.string == lastText else { return false }
            let expected: NSAttributedString
            if let lastRTF,
               let rich = ThemeTextAttributes.readRTF(lastRTF, text: lastText) {
                expected = rich
            } else {
                expected = NSAttributedString(string: lastText, attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)
                ])
            }
            // Native text storage fixes fallback fonts (including Unicode and
            // emoji) and paragraph attributes during layout. Apply those same
            // fixes to the expected value; real font/paragraph differences in
            // an undo must still differ after this normalization.
            let expectedStorage = NSTextStorage(attributedString:
                ThemeTextAttributes.display(expected, theme: parent.theme))
            expectedStorage.fixAttributes(in: NSRange(location: 0, length: expectedStorage.length))
            func comparisonValue(_ source: NSAttributedString) -> NSAttributedString {
                let value = NSMutableAttributedString(attributedString:
                    ThemeTextAttributes.canonical(source, theme: parent.theme))
                // Layout records a font-substitution provenance attribute for
                // some Unicode runs. It is not a user formatting change; retain
                // the actual NSFont and every other attribute in the comparison.
                value.removeAttribute(NSAttributedString.Key("NSOriginalFont"),
                                      range: NSRange(location: 0, length: value.length))
                return value
            }
            return comparisonValue(editor.attributedString()).isEqual(to: comparisonValue(expectedStorage))
        }

        private func persist(_ editor: NSTextView) {
            guard !isLoading else { return }
            let text = editor.string
            let canonical = ThemeTextAttributes.canonical(editor.attributedString(), theme: parent.theme)
            let rtf = ThemeTextAttributes.rtf(canonical)
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
    weak var pageTextFormatting: PageTextFormatting?
    var formattingTheme: PageTheme = .light

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if string is String, !hasMarkedText() { pageTextFormatting?.prepareTyping(in: self) }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { pageTextFormatting?.prepareTyping(in: self) }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    // Late native cursor updates must follow the tool that owns the page.
    var pageCursorProvider: (() -> NSCursor?)?
    var onPageSelectAll: (() -> Bool)?
    var canSelectAllPage: (() -> Bool)?
    var allowsPageTextUndo: (() -> Bool)?
    var onPageUndoComplete: (() -> Void)?

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
    var pageUndoManager: UndoManager? {
        didSet {
            guard pageUndoManager !== oldValue else { return }
            if let state = undoInteractionState {
                undoInteractionState = nil
                isEditable = state.editable
                isSelectable = state.selectable
            }
            for observer in pageUndoObservers { NotificationCenter.default.removeObserver(observer) }
            pageUndoObservers = []
            guard let pageUndoManager else { return }
            for name in [Notification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
                pageUndoObservers.append(NotificationCenter.default.addObserver(forName: name, object: pageUndoManager, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isEditable, self.allowsPageTextUndo?() == true else { return }
                        self.undoInteractionState = (self.isEditable, self.isSelectable)
                        // AppKit's native text undo refuses edits to a read-only
                        // text view. Allow only this synchronous history action.
                        self.isEditable = true
                    }
                })
            }
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                pageUndoObservers.append(NotificationCenter.default.addObserver(forName: name, object: pageUndoManager, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let state = self.undoInteractionState else { return }
                        self.undoInteractionState = nil
                        self.isEditable = state.editable
                        self.isSelectable = state.selectable
                        self.onPageUndoComplete?()
                        self.window?.invalidateCursorRects(for: self)
                        if let window = self.window, window.isKeyWindow, !self.isHiddenOrHasHiddenAncestor,
                           self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                            self.pageCursorProvider?()?.set()
                        }
                    }
                })
            }
        }
    }
    private var pageUndoObservers: [NSObjectProtocol] = []
    private var undoInteractionState: (editable: Bool, selectable: Bool)?
    deinit { for observer in pageUndoObservers { NotificationCenter.default.removeObserver(observer) } }
    override var undoManager: UndoManager? { pageUndoManager ?? super.undoManager }
    var onPagePaste: (() -> Bool)?
    var canPastePage: (() -> Bool)?
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)), canPastePage?() == true { return true }
        if menuItem.action == #selector(selectAll(_:)), canSelectAllPage?() == true { return true }
        return super.validateMenuItem(menuItem)
    }
    override func paste(_ sender: Any?) {
        if onPagePaste?() == true { return }
        super.paste(sender)
    }
    override func selectAll(_ sender: Any?) {
        if onPageSelectAll?() == true { return }
        super.selectAll(sender)
    }
    var onTabletProximity: ((NSEvent) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            Self.activeEditor = self
            pageTextFormatting?.scheduleRefresh()
        }
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
        editor.accessibilityLabel = "Page text"
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
               let richText = ThemeTextAttributes.readRTF(rtf, text: text) {
                canonical = richText
            } else {
                canonical = NSAttributedString(string: text, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)
                ])
            }
            editor.overrideUserInterfaceStyle = parent.theme.isDark ? .dark : .light
            editor.attributedText = ThemeTextAttributes.display(canonical, theme: parent.theme)
            editor.selectedRange = ThemeTextAttributes.clipped(selected, length: canonical.length)
            editor.typingAttributes[.foregroundColor] = ThemeTextAttributes.color(parent.theme.resolvedInkHex(PageTheme.light.textHex))
            editor.typingAttributes[ThemeTextAttributes.canonicalColorKey] = ThemeTextAttributes.color(PageTheme.light.textHex)
            (editor as? PageNativeTextView)?.formattingTheme = parent.theme
            lastText = text
            lastRTF = rtf
            lastTheme = parent.theme
            RuledTextLayout.refresh(editor)
        }

        func textViewDidChangeSelection(_ editor: UITextView) {
            (editor as? IOSPageTextView)?.pageTextFormatting?.scheduleRefresh()
        }

        func textViewDidChange(_ editor: UITextView) {
            guard !isLoading else { return }
            let text = editor.text ?? ""
            let canonical = ThemeTextAttributes.canonical(editor.attributedText, theme: parent.theme)
            let rtf = ThemeTextAttributes.rtf(canonical)
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
typealias PageNativeTextView = NotesTextView
typealias NoteTextFont = NSFont
#else
typealias NoteTextColor = UIColor
typealias PageNativeTextView = IOSPageTextView
typealias NoteTextFont = UIFont
#endif

@MainActor
final class PageTextFormatting: ObservableObject {
    static let sizes = [10, 12, 14, 16, 18, 20, 24, 26, 32, 36, 48, 64, 72]
    @Published private(set) var pointSize = 16
    @Published private(set) var selectionPointSize: CGFloat? = 16
    private var refreshScheduled = false
    private var chosenSize: Int?
    private var colorHex: String?
    var target: (() -> PageNativeTextView?)?
    var validate: ((PageNativeTextView, String, Data) -> Bool)?
    #if os(iOS)
    weak var lastActiveEditor: IOSPageTextView?
    #endif

    init(color: String? = UserDefaults.standard.string(forKey: "inkColor")) {
        colorHex = color.flatMap(Self.validHex)
    }

    private static func validHex(_ value: String) -> String? {
        PageTheme.isRGBHex(value) ? value.uppercased() : nil
    }

    func chooseColor(_ hex: String, applyToTextSelection: Bool = true) {
        guard let hex = Self.validHex(hex) else { return }
        colorHex = hex
        if applyToTextSelection { apply(.color(hex)) }
    }

    func chooseSize(_ points: Int) {
        guard Self.sizes.contains(points) else { return }
        recordSize(points)
        apply(.size(points))
    }

    fileprivate func recordSize(_ points: Int) {
        chosenSize = points
        if pointSize != points { pointSize = points }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let value = self.target?().flatMap { self.displayedSize(in: $0) }
            if self.selectionPointSize != value { self.selectionPointSize = value }
        }
    }

    private func displayedSize(in editor: PageNativeTextView) -> CGFloat? {
        #if os(macOS)
        guard let storage = editor.textStorage else { return nil }
        let ranges = editor.selectedRanges.map(\.rangeValue)
        #else
        let storage = editor.textStorage
        let ranges = [editor.selectedRange]
        #endif
        let selected = ranges.filter { $0.length > 0 && NSMaxRange($0) <= storage.length }
        if selected.isEmpty {
            if let chosenSize { return CGFloat(chosenSize) }
            return (editor.typingAttributes[.font] as? NoteTextFont)?.pointSize ?? 16
        }
        var size: CGFloat?
        for range in selected {
            var mixed = false
            storage.enumerateAttribute(.font, in: range) { value, _, stop in
                let points = (value as? NoteTextFont)?.pointSize ?? 16
                if let size, size != points { mixed = true; stop.pointee = true }
                else { size = points }
            }
            if mixed { return nil }
        }
        return size
    }

    @MainActor private enum Attribute {
        case color(String), size(Int)

        func values(for run: [NSAttributedString.Key: Any], theme: PageTheme) -> [NSAttributedString.Key: Any] {
            switch self {
            case let .color(hex):
                return [.foregroundColor: ThemeTextAttributes.color(theme.resolvedInkHex(hex)),
                        ThemeTextAttributes.canonicalColorKey: ThemeTextAttributes.color(hex)]
            case let .size(points):
                let font = run[.font] as? NoteTextFont ?? .systemFont(ofSize: 16)
                return [.font: ThemeTextAttributes.resizedFont(font, to: CGFloat(points))]
            }
        }
    }

    func prepareTyping(in editor: PageNativeTextView) {
        guard colorHex != nil || chosenSize != nil else { return }
        var attributes = editor.typingAttributes
        if let colorHex { attributes.merge(Attribute.color(colorHex).values(for: attributes, theme: editor.formattingTheme)) { _, new in new } }
        if let chosenSize { attributes.merge(Attribute.size(chosenSize).values(for: attributes, theme: editor.formattingTheme)) { _, new in new } }
        if !(attributes as NSDictionary).isEqual(to: editor.typingAttributes) { editor.typingAttributes = attributes }
    }

    private func apply(_ attribute: Attribute) {
        guard let editor = target?(), editor.isEditable else { return }
        #if os(macOS)
        guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        let ranges = editor.selectedRanges.map(\.rangeValue)
        #else
        guard editor.markedTextRange == nil else { return }
        let storage = editor.textStorage
        let ranges = [editor.selectedRange]
        #endif
        var replacements: [(NSRange, NSAttributedString)] = []
        for range in ranges where range.length > 0 && NSMaxRange(range) <= storage.length {
            let original = storage.attributedSubstring(from: range)
            let styled = NSMutableAttributedString(attributedString: original)
            original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { run, part, _ in
                styled.addAttributes(attribute.values(for: run, theme: editor.formattingTheme), range: part)
            }
            if !original.isEqual(to: styled) {
                replacements.append((range, ThemeTextAttributes.canonical(styled, theme: editor.formattingTheme)))
            }
        }
        if !replacements.isEmpty {
            Self.restore(replacements, in: editor)
        }
        if ranges.allSatisfy({ $0.length == 0 }) { prepareTyping(in: editor) }
        scheduleRefresh()
    }

    // Native text input keeps its own undo. One formatting command changes
    // only attributes, so undo and redo never replace characters or the caret.
    private static func restore(_ replacements: [(NSRange, NSAttributedString)], in editor: PageNativeTextView) {
        #if os(macOS)
        guard let storage = editor.textStorage else { return }
        #else
        let storage = editor.textStorage
        #endif
        var inverse: [(NSRange, NSAttributedString)] = []
        for (range, replacement) in replacements {
            guard NSMaxRange(range) <= storage.length else { return }
            let previous = storage.attributedSubstring(from: range)
            guard previous.string == replacement.string else { return }
            inverse.append((range, ThemeTextAttributes.canonical(previous, theme: editor.formattingTheme)))
        }
        #if os(macOS)
        let pageHistory = editor.undoManager as? PageUndoManager
        if pageHistory?.isRejectingRemainingActions == true {
            pageHistory?.retainRejectedAction(withTarget: editor, actionName: "Format Text") { restore(replacements, in: $0) }
            return
        }
        #endif
        if let validate = editor.pageTextFormatting?.validate {
            let candidate = NSMutableAttributedString(attributedString: ThemeTextAttributes.canonical(storage, theme: editor.formattingTheme))
            for (range, replacement) in replacements { candidate.replaceCharacters(in: range, with: replacement) }
            guard let data = ThemeTextAttributes.rtf(candidate), validate(editor, candidate.string, data) else {
                #if os(macOS)
                pageHistory?.retainRejectedAction(withTarget: editor, actionName: "Format Text") { restore(replacements, in: $0) }
                #endif
                return
            }
        }
        #if os(macOS)
        if editor.undoManager?.isUndoing != true && editor.undoManager?.isRedoing != true { editor.breakUndoCoalescing() }
        #endif
        editor.undoManager?.registerUndo(withTarget: editor) { target in restore(inverse, in: target) }
        editor.undoManager?.setActionName("Format Text")
        storage.beginEditing()
        for (range, replacement) in replacements {
            let display = ThemeTextAttributes.display(replacement, theme: editor.formattingTheme)
            display.enumerateAttributes(in: NSRange(location: 0, length: display.length)) { attributes, part, _ in
                storage.setAttributes(attributes, range: NSRange(location: range.location + part.location, length: part.length))
            }
        }
        storage.endEditing()
        #if os(macOS)
        editor.didChangeText()
        #else
        editor.delegate?.textViewDidChange?(editor)
        #endif
        editor.pageTextFormatting?.scheduleRefresh()
        RuledTextLayout.refresh(editor)
    }
}

extension UnifiedPageEditor {
    func observingTextFormatting(_ formatting: PageTextFormatting) -> Self {
        var editor = self
        editor.textFormatting = formatting
        return editor
    }
}

/// Display colors carry their original foreground as transient metadata. Only
/// canonical colors enter RTF, so switching appearance never rewrites the note.
@MainActor
enum ThemeTextAttributes {
    static let canonicalColorKey = NSAttributedString.Key("io.inotes.canonicalForeground")

    static func resizedFont(_ font: NoteTextFont, to pointSize: CGFloat) -> NoteTextFont {
        #if os(macOS)
        return NSFontManager.shared.convert(font, toSize: pointSize)
        #else
        return font.withSize(pointSize)
        #endif
    }

    // Earlier dark editors saved white as their automatic text color. Mark RTF
    // with intentional white using an ignorable destination understood by RTF
    // readers. Other colors keep their original native RTF representation.
    private static let rtfHeader = Data(#"{\rtf1"#.utf8)
    private static let legacyWhite: Set<String> = ["#FFFFFF", "#FEFEFE", "#FDFDFD"]

    static func readRTF(_ data: Data, text: String) -> NSAttributedString? {
        guard let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                  documentAttributes: nil), value.string == text else { return nil }
        if data.starts(with: PageContent.explicitWhiteRTFPrefix) { return value }
        var migrated: NSMutableAttributedString?
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { foreground, range, _ in
            guard let foreground = foreground as? NoteTextColor, legacyWhite.contains(hex(foreground)) else { return }
            if migrated == nil { migrated = NSMutableAttributedString(attributedString: value) }
            migrated?.addAttribute(.foregroundColor, value: color(PageTheme.light.textHex), range: range)
        }
        return migrated ?? value
    }

    static func rtf(_ canonical: NSAttributedString) -> Data? {
        let range = NSRange(location: 0, length: canonical.length)
        guard var data = try? canonical.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return nil }
        var explicitWhite = false
        canonical.enumerateAttribute(.foregroundColor, in: range) { foreground, _, stop in
            if let foreground = foreground as? NoteTextColor, legacyWhite.contains(hex(foreground)) {
                explicitWhite = true
                stop.pointee = true
            }
        }
        if explicitWhite, data.starts(with: rtfHeader) {
            data.replaceSubrange(data.startIndex..<rtfHeader.count, with: PageContent.explicitWhiteRTFPrefix)
        }
        return data
    }

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
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = resolved.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil),
              UIColor(cgColor: converted).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return PageTheme.light.textHex }
        #endif
        // Native pickers can provide extended or Display P3 colors. Keep the
        // canonical archive/picker value bounded to opaque six-digit sRGB.
        func byte(_ value: CGFloat) -> Int {
            value.isFinite ? Int((min(1, max(0, value)) * 255).rounded()) : 0
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    static func display(_ source: NSAttributedString, theme: PageTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let original = attributes[canonicalColorKey] as? NoteTextColor
                ?? attributes[.foregroundColor] as? NoteTextColor
                ?? color(PageTheme.light.textHex)
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
                canonical = color(theme.isDark ? theme.canonicalInkHex(hex(displayed)) : hex(displayed))
            }
            result.addAttribute(.foregroundColor, value: canonical, range: range)
            result.removeAttribute(canonicalColorKey, range: range)
        }
        return result
    }
}
#endif
