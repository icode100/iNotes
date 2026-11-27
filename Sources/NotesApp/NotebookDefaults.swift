import SwiftUI
import NotesCore

private struct NotebookDefaultsActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openNotebookDefaults: () -> Void {
        get { self[NotebookDefaultsActionKey.self] }
        set { self[NotebookDefaultsActionKey.self] = newValue }
    }
}

enum PageZoomSetting: Codable, Hashable {
    case scale(Double)
    case fitPage
    case fitWidth

    static let manualRange = 0.25...4.0

    var isValid: Bool {
        switch self {
        case .scale(let scale): return scale.isFinite && Self.manualRange.contains(scale)
        case .fitPage, .fitWidth: return true
        }
    }
}

struct NotebookDefaults: Codable, Equatable {
    static let preferenceKey = "notebook.creationDefaults.v1"
    static let writingTools: [InkTool] = [.pen, .pencil, .marker, .highlighter, .line, .diagram]
    var widths: [String: Double] = [:]
    var colors: [String: String] = [:]
    var paper = PaperStyle.dotted
    var template = PageTemplate.none
    var guideStyle = LinePattern.solid
    var zoom = PageZoomSetting.scale(1)

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        widths = try values.decode([String: Double].self, forKey: .widths)
        colors = try values.decode([String: String].self, forKey: .colors)
        paper = try values.decode(PaperStyle.self, forKey: .paper)
        template = try values.decode(PageTemplate.self, forKey: .template)
        guideStyle = try values.decode(LinePattern.self, forKey: .guideStyle)
        // An older preference has no zoom field. Keep the user's pen and paper
        // choices when upgrading or when a newer zoom option is unrecognized.
        if let savedZoom = try? values.decode(PageZoomSetting.self, forKey: .zoom), savedZoom.isValid {
            zoom = savedZoom
        }
    }

    func width(for tool: InkTool) -> Double {
        widths[tool.rawValue] ?? InkNibPreset.defaultWidth(for: tool)
    }

    func color(for tool: InkTool) -> String? {
        if let color = colors[tool.rawValue] { return color }
        switch tool {
        case .highlighter: return "#E2B84D"
        case .line: return "#30343B"
        default: return nil
        }
    }

    var isValid: Bool {
        let keys = Set(Self.writingTools.map(\.rawValue))
        return zoom.isValid && template.isSupported(on: paper)
            && widths.allSatisfy { keys.contains($0.key) && $0.value.isFinite && (0.5...InkGeometryLimits.maximumStrokeWidth).contains($0.value) }
            && colors.allSatisfy { entry in
                let hex = entry.value.utf8
                return keys.contains(entry.key) && hex.count == 7 && hex.first == 35 && hex.dropFirst().allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }
            }
    }

    static func load(from preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: preferenceKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.isValid else { return Self() }
        return saved
    }
}

struct NotebookDefaultsView: View {
    @ObservedObject var store: NotesStore
    @ViewState private var draft: NotebookDefaults
    @ViewState private var tool = InkTool.pen
    @ViewState private var zoomText: String?
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    init(store: NotesStore) {
        self.store = store
        _draft = ViewState(initialValue: store.notebookDefaults)
    }

    private var tools: [InkTool] {
        #if os(macOS)
        NotebookDefaults.writingTools
        #else
        NotebookDefaults.writingTools.filter { $0 != .diagram }
        #endif
    }

