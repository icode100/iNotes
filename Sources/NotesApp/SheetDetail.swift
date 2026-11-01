import SwiftUI
import UniformTypeIdentifiers
import NotesCore
#if os(macOS)
import AppKit
#endif

enum InkNibPreset: String, CaseIterable {
    case extraFine, fine, medium, broad, highlighter

    static let pointsPerMillimeter = 72.0 / 25.4

    var title: String {
        switch self {
        case .extraFine: return "Extra Fine"
        case .fine: return "Fine"
        case .medium: return "Medium"
        case .broad: return "Broad"
        case .highlighter: return "Highlighter width"
        }
    }

    static func presets(for tool: InkTool) -> [Self] {
        tool == .highlighter ? [.fine, .medium, .broad, .highlighter] : [.extraFine, .fine, .medium, .broad]
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
        case .broad: return 7
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
    @ViewState private var showAttachmentImporter = false
    @ViewState private var showExporter = false
    @ViewState private var exportData = BackupDocument()
    @ViewState private var exportType: UTType = .plainText
    @ViewState private var exportName = "Note"
    @ViewState private var equationDraft: NoteEquation?
    @ViewState private var renameRequest: NameRequest?
    private var sheet: NoteNode? { store.library.node(id: sheetID) }
    private var inkTool: InkTool { InkTool(rawValue: selectedTool) ?? .pen }
    private var paper: InkPaper { InkPaper(rawValue: sheet?.paperStyle.rawValue ?? "dotted") ?? .dotted }
    private var pageTheme: PageTheme {
        (PageColorScheme(rawValue: pageColorScheme) ?? .system).resolved(isDark: colorScheme == .dark)
    }
    private var workspaceAccent: Color {
        (WorkspaceTheme(rawValue: workspaceTheme) ?? .classic).accent(isDark: colorScheme == .dark)
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
                            Text(store.sheetHeading(sheet.id))
                                .font(.system(size: 28, weight: .semibold, design: .serif))
                                .lineLimit(2).accessibilityAddTraits(.isHeader)
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
                                  tool: inkTool, colorHex: inkColor, lineWidth: inkWidth, paper: paper, theme: pageTheme,
                                  linePattern: LinePattern(rawValue: linePattern) ?? .solid,
                                  pageTemplate: sheet.pageTemplate, templateLinePattern: sheet.templateLinePattern,
                                  onTextChange: { text, data in store.update(sheet.id) { $0.body = text; $0.richTextRTF = data } },
                                  onInkChange: { strokes, data in store.update(sheet.id) { $0.strokes = strokes; $0.pencilKitData = data } },
                                  onInputChange: { inputDevice.report($0) },
                                  onPageChange: { content in store.update(sheet.id) { $0.pageContent = content } },
                                  onEquationEdit: { equationDraft = $0 })
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
        let words = ([sheet.body] + sheet.textBoxes.map(\.text)).joined(separator: " ")
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
        case .highlighter:
            inkWidth = InkNibPreset.defaultWidth(for: tool)
            inkColor = "#E2B84D"
        case .text, .select, .lasso, .eraser: break
        }
        NotificationCenter.default.post(name: .noteToolFocus, object: tool)
    }

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
            ForEach(["#30343B", "#314D43", "#3869B2", "#B14D55", "#E2B84D"], id: \.self) { hex in
                Button { inkColor = hex } label: {
                    Circle().fill(Color(hex: pageTheme.resolvedInkHex(hex))).frame(width: 15, height: 15)
                        .padding(3).overlay(Circle().stroke(inkColor == hex ? Color.secondary : .clear, lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel(inkColorName(hex))
            }
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

    private func inkColorName(_ hex: String) -> String {
        switch hex {
        case "#30343B": return pageTheme == .dark ? "Light graphite ink" : "Graphite ink"
        case "#314D43": return "Sage ink"
        case "#3869B2": return "Blue ink"
        case "#B14D55": return "Rose ink"
        default: return "Gold ink"
        }
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
        let data = try Data(contentsOf: url)
        guard data.count <= 10 * 1024 * 1024 else { throw LibraryError.tooLarge }
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
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Add tags, separated by commas", text: $draft)
            .font(.caption).textFieldStyle(.plain).foregroundStyle(.secondary)
            .focused($focused).onSubmit(commit)
            .onAppear { draft = tags.joined(separator: ", ") }
            .onDisappear(perform: commit)
            .onChange(of: focused) { _, value in if !value { commit() } }
    }
    private func commit() {
        let result = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if tags != result { tags = result }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
