#if os(macOS)
import SwiftUI
import NotesCore

struct ConnectorAppearance: Equatable {
    enum AttachmentSides { case automatic, fixed, mixed }

    var route: PageDiagram.ConnectorRoute
    var heads: PageDiagram.ArrowHeads
    var openHeads: Bool
    var color: String
    var pattern: LinePattern
    var width: Double
    var attachmentSides: AttachmentSides

    init(_ connector: PageDiagram) {
        route = connector.route
        heads = connector.arrowHeads
        openHeads = connector.openArrowheads == true
        color = connector.colorHex
        pattern = connector.linePattern
        width = connector.lineWidth
        let attachments = [connector.startAttachment, connector.endAttachment].compactMap { $0 }
        let automaticCount = attachments.filter { $0.followsTarget == true }.count
        if automaticCount == 0 { attachmentSides = .fixed }
        else if automaticCount == attachments.count { attachmentSides = .automatic }
        else { attachmentSides = .mixed }
    }
}

extension MacPageSelectionController {
    var selectedConnector: PageDiagram? {
        guard let id = singleSelectedDiagramID else { return nil }
        return content.diagrams.first { $0.id == id && $0.kind == .connector }
    }

    @discardableResult
    func applyConnectorAppearance(_ style: ConnectorAppearance, to id: UUID) -> Bool {
        guard let page, page.inkView.isInputEnabled, singleSelectedDiagramID == id,
              let index = content.diagrams.firstIndex(where: { $0.id == id && $0.kind == .connector }) else { return false }
        var next = content
        if style.attachmentSides != .mixed && style.attachmentSides != ConnectorAppearance(content.diagrams[index]).attachmentSides {
            let frames = page.externalAnchorFrames(in: content)
            // Capture the visible ports when pinning. Switching to automatic
            // also reroutes an older arrow immediately in its current layout.
            if style.attachmentSides == .fixed {
                next.diagrams[index] = PageDiagramGeometry.routedConnectors(in: next.diagrams, frames: frames)[index]
            }
            let automatic: Bool? = style.attachmentSides == .automatic ? true : nil
            next.diagrams[index].startAttachment?.followsTarget = automatic
            next.diagrams[index].endAttachment?.followsTarget = automatic
            if automatic == true {
                next.diagrams[index] = PageDiagramGeometry.routedConnectors(in: next.diagrams, frames: frames)[index]
            }
        }
        next.diagrams[index].route = style.route
        next.diagrams[index].arrowHeads = style.heads
        next.diagrams[index].openArrowheads = style.openHeads ? true : nil
        next.diagrams[index].colorHex = style.color
        next.diagrams[index].linePattern = style.pattern
        next.diagrams[index].lineWidth = style.width
        return commit(next, action: "Change Arrow Style")
    }
}

/// Keep the color panel and line controls in a local draft so Apply is one undo.
struct ConnectorAppearanceButton: View {
    let connector: PageDiagram
    let selection: MacDiagramSelectionStyle
    var floating = false
    @ViewState private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("Arrow", systemImage: "arrow.up.right").font(.caption).frame(height: 30).floatingHitArea(floating)
        }
        .buttonStyle(.borderless)
        .help("Change the selected arrow’s style")
        .accessibilityLabel("Edit arrow style")
        .popover(isPresented: $isPresented) {
            ConnectorAppearanceForm(connector, selection: selection)
        }
    }
}

private struct ConnectorAppearanceForm: View {
    let connectorID: UUID
    let hasAttachments: Bool
    let hasMixedSides: Bool
    let selection: MacDiagramSelectionStyle
    @ViewState private var draft: ConnectorAppearance
    @Environment(\.dismiss) private var dismiss

    init(_ connector: PageDiagram, selection: MacDiagramSelectionStyle) {
        connectorID = connector.id
        hasAttachments = connector.startAttachment != nil || connector.endAttachment != nil
        hasMixedSides = ConnectorAppearance(connector).attachmentSides == .mixed
        self.selection = selection
        _draft = ViewState(initialValue: ConnectorAppearance(connector))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arrow style").font(.headline)
            Picker("Route", selection: $draft.route) {
                Text("Straight").tag(PageDiagram.ConnectorRoute.straight)
                Text("Elbow").tag(PageDiagram.ConnectorRoute.elbow)
            }
            if hasAttachments {
                Picker("Attachment sides", selection: $draft.attachmentSides) {
                    Text("Automatic").tag(ConnectorAppearance.AttachmentSides.automatic)
                    Text("Fixed").tag(ConnectorAppearance.AttachmentSides.fixed)
                    if hasMixedSides { Text("Mixed").tag(ConnectorAppearance.AttachmentSides.mixed) }
                }
                .help("Automatic picks the sides that face each other as objects move.")
            }
            Picker("Arrowheads", selection: $draft.heads) {
                Text("None").tag(PageDiagram.ArrowHeads.none)
                Text("End").tag(PageDiagram.ArrowHeads.end)
                Text("Both ends").tag(PageDiagram.ArrowHeads.both)
            }
            Picker("Head style", selection: $draft.openHeads) {
                Text("Filled").tag(false)
                Text("Open").tag(true)
            }.disabled(draft.heads == .none)
            Picker("Line", selection: $draft.pattern) {
                ForEach(LinePattern.allCases, id: \.self) { pattern in
                    Text(pattern.displayName).tag(pattern)
                }
            }
            Stepper(value: $draft.width, in: 0.5...100, step: 0.5) {
                Text("Width  \(draft.width, format: .number.precision(.fractionLength(0...2))) pt")
            }
            ColorPicker("Color", selection: Binding(get: { Color(hex: draft.color) },
                set: { draft.color = InkColors.canonicalHex($0) }), supportsOpacity: false)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    selection.apply(draft, to: connectorID)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .pickerStyle(.segmented).padding(16).frame(width: 320)
    }
}
#endif