    private var widthInMillimeters: Binding<Double> {
        Binding(get: { InkNibPreset.millimeters(width: draft.width(for: tool), tool: tool) },
                set: { draft.widths[tool.rawValue] = InkNibPreset.storedWidth(millimeters: $0, tool: tool) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notebook defaults").font(.title2.bold())
            Form {
                Section("When selecting a drawing tool") {
                    Picker("Tool", selection: $tool) {
                        ForEach(tools, id: \.self) { item in
                            Text(toolName(item)).tag(item)
                        }
                    }
                    let presets = InkNibPreset.presets(for: tool)
                    let preset = presets.first { abs($0.width(for: tool) - draft.width(for: tool)) < 0.000001 }
                    Picker("Width", selection: Binding(get: { preset?.rawValue ?? "custom" }, set: { raw in
                        if let selection = InkNibPreset(rawValue: raw) {
                            draft.widths[tool.rawValue] = selection.width(for: tool)
                        }
                    })) {
                        ForEach(presets, id: \.self) { size in Text(size.label(for: tool)).tag(size.rawValue) }
                        if preset == nil { Text("Custom").tag("custom") }
                    }
                    HStack {
                        Text("Width in mm")
                        Spacer()
                        TextField("Millimeters", value: widthInMillimeters,
                                  format: .number.precision(.fractionLength(0...3)))
                            .multilineTextAlignment(.trailing).frame(width: 84)
                    }
                    Toggle("Use a default ink color", isOn: Binding(get: { draft.colors[tool.rawValue] != nil }, set: { enabled in
                        draft.colors[tool.rawValue] = enabled ? (draft.color(for: tool) ?? "#30343B") : nil
                    }))
                    if let hex = draft.colors[tool.rawValue] {
                        ColorPicker("Ink color", selection: Binding(get: { Color(hex: hex) },
                            set: { draft.colors[tool.rawValue] = InkColors.canonicalHex($0) }), supportsOpacity: false)
                    }
                }
                Section("For new pages") {
                    Picker("Paper", selection: Binding(get: { draft.paper }, set: { paper in
                        draft.paper = paper
                        draft.template = draft.template.effective(on: paper)
                    })) {
                        ForEach(PaperStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Template", selection: $draft.template) {
                        ForEach(PageTemplate.allCases.filter { $0.isSupported(on: draft.paper) }, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Template line", selection: $draft.guideStyle) {
                        ForEach(LinePattern.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Pages without a saved zoom") {
                    Picker("Default zoom", selection: Binding(get: {
                        if case .scale = draft.zoom { return PageZoomSetting.scale(1) }
                        return draft.zoom
                    }, set: { selection in
                        if case .scale = selection, case .scale = draft.zoom { return }
                        zoomText = nil
                        draft.zoom = selection
                    })) {
                        Text("Percentage").tag(PageZoomSetting.scale(1))
                        Text("Fit Page").tag(PageZoomSetting.fitPage)
                        Text("Fit Width").tag(PageZoomSetting.fitWidth)
                    }
                    if case .scale(let scale) = draft.zoom {
                        HStack {
                            PageZoomSlider(label: "Default zoom percentage", id: "default-zoom", scale: Binding(get: { scale }, set: {
                                zoomText = nil
                                draft.zoom = .scale($0)
                            }))
                            ZoomPercentageField(scale: scale, draft: $zoomText, label: "Default zoom percentage",
                                                id: "default-zoom-percentage", commit: { draft.zoom = .scale($0) })
                        }
                    }
                }
            }.formStyle(.grouped)
            if !draft.isValid {
                Text("Enter a width between \(InkNibPreset.millimeters(width: 0.5, tool: tool), format: .number.precision(.fractionLength(3))) and \(InkNibPreset.millimeters(width: 100, tool: tool), format: .number.precision(.fractionLength(3))) mm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore defaults") { zoomText = nil; draft = NotebookDefaults() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    // A click on Save can arrive before the field loses focus.
                    if case .scale = draft.zoom, let zoomText,
                       let scale = ZoomPercentage.scale(from: zoomText, locale: locale) {
                        draft.zoom = .scale(scale)
                    }
                    store.saveNotebookDefaults(draft)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!draft.isValid)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 440)
        .frame(minHeight: 380, idealHeight: 625, maxHeight: 625)
        #endif
    }

    private func toolName(_ item: InkTool) -> String {
        switch item {
        case .line: return "Straight line"
        case .marker: return "Brush / Marker"
        case .diagram: return "Shapes and arrows"
        default: return item.rawValue.capitalized
        }
    }
}
