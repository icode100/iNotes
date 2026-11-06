import SwiftUI
import UniformTypeIdentifiers
import NotesCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
/// Code-drawn icons avoid native menu image stripping.
private struct DiagramToolGlyph: View {
    let kind: PageDiagram.Kind
    var route: PageDiagram.ConnectorRoute = .straight
    var heads: PageDiagram.ArrowHeads = .none

    var body: some View {
        Path { path in
            let rect = CGRect(x: 2, y: 2, width: 24, height: 20)
            switch kind {
            case .rectangle, .table: path.addRect(rect)
            case .roundedRectangle: path.addRoundedRect(in: rect, cornerSize: CGSize(width: 5, height: 5))
            case .ellipse: path.addEllipse(in: rect)
            case .triangle:
                path.move(to: CGPoint(x: 14, y: 2)); path.addLine(to: CGPoint(x: 26, y: 22))
                path.addLine(to: CGPoint(x: 2, y: 22)); path.closeSubpath()
            case .diamond:
                path.move(to: CGPoint(x: 14, y: 2)); path.addLine(to: CGPoint(x: 26, y: 12))
                path.addLine(to: CGPoint(x: 14, y: 22)); path.addLine(to: CGPoint(x: 2, y: 12)); path.closeSubpath()
            case .connector:
                let startY: CGFloat = route == .straight ? 12 : 5
                let endY: CGFloat = route == .straight ? 12 : 19
                path.move(to: CGPoint(x: 3, y: startY))
                if route == .elbow {
                    path.addLine(to: CGPoint(x: 14, y: startY)); path.addLine(to: CGPoint(x: 14, y: endY))
                }
                path.addLine(to: CGPoint(x: 25, y: endY))
                if heads != .none {
                    path.move(to: CGPoint(x: 20, y: endY - 4)); path.addLine(to: CGPoint(x: 25, y: endY))
                    path.addLine(to: CGPoint(x: 20, y: endY + 4))
                }
                if heads == .both {
                    path.move(to: CGPoint(x: 8, y: startY - 4)); path.addLine(to: CGPoint(x: 3, y: startY))
                    path.addLine(to: CGPoint(x: 8, y: startY + 4))
                }
            }
            if kind == .table {
                for x in [10.0, 18.0] {
                    path.move(to: CGPoint(x: x, y: 2)); path.addLine(to: CGPoint(x: x, y: 22))
                }
                for y in [9.0, 15.0] {
                    path.move(to: CGPoint(x: 2, y: y)); path.addLine(to: CGPoint(x: 26, y: y))
                }
            }
        }.stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: 28, height: 24).accessibilityHidden(true)
    }
}
#endif

/// Canonical sRGB values. Paper themes adapt their display without changing
/// the selected color or the colors of strokes already stored in a notebook.
enum InkColors {
    static let palette: [(name: String, hex: String)] = [
        ("Graphite", "#30343B"), ("Sage", "#314D43"), ("Blue", "#3869B2"),
        ("Rose", "#B14D55"), ("Gold", "#E2B84D"), ("Violet", "#7852A9"),
        ("Teal", "#177E89"), ("Orange", "#C56A24"), ("Crimson", "#A62D42"),
        ("Indigo", "#4D4BA5"), ("Olive", "#6D762E"), ("Cocoa", "#805538"),
        ("Coral", "#DB746B"), ("Lilac", "#AA85C8"), ("Aqua", "#60B6B2"),
        ("Silver", "#92989F")
    ]

    @MainActor static func canonicalHex(_ color: Color) -> String {
        #if os(macOS)
        return ThemeTextAttributes.hex(NSColor(color))
        #else
        return ThemeTextAttributes.hex(UIColor(color))
        #endif
    }
}

enum InkNibPreset: String, CaseIterable {
    case extraFine, fine, medium, broad, extraBroad, highlighter

    static let pointsPerMillimeter = 72.0 / 25.4

    var title: String {
        switch self {
        case .extraFine: return "Extra Fine"
        case .fine: return "Fine"
        case .medium: return "Medium"
        case .broad: return "Broad"
        case .extraBroad: return "Extra Broad"
        case .highlighter: return "Highlighter width"
        }
    }

    static func presets(for tool: InkTool) -> [Self] {
        tool == .highlighter ? [.fine, .medium, .broad, .highlighter] : [.extraFine, .fine, .medium, .broad, .extraBroad]
    }

