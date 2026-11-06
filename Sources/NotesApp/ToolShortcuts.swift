import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ToolShortcut: Identifiable {
    let tool: InkTool
    let title: String
    let key: String
    var shifted = false
    var id: String { tool.rawValue }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key)) }
    var modifiers: EventModifiers { shifted ? [.command, .option, .shift] : [.command, .option] }
    var hint: String { (shifted ? "⇧" : "") + key.uppercased() }
}

extension Notification.Name {
    static let noteToolShortcut = Notification.Name("iNotes.noteToolShortcut")
    static let noteToolFocus = Notification.Name("iNotes.noteToolFocus")
}

@MainActor
enum ToolShortcuts {
    static var all: [ToolShortcut] {
        var choices: [ToolShortcut] = [
        ToolShortcut(tool: .select, title: "Select", key: "v"),
        ToolShortcut(tool: .lasso, title: "Lasso", key: "l"),
        ToolShortcut(tool: .pen, title: "Pen", key: "p"),
        ToolShortcut(tool: .pencil, title: "Pencil", key: "p", shifted: true),
        ToolShortcut(tool: .marker, title: "Brush / Marker", key: "b"),
        ToolShortcut(tool: .highlighter, title: "Highlighter", key: "h"),
        ToolShortcut(tool: .eraser, title: "Eraser", key: "e"),
        ToolShortcut(tool: .text, title: "Text", key: "t"),
        ToolShortcut(tool: .line, title: "Straight Line", key: "l", shifted: true)
        ]
        #if os(macOS)
        choices.append(ToolShortcut(tool: .diagram, title: "Shapes and Tables", key: "s"))
        #endif
        return choices
    }

    static func match(key: String, shifted: Bool) -> InkTool? {
        all.first { $0.key == key.lowercased() && $0.shifted == shifted }?.tool
    }

    static func help(for tool: InkTool) -> String {
        guard let shortcut = all.first(where: { $0.tool == tool }) else { return "" }
        return "\(shortcut.hint) when the page has focus; ⌘⌥\(shortcut.hint) while editing text"
    }

    static func activate(_ tool: InkTool) {
        #if os(macOS)
        guard NSApp.keyWindow != nil, NSApp.keyWindow?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        NotificationCenter.default.post(name: .noteToolShortcut, object: tool)
    }

    #if os(iOS)
    static func keyCommands(includePlain: Bool, action: Selector) -> [UIKeyCommand] {
        all.flatMap { shortcut -> [UIKeyCommand] in
            let shift: UIKeyModifierFlags = shortcut.shifted ? [.shift] : []
            let modifiedFlags: UIKeyModifierFlags = [.command, .alternate]
            let modified = UIKeyCommand(input: shortcut.key, modifierFlags: modifiedFlags.union(shift), action: action)
            modified.discoverabilityTitle = shortcut.title
            var result = [modified]
            if includePlain {
                let plain = UIKeyCommand(input: shortcut.key, modifierFlags: shift, action: action)
                plain.discoverabilityTitle = shortcut.title
                result.append(plain)
            }
            return result
        }
    }
    static func tool(for command: UIKeyCommand) -> InkTool? {
        guard let input = command.input else { return nil }
        return match(key: input, shifted: command.modifierFlags.contains(.shift))
    }
    #endif
}

#if os(macOS)
/// App-local shortcuts never consume characters destined for native text input.
@MainActor
final class ToolShortcutMonitor: ObservableObject {
    private var monitor: Any?
    static func eligibleTool(for event: NSEvent, in window: NSWindow?, activeTool: InkTool? = nil) -> InkTool? {
        guard event.type == .keyDown, let window,
              activeTool != .text,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextInputClient),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers else { return nil }
        return ToolShortcuts.match(key: key, shifted: event.modifierFlags.contains(.shift))
    }
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard RunLoop.current.currentMode != .eventTracking,
                      let tool = Self.eligibleTool(for: event, in: NSApp.keyWindow,
                          activeTool: InkTool(rawValue: UserDefaults.standard.string(forKey: "inkTool") ?? "pen")) else { return event }
                ToolShortcuts.activate(tool)
                return nil
            }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

@MainActor
enum ToolShortcutDiagnostics {
    static func run() throws -> String {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "iNotes.ToolShortcutDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ink = InkDocumentView(frame: window.contentView!.bounds)
        let editor = RichTextEditor.makeNativeTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        window.contentView?.addSubview(ink)
        window.contentView?.addSubview(editor)
        func event(_ key: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: key,
                            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 35)!
        }
        window.makeFirstResponder(ink)
        try require(eligible(event("p")) == .pen, "P selects Pen when the canvas has focus")
        try require(eligible(event("P", flags: .shift)) == .pencil, "Shift-P selects Pencil")
        try require(eligible(event("l")) == .lasso && eligible(event("L", flags: .shift)) == .line, "Lasso and straight-line shortcuts remain distinct")
        try require(eligible(event("h")) == .highlighter && eligible(event("v")) == .select, "Highlighter and Select have canvas shortcuts")
        try require(eligible(event("s")) == .diagram, "S selects the native shapes tool from the page")
        try require(eligible(event("q")) == nil && eligible(event("p", flags: .command)) == nil, "Unknown keys and standard command chords pass through")
        try require(ToolShortcutMonitor.eligibleTool(for: event("p"), in: window, activeTool: .text) == nil,
                    "Text mode protects typing even if a previous canvas responder still has focus")
        window.makeFirstResponder(editor)
        try require(eligible(event("p")) == nil && eligible(event("h")) == nil && eligible(event("s")) == nil, "Typing letters never selects drawing tools")
        editor.insertText("p + h = \\phi", replacementRange: NSRange(location: 0, length: 0))
        try require(editor.string == "p + h = \\phi", "Text and LaTeX-like input remain intact")
        return "Tool shortcut checks passed: \(checks), including canvas focus and native text-input protection"

        func eligible(_ event: NSEvent) -> InkTool? { ToolShortcutMonitor.eligibleTool(for: event, in: window) }
    }
}
#endif
