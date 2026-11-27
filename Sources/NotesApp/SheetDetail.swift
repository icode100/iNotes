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
        let millimeters = millimeters(width: width, tool: tool)
        return "Custom · \(String(format: "%.2f", millimeters)) mm"
    }

    static func millimeters(width: Double, tool: InkTool) -> Double {
        width * multiplier(for: tool) / pointsPerMillimeter
    }

    static func storedWidth(millimeters: Double, tool: InkTool) -> Double {
        millimeters * pointsPerMillimeter / multiplier(for: tool)
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

/// Owned by the sheet-keyed editor. Toolbar actions use its native history
/// even when clicking a button changes the window's first responder.
@MainActor
final class PageToolbarHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var manager: () -> UndoManager? = { nil }
    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false

    init() {
        for name: Notification.Name in [.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup,
                                         .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func bind(_ resolve: @escaping () -> UndoManager?) {
        manager = resolve
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshPending = false
            let current = manager()
            let undo = current?.canUndo == true
            let redo = current?.canRedo == true
            if undo != canUndo { canUndo = undo }
            if redo != canRedo { canRedo = redo }
        }
    }

    func undo() { if let manager = manager(), manager.canUndo { manager.undo() } }
    func redo() { if let manager = manager(), manager.canRedo { manager.redo() } }
}

struct SheetDetail: View {
    @Environment(\.openNotebookDefaults) private var openNotebookDefaults
    @EnvironmentObject private var store: NotesStore
    #if os(macOS)
    @Environment(\.workspaceDiagnosticControls) private var diagnosticControls
    #endif
    @EnvironmentObject private var inputDevice: InputDeviceMonitor
    @EnvironmentObject private var presentation: EditorPresentation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("workspaceTheme") private var workspaceTheme = "classic"
    @AppStorage("pageColorScheme") private var pageColorScheme = "system"
    @AppStorage("linePattern") private var linePattern = "solid"
    let sheetID: UUID
    let zoomSession: PageZoomSession
    @StateObject private var pageHistory = PageToolbarHistory()
    @StateObject private var selectedInkStyle = PageInkSelectionStyle()
    #if os(macOS)
    @StateObject private var selectedDiagramStyle = MacDiagramSelectionStyle()
    #endif
    @AppStorage("inkColor") private var inkColor = "#30343B"
    @AppStorage("inkWidth") private var inkWidth = InkNibPreset.defaultWidth(for: .pen)
    @AppStorage("inkTool") private var selectedTool = "pen"
    @AppStorage("fullScreenToolbarMode") private var fullScreenToolbarMode = FullScreenToolbarMode.docked
    @AppStorage("floatingToolbarAnchorX") private var floatingAnchorX = 0.90
    @AppStorage("floatingToolbarAnchorY") private var floatingAnchorY = 0.32
    private var showsFloatingToolbar: Bool {
        presentation.toolsVisible && presentation.isFullScreenWorkspace && fullScreenToolbarMode != .docked
    }
    private var floatingHoverOnly: Bool { fullScreenToolbarMode == .hover }
    private var floatingAnchor: Binding<CGPoint> {
        Binding(get: { CGPoint(x: floatingAnchorX, y: floatingAnchorY) }, set: {
            guard $0.x.isFinite, $0.y.isFinite else { return }
            floatingAnchorX = min(1, max(0, $0.x))
            floatingAnchorY = min(1, max(0, $0.y))
        })
    }
    private var fullScreenToolbarModeMenu: some View {
        FullScreenToolbarModeMenu { presentation.toolsVisible = true }
    }
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
    @ViewState private var recolorDraft = "#30343B"
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
                        Label("This page is in Trash", systemImage: "trash").foregroundStyle(.secondary)
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
                            }.buttonStyle(.plain).help("Favorite page").disabled(sheet.isTrashed)
                                .accessibilityLabel(sheet.isFavorite ? "Remove from favorites" : "Favorite page")
                            Menu {
                                if !sheet.isTrashed {
                                    Button("Rename page…") {
                                        renameRequest = NameRequest(kind: .sheet, renameID: sheet.id, title: sheet.title)
                                    }
                                    Divider()
                                }
                                Button("Export text…") { exportText(sheet) }
                                #if os(macOS)
                                Button("Export rich text…") { MacFileActions.exportRichText(sheet, store: store) }
                                Button("Export page as PDF…") { MacFileActions.exportPDF(sheet, theme: pageTheme, store: store) }
                                Button("Export page as PNG…") { MacFileActions.exportPagePNG(sheet, paper: paper, theme: pageTheme, store: store) }
                                if !sheet.isTrashed, let parentID = sheet.parentID, let folder = store.library.node(id: parentID) {
                                    Divider()
                                    NotebookExportButtons(folder: folder)
                                    if let workbook = store.library.path(to: folder.id).first, workbook.kind == .workbook {
                                        NotebookExportButtons(folder: workbook)
                                    }
                                }
                                #endif
                                Divider()
                                if !sheet.isTrashed {
                                    Button("Duplicate page") { store.duplicate(sheet.id) }
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
                            .help("More page actions").accessibilityLabel("More page actions")
                        }.font(.system(size: 18)).frame(height: 30)
                    }
                    TagsField(tags: store.binding(sheet.id, \.tags, fallback: [])).disabled(sheet.isTrashed)
                }.padding(.horizontal, 30).padding(.top, 25).padding(.bottom, 18)
                    .background { WorkspaceScenery() }
                Divider()
                }
                if presentation.toolsVisible && !showsFloatingToolbar {
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            HStack(spacing: 2) {
                                historyButton("Undo", symbol: "arrow.uturn.backward", enabled: pageHistory.canUndo, action: pageHistory.undo)
                                historyButton("Redo", symbol: "arrow.uturn.forward", enabled: pageHistory.canRedo, action: pageHistory.redo)
                            }
                            Divider().frame(height: 22)
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
                    attachmentButton(sheet)
                    sheetsButton
                    headingButton
                    fullPageButton
                    toolbarButton
                    if presentation.isFullScreenWorkspace { toolbarLayoutButton }
                }.padding(.horizontal, 18).padding(.vertical, 10)
                HStack {
                    tabletStatusMenu
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
                                  onObjectPlacement: { selectedTool = InkTool.select.rawValue },
                                  toolbarHistory: pageHistory, zoomSession: zoomSession)
                    .observingInkSelection(selectedInkStyle)
                    #if os(macOS)
                    .observingDiagramSelection(selectedDiagramStyle)
                    #endif
                    .frame(maxWidth: .infinity, maxHeight: .infinity).disabled(sheet.isTrashed)
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if !presentation.toolsVisible {
                                HStack(spacing: 12) {
                                    sheetsButton; headingButton; fullPageButton; toolbarButton
                                    if presentation.isFullScreenWorkspace { toolbarLayoutButton }
                                }
                                    .padding(10).background(.regularMaterial, in: Capsule())
                            }
                            let number = sheet.numberedPageTitle ?? "Page"
                            Text(number)
                                .font(.system(.caption, design: .monospaced)).fontWeight(.medium)
                                .foregroundStyle(.primary).fixedSize()
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .allowsHitTesting(false)
                                .accessibilityLabel("Current page, \(number)")
                        }.padding(12)
                    }
                    .overlay {
                        if showsFloatingToolbar { floatingDrawingToolbar(sheet) }
                    }
                if !sheet.attachments.isEmpty { attachments(sheet) }
            }
            .background(editorBackground)
            .navigationTitle(store.sheetHeading(sheet.id))
            .focusedSceneValue(\.floatingPagePresentation, showsFloatingToolbar ? presentation : nil)
            .onReceive(NotificationCenter.default.publisher(for: .noteToolShortcut)) { note in
                if let tool = note.object as? InkTool, !sheet.isTrashed { selectTool(tool) }
            }
            .onChange(of: store.notebookDefaults) { old, new in
                guard NotebookDefaults.writingTools.contains(inkTool) else { return }
                if old.width(for: inkTool) != new.width(for: inkTool) { inkWidth = new.width(for: inkTool) }
                if old.colors[inkTool.rawValue] != new.colors[inkTool.rawValue], let color = new.color(for: inkTool) { inkColor = color }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $equationDraft) { equation in
                EquationEditor(equation: equation, theme: pageTheme) { saved in
                    store.update(sheet.id) { note in
                        if let index = note.equations.firstIndex(where: { $0.id == saved.id }) { note.equations[index] = saved }
                        else { note.equations.append(saved) }
                        let frames = PageDiagramGeometry.externalAnchorFrames(images: note.images, textBoxes: note.textBoxes, equations: note.equations) { id in
                            #if os(macOS)
                            selectedDiagramStyle.textBoxHeight(id)
                            #else
                            nil
                            #endif
                        }
                        note.diagrams = PageDiagramGeometry.routedConnectors(in: note.diagrams, frames: frames,
                            movedDiagramIDs: [], movedObjectIDs: [.equation: [saved.id]])
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

    private func historyButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void,
                               floating: Bool = false) -> some View {
        let id = (floating ? "floating." : "page.history.") + title.lowercased()
        return Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 30).contentShape(Rectangle())
                .floatingHitArea(floating)
        }
        .buttonStyle(.borderless).disabled(!enabled).help(title).accessibilityLabel(title)
        .accessibilityIdentifier(id)
        #if os(macOS)
        .background {
            if let diagnosticControls {
                WorkspaceDiagnosticControlProbe(controls: diagnosticControls, identifier: id,
                                                enabled: enabled, value: title, action: action)
            }
        }
        #endif
    }

    private func headerMetadata(_ sheet: NoteNode) -> some View {
        let number = sheet.numberedPageTitle ?? "Page"
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
        let visible = presentation.sheetsVisible
        return Button { presentation.toggleSheets() } label: {
            Image(systemName: visible ? "ellipsis.rectangle.fill" : "ellipsis.rectangle")
                .frame(width: 24, height: 28)
        }.buttonStyle(.plain)
            .help(visible ? "Hide page navigation" : "Show page navigation")
            .accessibilityLabel(visible ? "Hide page navigation" : "Show page navigation")
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
            .help(presentation.fullPage ? "Exit full page" : "Full page · hide the sidebar and heading")
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

    private var toolbarLayoutButton: some View {
        fullScreenToolbarModeMenu
            .labelStyle(.iconOnly)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .frame(width: 28, height: 28)
            .accessibilityLabel("Full-screen toolbar")
    }

    private var editorBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private func attachmentButton(_ sheet: NoteNode, inMenu: Bool = false) -> some View {
        Button { showAttachmentImporter = true } label: {
            if inMenu { Label("Attach a file…", systemImage: "paperclip") }
            else { Image(systemName: "paperclip") }
        }
        .buttonStyle(.plain).help("Attach a file (up to 10 MiB)").accessibilityLabel("Attach a file")
        .disabled(sheet.isTrashed)
    }

    @ViewBuilder private var tabletStatusEntries: some View {
        Text(inputDevice.status)
        #if os(macOS)
        ForEach(inputDevice.tabletNames, id: \.self) { Text($0) }
        Button("Check connected tablets") { inputDevice.refresh() }
        #endif
        Text("Stylus activity is detected when your pen reaches the page.")
    }

    private var tabletStatusMenu: some View {
        Menu { tabletStatusEntries } label: {
            Label(inputDevice.status, systemImage: inputDevice.detected ? "pencil.tip.crop.circle.badge.checkmark" : "pencil.tip")
                .font(.caption).foregroundStyle(inputDevice.detected ? workspaceAccent : Color.secondary)
        }
    }

    #if os(macOS)
    private static let formatCommands: [(title: String, icon: String, command: RichTextCommand)] = [
        ("Bold", "bold", .bold), ("Italic", "italic", .italic), ("Underline", "underline", .underline),
        ("Heading", "textformat.size", .heading), ("Body text", "textformat", .body),
        ("Bullet list", "list.bullet", .bullet), ("Checklist", "checklist", .checklist)
    ]

    private var formattingToolbar: some View {
        HStack(spacing: 4) {
            ForEach(Self.formatCommands, id: \.command) { item in
                if item.command == .heading { Divider().frame(height: 16).padding(.horizontal, 3) }
                formatButton(item.title, item.icon, item.command)
            }
        }
    }
    private func formatButton(_ title: String, _ symbol: String, _ command: RichTextCommand) -> some View {
        Button { RichTextEditor.perform(command) } label: { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
    #endif

    private static let drawingChoices: [(tool: InkTool, title: String, symbol: String)] = [
        (.text, "Text", "textformat"), (.select, "Select", "cursorarrow"), (.lasso, "Lasso", "lasso"),
        (.pen, "Pen", "pencil.tip"), (.line, "Straight line", "line.diagonal"), (.pencil, "Pencil", "pencil"),
        (.marker, "Marker", "paintbrush.pointed"), (.highlighter, "Highlighter", "highlighter"), (.eraser, "Eraser", "eraser")
    ]

    private var drawingTools: some View {
        HStack(spacing: 3) {
            ForEach(Self.drawingChoices, id: \.tool) { item in
                toolButton(item.tool, title: item.title, symbol: item.symbol)
            }
        }
    }

    private func toolButton(_ tool: InkTool, title: String, symbol: String, floating: Bool = false) -> some View {
        Button { selectTool(tool) } label: {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 30)
                .background(inkTool == tool ? workspaceAccent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .floatingHitArea(floating)
        }.buttonStyle(.plain)
            .help((tool == .line ? "Draw a straight line. Nearby horizontal and vertical lines snap into place; hold Shift on Mac to lock an axis." : "\(title) tool.") + " " + ToolShortcuts.help(for: tool))
            .accessibilityLabel("\(title) tool")
            .accessibilityValue(inkTool == tool ? "Selected" : "Not selected")
    }

    private func selectTool(_ tool: InkTool) {
        selectedTool = tool.rawValue
        if NotebookDefaults.writingTools.contains(tool) {
            inkWidth = store.notebookDefaults.width(for: tool)
            if let color = store.notebookDefaults.color(for: tool) { inkColor = color }
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
        HStack(spacing: 5) {
            diagramPaletteButton()
            selectedDiagramAppearance
        }
    }

    private func diagramPaletteButton(floating: Bool = false) -> some View {
        Button { showDiagramPalette.toggle() } label: {
            Image(systemName: "square.on.circle").font(.system(size: 15)).frame(width: 30, height: 30)
                .background(inkTool == .diagram ? workspaceAccent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .floatingHitArea(floating)
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
                    Toggle("Fill new shapes", isOn: $diagramFill)
                    Divider()
                    HStack {
                        Text("Selection").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        selectedDiagramAppearance
                    }
                    Text("Choose an icon, then drag once. Click blank paper to deselect; double-click an object to edit its text.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(width: 302)
                    .onAppear { tableRows = min(20, max(1, tableRows)); tableColumns = min(12, max(1, tableColumns)) }
            }
    }

    @ViewBuilder private var selectedDiagramAppearance: some View {
        if let arrow = selectedDiagramStyle.editableConnector {
            ConnectorAppearanceButton(connector: arrow, selection: selectedDiagramStyle).id(arrow.id)
        } else {
            selectedShapeFillMenu
        }
    }

    private var selectedShapeFillMenu: some View {
        Menu {
            if selectedDiagramStyle.fill == nil && selectedDiagramStyle.selectedCount > 0 {
                Text("Mixed fill")
            }
            CheckedMenuButton(title: "Filled", isSelected: selectedDiagramStyle.fill == true) {
                selectedDiagramStyle.setFill(true)
            }
            CheckedMenuButton(title: "No fill", isSelected: selectedDiagramStyle.fill == false) {
                selectedDiagramStyle.setFill(false)
            }
        } label: {
            Label("Fill", systemImage: "paintbrush.fill").font(.caption).frame(height: 30)
        }
        .menuStyle(.borderlessButton)
        .disabled(!selectedDiagramStyle.canEdit)
        .help(selectedDiagramStyle.selectedCount == 0 ? "Select a shape or table to edit its fill" : "Change fill on selected shapes and tables")
        .accessibilityLabel("Fill selected shapes")
        .accessibilityValue(selectedDiagramStyle.accessibilityValue)
        .accessibilityIdentifier("page.diagram.fill")
    }
    #endif

    @ViewBuilder
    private var selectionActions: some View {
        if inkTool == .select || inkTool == .lasso {
            Menu { selectionCommands } label: { Image(systemName: "square.dashed").frame(width: 30, height: 30) }
            .help("Selection actions").accessibilityLabel("Selection actions")
        }
    }

    @ViewBuilder private var selectionCommands: some View {
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
    }

    private func selectionAction(_ title: String, _ command: PageSelectionCommand) -> some View {
        Button(title) { NotificationCenter.default.post(name: .pageSelectionCommand, object: command) }
    }

    private var equationActions: some View {
        Menu { equationCommands } label: { Image(systemName: "function").frame(width: 30, height: 30) }
        .help("Insert or edit a LaTeX equation").accessibilityLabel("Equations")
    }

    @ViewBuilder private var equationCommands: some View {
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
    }

    private var inkSettings: some View {
        HStack(spacing: 9) {
            ForEach(Array(InkColors.palette.prefix(5)), id: \.hex) { choice in
                inkSwatch(choice)
            }
            inkPaletteButton()
            if !selectedInkStyle.canEdit { customInkPicker.labelsHidden().frame(width: 26) }
            paperSettingsMenu()
        }
    }

    private func inkPaletteButton(compact: Bool = false) -> some View {
        Button {
            if !showInkColors { recolorDraft = inkColor }
            showInkColors.toggle()
        } label: {
            if selectedInkStyle.canEdit && !compact { Label("Recolor ink", systemImage: "paintpalette") }
            else { Image(systemName: "paintpalette").frame(width: 24, height: 26).floatingHitArea(compact) }
        }.buttonStyle(.plain)
            .help(selectedInkStyle.canEdit ? "Recolor selected handwriting" : "More ink colors")
            .accessibilityLabel(selectedInkStyle.canEdit ? "Recolor selected handwriting" : "More ink colors")
            .popover(isPresented: $showInkColors) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(selectedInkStyle.canEdit ? "Recolor selected ink" : "Ink colors").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(42)), count: 4), spacing: 12) {
                        ForEach(InkColors.palette, id: \.hex) { choice in
                            inkSwatch(choice)
                        }
                    }
                    if selectedInkStyle.canEdit {
                        ColorPicker("Custom color", selection: Binding(get: { Color(hex: recolorDraft) },
                            set: { recolorDraft = InkColors.canonicalHex($0) }), supportsOpacity: false)
                        HStack {
                            Text(recolorDraft).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Apply") {
                                selectedInkStyle.apply(recolorDraft)
                                showInkColors = false
                            }
                        }
                    } else {
                        customInkPicker
                        Text(inkColor.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }.padding(18)
            }
            .onChange(of: selectedInkStyle.canEdit) { _, _ in showInkColors = false }
    }

    private func paperSettingsMenu(readOnly: Bool = false, floating: Bool = false) -> some View {
        Menu {
            Group {
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
            }.disabled(readOnly)
            Divider()
            Button("Notebook defaults…", action: openNotebookDefaults)
            AppearanceMenu(showPageNavigation: { presentation.sheetsVisible = true })
        } label: { Image(systemName: "slider.horizontal.3").floatingHitArea(floating) }
        .help("Nib width, line style, paper templates, and appearance").accessibilityLabel("Paper and appearance")
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
        let isCurrent = !selectedInkStyle.canEdit && inkColor.uppercased() == choice.hex
        let label = selectedInkStyle.canEdit ? "Recolor selected ink " + choice.name : choice.name + " ink"
        return Button {
            if selectedInkStyle.canEdit {
                selectedInkStyle.apply(choice.hex)
                showInkColors = false
            } else { inkColor = choice.hex }
        } label: {
            Circle().fill(Color(hex: pageTheme.resolvedInkHex(choice.hex))).frame(width: 15, height: 15)
                .padding(5).overlay(Circle().stroke(isCurrent ? Color.primary : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).help(label)
            .accessibilityLabel(label)
            .accessibilityValue(selectedInkStyle.canEdit ? "" : (isCurrent ? "Selected" : "Not selected"))
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


private extension View {
    @ViewBuilder func floatingHitArea(_ enabled: Bool) -> some View {
        if enabled { frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Circle()) }
        else { self }
    }
}

private enum FloatingPageTool: Hashable {
    case exitWorkspace, drawing(InkTool), colors, undo, redo, paper, more
    #if os(macOS)
    case shapes
    #endif
}

extension SheetDetail {
    func floatingDrawingToolbar(_ sheet: NoteNode) -> some View {
        // Keep Exit on the first group of controls when the ring needs paging.
        var items = [FloatingPageTool.exitWorkspace] + Self.drawingChoices.map { .drawing($0.tool) }
        #if os(macOS)
        items.append(.shapes)
        #endif
        items += [.colors, .undo, .redo, .paper, .more]
        return FloatingPageToolbar(items: items, hoverOnly: floatingHoverOnly, anchor: floatingAnchor) { item in
            floatingControl(item, sheet: sheet)
        }
    }

    @ViewBuilder private func floatingControl(_ item: FloatingPageTool, sheet: NoteNode) -> some View {
        #if os(macOS)
        let readOnly = sheet.isTrashed
        #else
        let readOnly = sheet.isTrashed || !sheet.images.isEmpty || !sheet.diagrams.isEmpty
        #endif
        switch item {
        case .exitWorkspace:
            Button(action: presentation.exitFullScreenWorkspace) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").floatingHitArea(true)
            }
            .buttonStyle(.plain)
            .help(exitWorkspaceTitle)
            .accessibilityLabel(exitWorkspaceTitle)
            .accessibilityIdentifier("floating.exitWorkspace")
            #if os(macOS)
            .background {
                if let diagnosticControls {
                    WorkspaceDiagnosticControlProbe(controls: diagnosticControls, identifier: "floating.exitWorkspace",
                        value: exitWorkspaceTitle, action: presentation.exitFullScreenWorkspace)
                }
            }
            #endif
        case .drawing(let tool):
            if let choice = Self.drawingChoices.first(where: { $0.tool == tool }) {
                toolButton(tool, title: choice.title, symbol: choice.symbol, floating: true)
                    .disabled(readOnly)
                    .accessibilityIdentifier("floating." + tool.rawValue)
                    #if os(macOS)
                    .background {
                        if let diagnosticControls {
                            WorkspaceDiagnosticControlProbe(controls: diagnosticControls, identifier: "floating." + tool.rawValue,
                                enabled: !readOnly, value: inkTool == tool ? "Selected" : "Not selected", action: { selectTool(tool) })
                        }
                    }
                    #endif
            }
        #if os(macOS)
        case .shapes:
            diagramPaletteButton(floating: true).disabled(readOnly)
        #endif
        case .colors:
            inkPaletteButton(compact: true).disabled(readOnly)
        case .undo:
            historyButton("Undo", symbol: "arrow.uturn.backward", enabled: !readOnly && pageHistory.canUndo,
                          action: pageHistory.undo, floating: true)
        case .redo:
            historyButton("Redo", symbol: "arrow.uturn.forward", enabled: !readOnly && pageHistory.canRedo,
                          action: pageHistory.redo, floating: true)
        case .paper:
            paperSettingsMenu(readOnly: readOnly, floating: true)
                #if os(macOS)
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                #endif
        case .more:
            moreFloatingTools(sheet, readOnly: readOnly)
        }
    }

    private var exitWorkspaceTitle: String { presentation.nativeFullScreen ? "Exit Full Screen" : "Exit Full Page" }

    private func moreFloatingTools(_ sheet: NoteNode, readOnly: Bool) -> some View {
        Menu {
            Group {
                Menu("Selection") { selectionCommands }
                Menu("Equations") { equationCommands }
                #if os(macOS)
                if inkTool == .text {
                    Menu("Format text") {
                        ForEach(Self.formatCommands, id: \.command) { item in
                            Button(item.title) { RichTextEditor.perform(item.command) }
                        }
                    }
                }
                #endif
                attachmentButton(sheet, inMenu: true)
            }.disabled(readOnly)
            Divider()
            Button(presentation.sheetsVisible ? "Hide page navigation" : "Show page navigation") {
                presentation.toggleSheets()
            }
            PageNavigationModeMenu(showPageNavigation: { presentation.sheetsVisible = true })
            Button(!presentation.fullPage && presentation.headingVisible ? "Hide heading" : "Show heading") {
                presentation.toggleHeading()
            }
            if !presentation.fullPage {
                Button("Full page") { presentation.fullPage = true }
            }
            Button(exitWorkspaceTitle, action: presentation.exitFullScreenWorkspace)
            fullScreenToolbarModeMenu
            Button("Hide drawing toolbar") { presentation.toolsVisible.toggle() }
            Divider()
            Menu(inputDevice.status) { tabletStatusEntries }
        } label: { Image(systemName: "ellipsis.circle").floatingHitArea(true) }
        #if os(macOS)
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        #endif
        .help("More page tools").accessibilityLabel("More page tools")
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