    static func defaultWidth(for tool: InkTool) -> Double { Self.fine.width(for: tool) }

    func millimeters(for tool: InkTool) -> Double {
        if tool == .highlighter {
            return legacyHighlighterWidth * InkStyle.highlighter.widthMultiplier / Self.pointsPerMillimeter
        }
        switch self {
        case .extraFine: return tool == .marker ? 0.5 : 0.3
        case .fine: return tool == .marker ? 0.7 : 0.45
        case .medium: return tool == .marker ? 1 : 0.7
        case .broad: return tool == .marker ? 1.5 : 1
        case .extraBroad: return tool == .marker ? 2 : tool == .pen ? 1.5 : 1.3
        case .highlighter: return 4.5 * InkStyle.highlighter.widthMultiplier / Self.pointsPerMillimeter
        }
    }

    /// Existing renderers and PencilKit configuration apply the style multiplier.
    /// Store its inverse here so the nominal nib matches the chosen millimetres,
    /// while retaining existing archive widths and pressure behavior unchanged.
    func width(for tool: InkTool) -> Double {
        if tool == .highlighter { return legacyHighlighterWidth }
        return millimeters(for: tool) * Self.pointsPerMillimeter / Self.multiplier(for: tool)
    }

    func label(for tool: InkTool) -> String {
        let millimeters = millimeters(for: tool)
        let measurement = tool == .highlighter ? String(format: "%.2f", millimeters) : String(format: "%g", millimeters)
        return "\(title) · \(measurement) mm"
    }

    static func customLabel(width: Double, tool: InkTool) -> String {
        let millimeters = width * multiplier(for: tool) / pointsPerMillimeter
        return "Custom · \(String(format: "%.2f", millimeters)) mm"
    }

    private static func multiplier(for tool: InkTool) -> Double {
        switch tool {
        case .pencil: return InkStyle.pencil.widthMultiplier
        case .marker: return InkStyle.marker.widthMultiplier
        case .highlighter: return InkStyle.highlighter.widthMultiplier
        default: return InkStyle.pen.widthMultiplier
        }
    }

    private var legacyHighlighterWidth: Double {
        switch self {
        case .extraFine: return 0.75 // Not offered for Highlighter.
        case .fine: return 1.5
        case .medium: return 2.5
        case .broad, .extraBroad: return 7 // Extra Broad is not offered for Highlighter.
        case .highlighter: return 4.5
        }
    }
}

