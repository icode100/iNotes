import SwiftUI
import Combine

enum ZoomPercentage {
    static func display(_ scale: Double, locale: Locale = .current) -> String {
        scale.formatted(.percent.locale(locale).precision(.fractionLength(0...2)))
    }

    static func limits(locale: Locale) -> String {
        let range = PageZoomSetting.manualRange
        return "(\(display(range.lowerBound, locale: locale))–\(display(range.upperBound, locale: locale)))"
    }

    static func scale(from input: String, locale: Locale = .current) -> Double? {
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{061C}\u{200E}\u{200F}"))
        var text = input.trimmingCharacters(in: padding)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        for symbol in [formatter.percentSymbol ?? "%", "%"] where !symbol.isEmpty {
            if text.hasSuffix(symbol) { text.removeLast(symbol.count); break }
            if text.hasPrefix(symbol) { text.removeFirst(symbol.count); break }
        }
        text = text.trimmingCharacters(in: padding)
        if let separator = locale.decimalSeparator, separator != "." {
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        // Percentages may use localized decimal digits, but never need grouping.
        var number = ""
        for character in text {
            if character == "." {
                number.append(".")
            } else if character.isNumber, let digit = character.wholeNumberValue, (0...9).contains(digit) {
                number.append(String(digit))
            } else { return nil }
        }
        guard let percent = Double(number), percent.isFinite else { return nil }
        let scale = percent / 100
        return PageZoomSetting.manualRange.contains(scale) ? scale : nil
    }
}

enum PageZoomDirection: Equatable {
    case zoomIn, zoomOut

    func nextScale(from scale: Double) -> Double? {
        let range = PageZoomSetting.manualRange
        guard scale.isFinite, scale > 0 else { return nil }
        switch self {
        case .zoomIn:
            guard scale < range.upperBound else { return nil }
            return min(range.upperBound, max(range.lowerBound, scale * 1.2))
        case .zoomOut:
            guard scale > range.lowerBound else { return nil }
            return max(range.lowerBound, min(range.upperBound, scale / 1.2))
        }
    }
}

struct PageZoomSlider: View {
    #if os(iOS)
    private static let buttonWidth: CGFloat = 44
    #else
    private static let buttonWidth: CGFloat = 24
    #endif
    private static let spacing: CGFloat = 2
    static let stepButtonsWidth = 2 * (buttonWidth + spacing)

    let label: LocalizedStringKey
    let id: String
    @Binding var scale: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    #if os(macOS)
    @Environment(\.workspaceDiagnosticControls) private var diagnosticControls
    #endif

    var body: some View {
        HStack(spacing: Self.spacing) {
            stepButton(.zoomOut)
            track
            stepButton(.zoomIn)
        }
    }

