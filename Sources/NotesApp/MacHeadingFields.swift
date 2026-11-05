#if os(macOS)
import AppKit
import SwiftUI

/// Measure a fresh plain field only after assigning its intended native font.
/// Both heading fields have exhibited another font role's allocation despite
/// retaining their correct font and native cell metrics.
@MainActor
struct MacTextFieldMetrics {
    let font: NSFont
    let height: CGFloat

    init(font: NSFont) {
        let field = NSTextField(string: "")
        field.font = font
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        let measured = field.cell?.cellSize.height ?? field.intrinsicContentSize.height
        let nativeLineHeight = font.ascender - font.descender + font.leading
        self.font = font
        height = ceil(measured.isFinite && measured > 0 ? measured : nativeLineHeight)
    }
}

@MainActor
enum MacTagFieldMetrics {
    private static var cached: MacTextFieldMetrics?

    static var current: MacTextFieldMetrics {
        let font = NSFont.preferredFont(forTextStyle: .caption1, options: [:])
        if let cached, cached.font == font { return cached }
        let value = MacTextFieldMetrics(font: font)
        // One entry, replaced if the preferred system/accessibility font changes.
        cached = value
        return value
    }
}

@MainActor
enum MacSheetTitleFieldMetrics {
    private static var cached: MacTextFieldMetrics?

    static var current: MacTextFieldMetrics {
        let system = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let descriptor = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 28) ?? system
        if let cached, cached.font == font { return cached }
        let value = MacTextFieldMetrics(font: font)
        // A separate single entry keeps the two heading roles bounded.
        cached = value
        return value
    }
}

/// The role stays fixed for a native control's lifetime. SwiftUI owns the
/// container width; this view owns its NSTextField and exact native height.
enum MacHeadingFieldRole: Hashable {
    case title, tags

    @MainActor var metrics: MacTextFieldMetrics {
        self == .title ? MacSheetTitleFieldMetrics.current : MacTagFieldMetrics.current
    }
    var placeholder: String { self == .title ? "Page title" : "Add tags, separated by commas" }
}

/// A nonpublished copy lets disappearance commit the latest native draft even
/// when SwiftUI has not yet rebuilt a closure after the last editing event.
@MainActor
final class MacHeadingFieldDraft {
    var text = ""
}

@MainActor
final class MacHeadingNativeTextField: NSTextField {
    let role: MacHeadingFieldRole
    var nativeHeight: CGFloat