struct SheetDetail: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var inputDevice: InputDeviceMonitor
    @EnvironmentObject private var presentation: EditorPresentation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("workspaceTheme") private var workspaceTheme = "classic"
    @AppStorage("pageColorScheme") private var pageColorScheme = "system"
    @AppStorage("linePattern") private var linePattern = "solid"
    let sheetID: UUID
    @AppStorage("inkColor") private var inkColor = "#30343B"
    @AppStorage("inkWidth") private var inkWidth = InkNibPreset.defaultWidth(for: .pen)
    @AppStorage("inkTool") private var selectedTool = "pen"
    @AppStorage("diagramKind") private var diagramKindPreference = "rectangle"
    @AppStorage("diagramConnectorRoute") private var connectorRoutePreference = "straight"
    @AppStorage("diagramArrowHeads") private var arrowHeadsPreference = "end"
    @AppStorage("diagramFill") private var diagramFill = false
    @AppStorage("diagramTableRows") private var tableRows = 3
    @AppStorage("diagramTableColumns") private var tableColumns = 3
    @ViewState private var showAttachmentImporter = false
    @ViewState private var showExporter = false
    @ViewState private var exportData = BackupDocument()
    @ViewState private var exportType: UTType = .plainText
    @ViewState private var exportName = "Note"
    @ViewState private var equationDraft: NoteEquation?
    @ViewState private var renameRequest: NameRequest?
    @ViewState private var showInkColors = false
    @ViewState private var showDiagramPalette = false
    private var sheet: NoteNode? { store.library.node(id: sheetID) }
    private var inkTool: InkTool { InkTool(rawValue: selectedTool) ?? .pen }
    private var diagramKind: PageDiagram.Kind { PageDiagram.Kind(rawValue: diagramKindPreference) ?? .rectangle }
    private var connectorRoute: PageDiagram.ConnectorRoute { PageDiagram.ConnectorRoute(rawValue: connectorRoutePreference) ?? .straight }
    private var arrowHeads: PageDiagram.ArrowHeads { PageDiagram.ArrowHeads(rawValue: arrowHeadsPreference) ?? .end }
    private var paper: InkPaper { InkPaper(rawValue: sheet?.paperStyle.rawValue ?? "dotted") ?? .dotted }
    private var pageTheme: PageTheme {
        (PageColorScheme(rawValue: pageColorScheme) ?? .system)
            .resolved(isDark: colorScheme == .dark, scenery: workspaceTheme)
    }
    private var workspaceAccent: Color {
        WorkspaceTheme(preferenceValue: workspaceTheme).accent(isDark: colorScheme == .dark)
    }

    var body: some View {
        if let sheet {
            VStack(spacing: 0) {
                if sheet.isTrashed {
                    HStack {
                        Label("This sheet is in Trash", systemImage: "trash").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { store.restore(sheet.id) }
                    }.padding().background(.orange.opacity(0.1))
                }
                if !presentation.fullPage && presentation.headingVisible {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.breadcrumb(sheet.parentID)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            SheetTitleField(title: sheet.title, isReadOnly: sheet.isTrashed) { candidate in
                                store.rename(sheet.id, to: candidate)
                                return store.library.node(id: sheet.id)?.title == candidate
                            }
                            headerMetadata(sheet)
                        }
                        Spacer(minLength: 8)
                        HStack(alignment: .center, spacing: 6) {
                            Button { store.update(sheet.id) { $0.isFavorite.toggle() } } label: {
                                Image(systemName: sheet.isFavorite ? "star.fill" : "star")
                                    .foregroundStyle(sheet.isFavorite ? Color.orange : Color.secondary)
                                    .frame(width: 30, height: 30)
                            }.buttonStyle(.plain).help("Favorite sheet").disabled(sheet.isTrashed)
                                .accessibilityLabel(sheet.isFavorite ? "Remove from favorites" : "Favorite sheet")
                            Menu {
                                if !sheet.isTrashed {
                                    Button("Rename sheet…") {
                                        renameRequest = NameRequest(kind: .sheet, renameID: sheet.id, title: sheet.title)
                                    }
                                    Divider()
                                }
                                Button("Export text…") { exportText(sheet) }
                                #if os(macOS)
                                Button("Export rich text…") { MacFileActions.exportRichText(sheet, store: store) }
                                Button("Export sheet as PDF…") { MacFileActions.exportPDF(sheet, theme: pageTheme, store: store) }
                                Button("Export page as PNG…") { MacFileActions.exportPagePNG(sheet, paper: paper, theme: pageTheme, store: store) }
                                #endif
                                Divider()
                                if !sheet.isTrashed {
                                    Button("Duplicate sheet") { store.duplicate(sheet.id) }
                                    MoveMenu(node: sheet)
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { store.trash(sheet.id) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
                            }
                            #if os(macOS)
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            #endif
                            .frame(width: 30, height: 30)
                            .help("More sheet actions").accessibilityLabel("More sheet actions")
                        }.font(.system(size: 18)).frame(height: 30)
                    }
                    TagsField(tags: store.binding(sheet.id, \.tags, fallback: [])).disabled(sheet.isTrashed)
                }.padding(.horizontal, 30).padding(.top, 25).padding(.bottom, 18)
                    .background { WorkspaceScenery() }
                Divider()
                }
                if presentation.toolsVisible {
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            drawingTools
                            #if os(macOS)
                            diagramTools
                            #endif
                            selectionActions
                            equationActions
                            Divider().frame(height: 22)
                            inkSettings
                            #if os(macOS)
                            if inkTool == .text { Divider().frame(height: 22); formattingToolbar }
                            #endif
                        }.fixedSize(horizontal: true, vertical: false)
                    }.frame(height: 34).disabled(sheet.isTrashed)
                    Button { showAttachmentImporter = true } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.plain).help("Attach a file (up to 10 MiB)").disabled(sheet.isTrashed)
                    sheetsButton
                    headingButton
                    fullPageButton
                    toolbarButton
                }.padding(.horizontal, 18).padding(.vertical, 10)
                HStack {
                    Menu {
                        Text(inputDevice.status)
                        #if os(macOS)
                        ForEach(inputDevice.tabletNames, id: \.self) { Text($0) }
                        Button("Check connected tablets") { inputDevice.refresh() }
                        #endif
                        Text("Stylus activity is detected when your pen reaches the page.")
                    } label: {
                        Label(inputDevice.status, systemImage: inputDevice.detected ? "pencil.tip.crop.circle.badge.checkmark" : "pencil.tip")
                            .font(.caption).foregroundStyle(inputDevice.detected ? workspaceAccent : Color.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("Text and ink share this page").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 9)
                Divider()
                }
                UnifiedPageEditor(text: store.binding(sheet.id, \.body, fallback: ""),
                                  rtfData: store.binding(sheet.id, \.richTextRTF, fallback: nil),
                                  strokes: store.binding(sheet.id, \.strokes, fallback: []),
                                  pencilKitData: store.binding(sheet.id, \.pencilKitData, fallback: nil),
                                  textBoxes: store.binding(sheet.id, \.textBoxes, fallback: []),
                                  equations: store.binding(sheet.id, \.equations, fallback: []),
                                  images: store.binding(sheet.id, \.images, fallback: []),
                                  diagrams: store.binding(sheet.id, \.diagrams, fallback: []),
                                  tool: inkTool, colorHex: inkColor, lineWidth: inkWidth, paper: paper, theme: pageTheme,
                                  linePattern: LinePattern(rawValue: linePattern) ?? .solid,
                                  pageTemplate: sheet.pageTemplate, templateLinePattern: sheet.templateLinePattern,
                                  diagramKind: diagramKind, connectorRoute: connectorRoute, arrowHeads: arrowHeads,
                                  tableRows: min(20, max(1, tableRows)), tableColumns: min(12, max(1, tableColumns)),
                                  diagramFill: diagramFill,
                                  onTextChange: { text, data in store.update(sheet.id) { $0.body = text; $0.richTextRTF = data } },
                                  onInkChange: { strokes, data in store.update(sheet.id) { $0.strokes = strokes; $0.pencilKitData = data } },
                                  onInputChange: { inputDevice.report($0) },
                                  onPageChange: { content in store.update(sheet.id) { $0.pageContent = content } },
                                  onEquationEdit: { equationDraft = $0 },
                                  onPageValidate: { store.validatePageChange(sheet.id, content: $0) },
                                  onPageError: { store.errorMessage = $0 },
                                  onObjectPlacement: { selectedTool = InkTool.select.rawValue })
                    .frame(maxWidth: .infinity, maxHeight: .infinity).disabled(sheet.isTrashed)
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if !presentation.toolsVisible {
                                HStack(spacing: 12) { sheetsButton; headingButton; fullPageButton; toolbarButton }
                                    .padding(10).background(.regularMaterial, in: Capsule())
                            }
                            let number = store.sheetNumber(sheet.id).map { "Sheet \($0)" } ?? "Sheet"
                            Text(number)
                                .font(.system(.caption, design: .monospaced)).fontWeight(.medium)
                                .foregroundStyle(.primary).fixedSize()
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .allowsHitTesting(false)
                                .accessibilityLabel("Current sheet, \(number)")
                        }.padding(12)
                    }
                if !sheet.attachments.isEmpty { attachments(sheet) }
            }
            .background(editorBackground)
            .navigationTitle(store.sheetHeading(sheet.id))
            .onReceive(NotificationCenter.default.publisher(for: .noteToolShortcut)) { note in
                if let tool = note.object as? InkTool, !sheet.isTrashed { selectTool(tool) }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $equationDraft) { equation in
                EquationEditor(equation: equation, theme: pageTheme) { saved in
                    store.update(sheet.id) { note in
                        if let index = note.equations.firstIndex(where: { $0.id == saved.id }) { note.equations[index] = saved }
                        else { note.equations.append(saved) }
                    }
                }
            }
            .sheet(item: $renameRequest) { request in
                NameDialog(request: request) { title in
                    if let id = request.renameID { store.rename(id, to: title) }
                }
            }
            .fileImporter(isPresented: $showAttachmentImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { for url in try result.get() { try attach(url, to: sheet.id) } }
                catch { store.errorMessage = error.localizedDescription }
            }
            .fileExporter(isPresented: $showExporter, document: exportData, contentType: exportType, defaultFilename: exportName) { result in
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
            }
        }
    }

    private func headerMetadata(_ sheet: NoteNode) -> some View {
        let number = store.sheetNumber(sheet.id).map { "Sheet \($0)" } ?? "Sheet"
        let created = "Created " + sheet.createdAt.formatted(date: .abbreviated, time: .shortened)
        let words = ([sheet.body] + sheet.textBoxes.map(\.text) + sheet.diagrams.map { $0.text + " " + $0.cells.joined(separator: " ") }).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).count
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(number).monospacedDigit()
                Text("·")
                Text(created)
                Text("·")
                Text("\(words) words")
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(number).monospacedDigit()
                    Text("·")
                    Text("\(words) words")
                }
                Text(created).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    private var sheetsButton: some View {
        let visible = !presentation.fullPage && presentation.sheetsVisible
        return Button { presentation.toggleSheets() } label: {
            Image(systemName: visible ? "sidebar.right" : "rectangle.split.2x1")
                .frame(width: 24, height: 28)
        }.buttonStyle(.plain)
            .help(visible ? "Hide sheets pane" : "Show sheets pane")
            .accessibilityLabel(visible ? "Hide sheets pane" : "Show sheets pane")
            .keyboardShortcut("2", modifiers: [.command, .shift])
    }

    private var headingButton: some View {
        let visible = !presentation.fullPage && presentation.headingVisible
        return Button { presentation.toggleHeading() } label: {
            Image(systemName: visible ? "text.rectangle" : "text.badge.plus")
                .frame(width: 24, height: 28)
        }.buttonStyle(.plain)
            .help(visible ? "Hide heading" : "Show heading")
            .accessibilityLabel(visible ? "Hide heading" : "Show heading")
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }

    private var fullPageButton: some View {
        Button { presentation.fullPage.toggle() } label: {
            Image(systemName: presentation.fullPage ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .frame(width: 24, height: 28)
        }.buttonStyle(.plain)
            .help(presentation.fullPage ? "Exit full page" : "Full page · hide navigation and heading")
            .accessibilityLabel(presentation.fullPage ? "Exit full page" : "Full page")
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }

    private var toolbarButton: some View {
        Button { presentation.toolsVisible.toggle() } label: {
            Image(systemName: presentation.toolsVisible ? "rectangle.topthird.inset.filled" : "slider.horizontal.3")
                .frame(width: 24, height: 28)
        }.buttonStyle(.plain)
            .help(presentation.toolsVisible ? "Hide drawing toolbar" : "Show drawing toolbar")
            .accessibilityLabel(presentation.toolsVisible ? "Hide drawing toolbar" : "Show drawing toolbar")
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }

    private var editorBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    #if os(macOS)
    private var formattingToolbar: some View {
        HStack(spacing: 4) {
            formatButton("Bold", "bold", .bold)
            formatButton("Italic", "italic", .italic)
            formatButton("Underline", "underline", .underline)
            Divider().frame(height: 16).padding(.horizontal, 3)
            formatButton("Heading", "textformat.size", .heading)
            formatButton("Body text", "textformat", .body)
            formatButton("Bullet list", "list.bullet", .bullet)
            formatButton("Checklist", "checklist", .checklist)
        }
    }
    private func formatButton(_ title: String, _ symbol: String, _ command: RichTextCommand) -> some View {
        Button { RichTextEditor.perform(command) } label: { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
    #endif

    private var drawingTools: some View {
        HStack(spacing: 3) {
            toolButton(.text, title: "Text", symbol: "textformat")
            toolButton(.select, title: "Select", symbol: "cursorarrow")
            toolButton(.lasso, title: "Lasso", symbol: "lasso")
            toolButton(.pen, title: "Pen", symbol: "pencil.tip")
            toolButton(.line, title: "Straight line", symbol: "line.diagonal")
            toolButton(.pencil, title: "Pencil", symbol: "pencil")
            toolButton(.marker, title: "Marker", symbol: "paintbrush.pointed")
            toolButton(.highlighter, title: "Highlighter", symbol: "highlighter")
            toolButton(.eraser, title: "Eraser", symbol: "eraser")
        }
    }

    private func toolButton(_ tool: InkTool, title: String, symbol: String) -> some View {
        Button { selectTool(tool) } label: {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 30)
                .background(inkTool == tool ? workspaceAccent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .help((tool == .line ? "Draw a straight line. Nearby horizontal and vertical lines snap into place; hold Shift on Mac to lock an axis." : "\(title) tool.") + " " + ToolShortcuts.help(for: tool))
            .accessibilityLabel("\(title) tool")
    }

    private func selectTool(_ tool: InkTool) {
        selectedTool = tool.rawValue
        switch tool {
        case .pen, .pencil, .marker:
            inkWidth = InkNibPreset.defaultWidth(for: tool)
        case .line:
            inkWidth = InkNibPreset.defaultWidth(for: tool)
            inkColor = "#30343B"
        case .diagram:
            inkWidth = InkNibPreset.defaultWidth(for: .line)
        case .highlighter:
            inkWidth = InkNibPreset.defaultWidth(for: tool)
            inkColor = "#E2B84D"
        case .text, .select, .lasso, .eraser: break
        }
        NotificationCenter.default.post(name: .noteToolFocus, object: tool)
    }

    #if os(macOS)
    private var diagramChoices: [(kind: PageDiagram.Kind, title: String)] {
        [(.rectangle, "Rectangle"), (.roundedRectangle, "Rounded rectangle"),
         (.ellipse, "Ellipse"), (.triangle, "Triangle"), (.diamond, "Diamond")]
    }

    private func chooseDiagram(_ kind: PageDiagram.Kind) {
        diagramKindPreference = kind.rawValue
        showDiagramPalette = false
        selectTool(.diagram)
    }

    private func diagramChoice(_ title: String, kind: PageDiagram.Kind,
                               route: PageDiagram.ConnectorRoute = .straight,
                               heads: PageDiagram.ArrowHeads = .none,
                               selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DiagramToolGlyph(kind: kind, route: route, heads: heads)
                .frame(width: 46, height: 38)
                .foregroundStyle(selected ? workspaceAccent : Color.primary)
                .background(selected ? workspaceAccent.opacity(0.16) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                            .foregroundStyle(workspaceAccent).padding(2)
                    }
                }
        }.buttonStyle(.plain).help(title)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var diagramTools: some View {
        Button { showDiagramPalette.toggle() } label: {
            Image(systemName: "square.on.circle").font(.system(size: 15)).frame(width: 30, height: 30)
                .background(inkTool == .diagram ? workspaceAccent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help("Shapes, arrow connectors and tables")
            .accessibilityLabel("Shapes and tables")
            .accessibilityValue(inkTool == .diagram ? diagramKindPreference : "Not selected")
            .popover(isPresented: $showDiagramPalette) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shapes").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(diagramChoices, id: \.kind) { choice in
                            diagramChoice(choice.title, kind: choice.kind, selected: diagramKind == choice.kind) {
                                chooseDiagram(choice.kind)
                            }
                        }
                    }
                    Divider()
                    Text("Connectors").font(.headline)
                    HStack(spacing: 8) {
                        ForEach([(PageDiagram.ArrowHeads.none, "Line"), (.end, "Arrow"), (.both, "Double arrow")], id: \.0) { value, title in
                            diagramChoice(title, kind: .connector, route: connectorRoute, heads: value,
                                          selected: diagramKind == .connector && arrowHeads == value) {
                                arrowHeadsPreference = value.rawValue
                                chooseDiagram(.connector)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Route").font(.caption).foregroundStyle(.secondary)
                        diagramChoice("Straight connector", kind: .connector,
                                      selected: connectorRoute == .straight) { connectorRoutePreference = "straight" }
                        diagramChoice("Elbow connector", kind: .connector, route: .elbow,
                                      selected: connectorRoute == .elbow) { connectorRoutePreference = "elbow" }
                    }
                    Divider()
                    Text("Table").font(.headline)
                    HStack(spacing: 12) {
                        diagramChoice("Draw table", kind: .table, selected: diagramKind == .table) {
                            chooseDiagram(.table)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Stepper("Rows: \(tableRows)", value: $tableRows, in: 1...20)
                            Stepper("Columns: \(tableColumns)", value: $tableColumns, in: 1...12)
                        }.controlSize(.small)
                    }
                    Toggle("Fill shapes", isOn: $diagramFill)
                    Text("Choose an icon, then drag once. Click blank paper to deselect; double-click an object to edit its text.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(width: 302)
                    .onAppear { tableRows = min(20, max(1, tableRows)); tableColumns = min(12, max(1, tableColumns)) }
            }
    }
    #endif

    @ViewBuilder
    private var selectionActions: some View {
        if inkTool == .select || inkTool == .lasso {
            Menu {
                selectionAction("Copy selection", .copy)
                selectionAction("Cut selection", .cut)
                selectionAction("Paste", .paste)
                selectionAction("Duplicate selection", .duplicate)
                selectionAction("Delete selection", .delete)
                Divider()
                selectionAction("Undo selection change", .undo)
                selectionAction("Redo selection change", .redo)
                Divider()
                selectionAction("Select all page content", .selectAll)
                selectionAction("Clear selection", .clear)
            } label: { Image(systemName: "square.dashed").frame(width: 30, height: 30) }
            .help("Selection actions").accessibilityLabel("Selection actions")
        }
    }

    private func selectionAction(_ title: String, _ command: PageSelectionCommand) -> some View {
        Button(title) { NotificationCenter.default.post(name: .pageSelectionCommand, object: command) }
    }

    private var equationActions: some View {
        Menu {
            Button("Insert equation…") {
                let bottom = max(sheet?.equations.map { $0.y + $0.height }.max() ?? 60,
                                 sheet?.strokes.flatMap(\.points).map(\.y).max() ?? 60)
                equationDraft = NoteEquation(x: 60, y: min(99_000, bottom + 30))
            }
            if let equations = sheet?.equations, !equations.isEmpty {
                Divider()
                ForEach(equations) { equation in
                    Button("Edit: " + String(equation.latex.prefix(48))) { equationDraft = equation }
                }
            }
        } label: { Image(systemName: "function").frame(width: 30, height: 30) }
        .help("Insert or edit a LaTeX equation").accessibilityLabel("Equations")
    }

    private var inkSettings: some View {
        HStack(spacing: 9) {
            ForEach(Array(InkColors.palette.prefix(5)), id: \.hex) { choice in
                inkSwatch(choice)
            }
            Button { showInkColors.toggle() } label: {
                Image(systemName: "paintpalette").frame(width: 24, height: 26)
            }.buttonStyle(.plain).help("More ink colors").accessibilityLabel("More ink colors")
                .popover(isPresented: $showInkColors) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Ink colors").font(.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(42)), count: 4), spacing: 12) {
                            ForEach(InkColors.palette, id: \.hex) { choice in
                                inkSwatch(choice)
                            }
                        }
                        customInkPicker
                        Text(inkColor.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(18)
                }
            customInkPicker.labelsHidden().frame(width: 26)
            Menu {
                let presets = InkNibPreset.presets(for: inkTool)
                if !presets.contains(where: { abs(inkWidth - $0.width(for: inkTool)) < 0.000_001 }) {
                    CheckedMenuButton(title: InkNibPreset.customLabel(width: inkWidth, tool: inkTool), isSelected: true) {}
                }
                ForEach(presets, id: \.self) { preset in
                    CheckedMenuButton(title: preset.label(for: inkTool),
                                      isSelected: abs(inkWidth - preset.width(for: inkTool)) < 0.000_001) {
                        inkWidth = preset.width(for: inkTool)
                    }
                }
                Divider()
                Menu("Straight line style") {
                    ForEach(LinePattern.allCases, id: \.self) { pattern in
                        CheckedMenuButton(title: pattern.displayName, isSelected: linePattern == pattern.rawValue) {
                            linePattern = pattern.rawValue
                        }
                    }
                }
                Divider()
                ForEach(PaperStyle.allCases, id: \.self) { style in
                    CheckedMenuButton(title: style.rawValue.capitalized + " paper", isSelected: style == sheet?.paperStyle) {
                        store.update(sheetID) { $0.paperStyle = style }
                    }
                }
                Divider()
                Menu("Page template") {
                    ForEach(PageTemplate.allCases, id: \.self) { template in
                        CheckedMenuButton(title: templateTitle(template), isSelected: sheet?.pageTemplate == template) {
                            store.update(sheetID) { $0.pageTemplate = template }
                        }.disabled(!template.isSupported(on: sheet?.paperStyle ?? .dotted))
                    }
                    Divider()
                    Text("Left margin supports plain and ruled paper.")
                    ForEach(LinePattern.allCases, id: \.self) { pattern in
                        CheckedMenuButton(title: pattern.displayName + " template line", isSelected: sheet?.templateLinePattern == pattern) {
                            store.update(sheetID) { $0.templateLinePattern = pattern }
                        }
                    }
                }
                Divider()
                AppearanceMenu()
            } label: { Image(systemName: "slider.horizontal.3") }
            .help("Nib width, line style, paper templates, and appearance").accessibilityLabel("Paper and appearance")
        }
    }

    private func templateTitle(_ template: PageTemplate) -> String {
        switch template {
        case .none: return "No template"
        case .centerDivider: return "Center divider"
        case .leftMargin: return "Left margin"
        }
    }

    private var customInkPicker: some View {
        ColorPicker("Custom ink color", selection: Binding(
            get: { Color(hex: inkColor) },
            set: { inkColor = InkColors.canonicalHex($0) }
        ), supportsOpacity: false)
        .help("Choose any ink color. Dark paper adapts dark colors for readability.")
        .accessibilityLabel("Custom ink color")
        .accessibilityValue(inkColor.uppercased())
    }

    private func inkSwatch(_ choice: (name: String, hex: String)) -> some View {
        Button { inkColor = choice.hex } label: {
            Circle().fill(Color(hex: pageTheme.resolvedInkHex(choice.hex))).frame(width: 15, height: 15)
                .padding(5).overlay(Circle().stroke(inkColor.uppercased() == choice.hex ? Color.primary : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).help(choice.name + " ink")
            .accessibilityLabel(choice.name + " ink")
            .accessibilityValue(inkColor.uppercased() == choice.hex ? "Selected" : "Not selected")
    }

    private func attachments(_ sheet: NoteNode) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(sheet.attachments) { attachment in
                    HStack(spacing: 6) {
                        Button {
                            exportData = BackupDocument(data: attachment.data)
                            exportType = .data
                            exportName = attachment.filename
                            showExporter = true
                        } label: { Label(attachment.filename, systemImage: "doc.zipper").lineLimit(1) }
                        .buttonStyle(.plain).help("Save attachment")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        if !sheet.isTrashed {
                            Button { store.update(sheet.id) { $0.attachments.removeAll { $0.id == attachment.id } } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove attachment")
                        }
                    }.font(.caption).padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(12)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func attach(_ url: URL, to id: UUID) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 10 * 1024 * 1024 else {
            throw LibraryError.invalidData("Choose a file no larger than 10 MiB.")
        }
        let data = try BoundedFileReader.read(from: url, maximumBytes: 10 * 1024 * 1024)
        let attachment = NoteAttachment(filename: url.lastPathComponent, mediaType: values.contentType?.preferredMIMEType ?? "application/octet-stream", data: data)
        // Check the portable-library size before accepting bytes into the working copy.
        var candidate = store.library
        if var node = candidate.node(id: id) {
            node.attachments.append(attachment)
            try candidate.update(node)
            _ = try LibraryArchive.encode(candidate)
            store.update(id) { $0.attachments.append(attachment) }
        }
    }

    private func exportText(_ sheet: NoteNode) {
        exportData = BackupDocument(data: Data((sheet.displayTitle + "\n\n" + sheet.plainTextExport).utf8))
        exportType = .plainText
        exportName = sheet.displayTitle
        showExporter = true
    }
}


struct TagsField: View {
    @Binding var tags: [String]
    @ViewState private var draft = ""
    #if os(macOS)
    @ViewState private var nativeDraft = MacHeadingFieldDraft()
    #else
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        #if os(macOS)
        MacHeadingField(text: $draft, role: .tags, nativeDraft: nativeDraft, onCommit: commit)
            .id(MacHeadingFieldRole.tags)
            .onAppear {
                let value = tags.joined(separator: ", ")
                nativeDraft.text = value
                draft = value
            }
            .onDisappear { commit(nativeDraft.text) }
        #else
        TextField("Add tags, separated by commas", text: $draft)
            .font(.caption).textFieldStyle(.plain).foregroundStyle(.secondary)
            .focused($focused).onSubmit { commit(draft) }
            .onAppear { draft = tags.joined(separator: ", ") }
            .onDisappear { commit(draft) }
            .onChange(of: focused) { _, value in if !value { commit(draft) } }
        #endif
    }

    private func commit(_ raw: String) {
        let result = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if tags != result { tags = result }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