    private func stepButton(_ direction: PageZoomDirection) -> some View {
        let increasing = direction == .zoomIn
        let title: LocalizedStringKey = increasing ? "Zoom in" : "Zoom out"
        let identifier = id + (increasing ? "-in" : "-out")
        let enabled = direction.nextScale(from: scale) != nil
        return Button {
            if let next = direction.nextScale(from: scale) { scale = next }
        } label: {
            Image(systemName: increasing ? "plus.circle" : "minus.circle")
                .frame(width: Self.buttonWidth, height: Self.buttonWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
        #if os(macOS)
        .background {
            if let diagnosticControls {
                WorkspaceDiagnosticControlProbe(controls: diagnosticControls, identifier: identifier, enabled: enabled)
            }
        }
        #endif
    }

    private var track: some View {
        let range = PageZoomSetting.manualRange
        // A stepped native slider draws 376 tick marks beneath the track.
        // Snap only slider input so a typed fractional zoom stays exact.
        return Slider(value: Binding(get: { clamped(scale) }, set: { scale = ($0 * 100).rounded() / 100 }),
                      in: range, onEditingChanged: onEditingChanged) { Text(label) }
            .labelsHidden()
            .accessibilityIdentifier(id + "-slider")
            .accessibilityValue(ZoomPercentage.display(scale, locale: locale))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(increasing: true)
                case .decrement: adjust(increasing: false)
                @unknown default: break
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                adjust(increasing: (press.key == .rightArrow) == (layoutDirection == .leftToRight))
                return .handled
            }
            #if os(macOS)
            .background {
                if let diagnosticControls {
                    WorkspaceDiagnosticControlProbe(controls: diagnosticControls, identifier: id + "-slider")
                }
            }
            #endif
    }

    private func clamped(_ value: Double) -> Double {
        let range = PageZoomSetting.manualRange
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func adjust(increasing: Bool) {
        let percent = (clamped(scale) * 100).rounded()
        scale = clamped((percent + (increasing ? 1 : -1)) / 100)
    }
}

/// The draft stays local until Return or focus loss. Focusing a fitted scale
/// and leaving it untouched must preserve its automatic mode.
struct ZoomPercentageField: View {
    let scale: Double
    @Binding var draft: String?
    let label: String
    let id: String
    let commit: (Double) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool

    var body: some View {
        let displayed = ZoomPercentage.display(scale, locale: locale)
        let limits = ZoomPercentage.limits(locale: locale)
        VStack(spacing: 1) {
            TextField(label, text: Binding(get: {
                draft ?? displayed
            }, set: { draft = $0 == displayed ? nil : $0 }))
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 71)
                .accessibilityLabel(label)
                .accessibilityHint("Allowed range \(limits)")
                .accessibilityIdentifier(id)
                .onSubmit { focused = false }
                #if os(macOS)
                .onExitCommand { draft = nil; focused = false }
                #else
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .onKeyPress(.escape) {
                    draft = nil
                    focused = false
                    return .handled
                }
                #endif
                .onChange(of: focused) { _, active in
                    if !active { finishEditing() }
                    onFocusChange(active)
                }
            Text(verbatim: limits)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .onDisappear {
            finishEditing()
            onFocusChange(false)
        }
    }

    private func finishEditing() {
        guard let text = draft else { return }
        draft = nil
        if let value = ZoomPercentage.scale(from: text, locale: locale) { commit(value) }
    }
}

@MainActor
protocol PageZoomViewport: AnyObject {
    func applyZoom(_ setting: PageZoomSetting)
}

/// One mounted page in one window. Only the user's choice is persisted.
/// The measured scale of a fitted page belongs to this particular viewport.
@MainActor
final class PageZoomSession: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let pageID: UUID
    private(set) var setting: PageZoomSetting
    private(set) var scale: Double
    private let remember: (PageZoomSetting) -> Void
    private weak var viewport: PageZoomViewport?
    private var refreshPending = false
    #if os(macOS)
    var onScrollerClearanceChange: (() -> Void)?
    private(set) var scrollerClearance: CGFloat = 0
    private var scrollerClearanceChanged = false

    func reportScrollerClearance(_ height: CGFloat, from viewport: PageZoomViewport) {
        guard self.viewport === viewport, height != scrollerClearance else { return }
        scrollerClearance = height
        scrollerClearanceChanged = true
        refreshControls()
    }
    #endif

    init(pageID: UUID, setting: PageZoomSetting, remember: @escaping (PageZoomSetting) -> Void) {
        self.pageID = pageID
        self.setting = setting
        if case let .scale(value) = setting { scale = value } else { scale = 1 }
        self.remember = remember
    }

    func attach(_ viewport: PageZoomViewport) {
        self.viewport = viewport
        viewport.applyZoom(setting)
    }

    func detach(_ viewport: PageZoomViewport) {
        if self.viewport === viewport { self.viewport = nil }
    }

    func choose(_ choice: PageZoomSetting) {
        guard choice.isValid else { return }
        remember(choice)
        setting = choice
        if case let .scale(value) = choice { scale = value }
        viewport?.applyZoom(choice)
        refreshControls()
    }

    func report(_ choice: PageZoomSetting, scale measured: Double, from viewport: PageZoomViewport) {
        guard self.viewport === viewport, choice.isValid, measured.isFinite, measured > 0,
              choice != setting || measured != scale else { return }
        if choice != setting { remember(choice) }
        setting = choice
        scale = measured
        refreshControls()
    }

    private func refreshControls() {
        // Fit can be measured during SwiftUI's native layout. The page choice
        // above is already available if navigation happens in the same turn.
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            #if os(macOS)
            if self.scrollerClearanceChanged {
                self.scrollerClearanceChanged = false
                self.onScrollerClearanceChange?()
            }
            #endif
            self.objectWillChange.send()
        }
    }
}

struct PageZoomControls: View {
    @ObservedObject var session: PageZoomSession
    let compact: Bool
    @Binding var showsPopover: Bool
    @Binding var draggingSlider: Bool
    @Binding var editingPercentage: Bool
    @ViewState private var percentageDraft: String?
    @Environment(\.locale) private var locale
    #if os(macOS)
    @Environment(\.workspaceDiagnosticControls) private var diagnosticControls
    #endif

    private var percentage: String {
        ZoomPercentage.display(session.scale, locale: locale)
    }

    var body: some View {
        if compact {
            Button { showsPopover.toggle() } label: {
                VStack(spacing: 1) {
                    Text(percentage).monospacedDigit().font(.caption)
                    Text(verbatim: ZoomPercentage.limits(locale: locale))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page zoom")
            .accessibilityValue(percentage)
            .help("Adjust page zoom")
            .popover(isPresented: $showsPopover) {
                VStack(spacing: 6) {
                    slider
                    HStack(spacing: 8) { percentageAndFit }
                }
                .frame(width: 224)
                .padding(12)
                .presentationCompactAdaptation(.popover)
            }
        } else {
            HStack(spacing: 3) {
                slider
                percentageAndFit
            }
        }
    }

    private var slider: some View {
        PageZoomSlider(label: "Page zoom", id: "page-zoom", scale: Binding(get: { session.scale }, set: { choose(.scale($0)) }),
                       onEditingChanged: { draggingSlider = $0 })
            .onDisappear { draggingSlider = false }
    }

    @ViewBuilder private var percentageAndFit: some View {
        ZoomPercentageField(scale: session.scale, draft: $percentageDraft,
                            label: "Page zoom percentage", id: "page-zoom-percentage",
                            commit: { choose(.scale($0)) }, onFocusChange: { editingPercentage = $0 })
        fitButton(.fitPage, label: "Fit Page", icon: "arrow.up.left.and.arrow.down.right", id: "page-zoom-fit-page")
        fitButton(.fitWidth, label: "Fit Width", icon: "arrow.left.and.right", id: "page-zoom-fit-width")
    }

    private func fitButton(_ choice: PageZoomSetting, label: String, icon: String, id: String) -> some View {
        let selected = session.setting == choice
        return Button { choose(choice) } label: {
            Image(systemName: icon)
                #if os(iOS)
                .frame(width: 44, height: 44)
                #else
                .frame(width: 28, height: 32)
                #endif
                .background {
                    if selected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.22)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(id)
        #if os(macOS)
        .background {
            if let diagnosticControls {
                WorkspaceDiagnosticControlProbe(controls: diagnosticControls, identifier: id,
                    value: selected ? "Selected" : "Not selected", action: { choose(choice) })
            }
        }
        #endif
    }

    private func choose(_ setting: PageZoomSetting) {
        percentageDraft = nil
        session.choose(setting)
    }
}