    init(role: MacHeadingFieldRole) {
        self.role = role
        let metrics = role.metrics
        nativeHeight = metrics.height
        super.init(frame: .zero)
        font = metrics.font
        isBezeled = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        textColor = role == .title ? .labelColor : .secondaryLabelColor
        focusRingType = .none
        placeholderString = role.placeholder
        maximumNumberOfLines = 1
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        allowsEditingTextAttributes = false
        setAccessibilityLabel(role == .title ? "Page title" : "Tags")
        setAccessibilityHelp(role == .title
            ? "Optional. Leave blank to identify the sheet by its number."
            : "Separate tags with commas.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: nativeHeight) }
}

@MainActor
final class MacHeadingFieldView: NSView {
    let role: MacHeadingFieldRole
    let field: MacHeadingNativeTextField
    var nativeHeight: CGFloat { field.nativeHeight }
    override var isFlipped: Bool { true }

    init(role: MacHeadingFieldRole) {
        self.role = role
        field = MacHeadingNativeTextField(role: role)
        super.init(frame: .zero)
        addSubview(field)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        layoutField()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: nativeHeight) }
    override var fittingSize: NSSize { NSSize(width: max(0, bounds.width), height: nativeHeight) }

    override func layout() {
        super.layout()
        layoutField()
    }

    func refreshMetrics() {
        let metrics = role.metrics
        guard field.font != metrics.font || field.nativeHeight != metrics.height else { return }
        field.font = metrics.font
        field.nativeHeight = metrics.height
        field.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func layoutField() {
        // Plain native fields inset their glyphs by two points. Retain the
        // previous plain TextField alignment without clipping a taller control.
        let frame = NSRect(x: -2, y: 0, width: max(0, bounds.width + 4), height: nativeHeight)
        if field.frame != frame { field.frame = frame }
    }
}

@MainActor
struct MacHeadingField: NSViewRepresentable {
    @Binding var text: String
    let role: MacHeadingFieldRole
    var isReadOnly = false
    var nativeDraft: MacHeadingFieldDraft? = nil
    var onCommit: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MacHeadingFieldView {
        let view = MacHeadingFieldView(role: role)
        view.field.stringValue = text
        nativeDraft?.text = text
        context.coordinator.attach(to: view.field)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacHeadingFieldView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? nsView.bounds.width
        let fallbackWidth = nsView.bounds.width.isFinite ? max(0, nsView.bounds.width) : 0
        return CGSize(width: proposedWidth.isFinite ? max(0, proposedWidth) : fallbackWidth,
                      height: nsView.nativeHeight)
    }

    func updateNSView(_ view: MacHeadingFieldView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyingValue = true
        defer { coordinator.applyingValue = false }
        view.refreshMetrics()
        let field = view.field
        let enabled = !isReadOnly && context.environment.isEnabled
        if field.isEnabled != enabled { field.isEnabled = enabled }
        if field.isEditable != enabled { field.isEditable = enabled }
        if field.isSelectable != enabled { field.isSelectable = enabled }
        let appearance: NSAppearance.Name = context.environment.colorScheme == .dark ? .darkAqua : .aqua
        if field.appearance?.name != appearance { field.appearance = NSAppearance(named: appearance) }
        let editor = field.currentEditor() as? NSTextView
        // A model or theme refresh must not replace an active IME marked range.
        guard editor?.hasMarkedText() != true else { return }
        nativeDraft?.text = text
        guard field.stringValue != text || (editor != nil && editor?.string != text) else { return }
        let selection = editor?.selectedRange()
        field.stringValue = text
        if let editor, editor.string != text { editor.string = text }
        if let editor, let selection {
            let length = (text as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
    }

    static func dismantleNSView(_ view: MacHeadingFieldView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacHeadingField
        var applyingValue = false
        private weak var field: MacHeadingNativeTextField?
        private var undoObservers: [NSObjectProtocol] = []

        init(_ parent: MacHeadingField) { self.parent = parent }

        func attach(to field: MacHeadingNativeTextField) {
            detach()
            self.field = field
            field.delegate = self
            field.target = self
            field.action = #selector(submit(_:))
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let field = self.field,
                              let editor = field.currentEditor() as? NSTextView,
                              field.window?.firstResponder === editor,
                              let manager = notification.object as? UndoManager,
                              manager === editor.undoManager else { return }
                        self.publish(editor.string, editor: editor)
                    }
                })
            }
        }

        func detach() {
            undoObservers.forEach(NotificationCenter.default.removeObserver)
            undoObservers.removeAll()
            field?.delegate = nil
            field?.target = nil
            field?.action = nil
            field = nil
        }

        deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field, notification.object as AnyObject? === field else { return }
            (field.currentEditor() as? NSTextView)?.allowsUndo = true
        }

        func controlTextDidChange(_ notification: Notification) { publish(notification, commit: false) }
        func controlTextDidEndEditing(_ notification: Notification) { publish(notification, commit: true) }

        @objc private func submit(_ sender: NSTextField) {
            guard let field, sender === field else { return }
            let editor = field.currentEditor() as? NSTextView
            publish(editor?.string ?? field.stringValue, editor: editor, commit: true)
        }

        private func publish(_ notification: Notification, commit: Bool) {
            guard let field, notification.object as AnyObject? === field else { return }
            let editor = (notification.userInfo?["NSFieldEditor"] as? NSTextView)
                ?? (field.currentEditor() as? NSTextView)
            publish(editor?.string ?? field.stringValue, editor: editor, commit: commit)
        }

        private func publish(_ raw: String, editor: NSTextView?, commit: Bool = false) {
            guard !applyingValue, !parent.isReadOnly, let field, field.isEnabled,
                  field.isEditable, editor?.hasMarkedText() != true else { return }
            parent.nativeDraft?.text = raw
            if parent.text != raw { parent.text = raw }
            if commit { parent.onCommit?(raw) }
        }
    }
}
#endif
