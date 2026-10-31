import SwiftUI
import UniformTypeIdentifiers
import NotesCore
#if os(macOS)
import AppKit
#endif

struct SheetDetail: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var inputDevice: InputDeviceMonitor
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = "system"
    let sheetID: UUID
    @AppStorage("inkColor") private var inkColor = "#30343B"
    @AppStorage("inkWidth") private var inkWidth = 2.5
    @AppStorage("inkTool") private var selectedTool = "pen"
    @ViewState private var showAttachmentImporter = false
    @ViewState private var showExporter = false
    @ViewState private var exportData = BackupDocument()
    @ViewState private var exportType: UTType = .plainText
    @ViewState private var exportName = "Note"
    private var sheet: NoteNode? { store.library.node(id: sheetID) }
    private var inkTool: InkTool { InkTool(rawValue: selectedTool) ?? .pen }
    private var paper: InkPaper { InkPaper(rawValue: sheet?.paperStyle.rawValue ?? "dotted") ?? .dotted }
    private var pageTheme: PageTheme { colorScheme == .dark ? .dark : .light }

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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.breadcrumb(sheet.parentID)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            TextField("Untitled sheet", text: titleBinding(sheet))
                                .font(.system(size: 28, weight: .semibold, design: .serif)).textFieldStyle(.plain)
                                .accessibilityLabel("Sheet title").disabled(sheet.isTrashed)
                            HStack(spacing: 10) {
                                Text(sheet.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("·")
                                Text("\(sheet.body.split(whereSeparator: \.isWhitespace).count) words")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { store.update(sheet.id) { $0.isFavorite.toggle() } } label: {
                            Image(systemName: sheet.isFavorite ? "star.fill" : "star").foregroundStyle(sheet.isFavorite ? Color.orange : Color.secondary)
                        }.buttonStyle(.plain).help("Favorite sheet").disabled(sheet.isTrashed)
                        Menu {
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
                        } label: { Image(systemName: "ellipsis.circle") }
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        #endif
                        .frame(width: 24)
                    }
                    TagsField(tags: store.binding(sheet.id, \.tags, fallback: [])).disabled(sheet.isTrashed)
                }.padding(.horizontal, 30).padding(.top, 25).padding(.bottom, 18)
                Divider()
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            drawingTools
                            Divider().frame(height: 22)
                            inkSettings
                            #if os(macOS)
                            if inkTool == .text { Divider().frame(height: 22); formattingToolbar }
                            #endif
                        }.fixedSize(horizontal: true, vertical: false)
                    }.frame(height: 34)
                    Button { showAttachmentImporter = true } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.plain).help("Attach a file (up to 10 MiB)")
                }.padding(.horizontal, 18).padding(.vertical, 10).disabled(sheet.isTrashed)
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
                            .font(.caption).foregroundStyle(inputDevice.detected ? Color.accentColor : Color.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("Text and ink share this page").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 9)
                Divider()
                UnifiedPageEditor(text: store.binding(sheet.id, \.body, fallback: ""),
                                  rtfData: store.binding(sheet.id, \.richTextRTF, fallback: nil),
                                  strokes: store.binding(sheet.id, \.strokes, fallback: []),
                                  pencilKitData: store.binding(sheet.id, \.pencilKitData, fallback: nil),
                                  tool: inkTool, colorHex: inkColor, lineWidth: inkWidth, paper: paper, theme: pageTheme,
                                  onTextChange: { text, data in store.update(sheet.id) { $0.body = text; $0.richTextRTF = data } },
                                  onInkChange: { strokes, data in store.update(sheet.id) { $0.strokes = strokes; $0.pencilKitData = data } },
                                  onInputChange: { inputDevice.report($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity).disabled(sheet.isTrashed)
                if !sheet.attachments.isEmpty { attachments(sheet) }
            }
            .background(editorBackground)
            .navigationTitle(sheet.title)
            .fileImporter(isPresented: $showAttachmentImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { for url in try result.get() { try attach(url, to: sheet.id) } }
                catch { store.errorMessage = error.localizedDescription }
            }
            .fileExporter(isPresented: $showExporter, document: exportData, contentType: exportType, defaultFilename: exportName) { result in
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
            }
        }
    }

    private var editorBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private func titleBinding(_ sheet: NoteNode) -> Binding<String> {
        Binding(get: { store.library.node(id: sheet.id)?.title ?? "" }, set: { value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 256 { store.rename(sheet.id, to: value) }
        })
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
            toolButton(.pen, title: "Pen", symbol: "pencil.tip")
            toolButton(.line, title: "Straight line", symbol: "line.diagonal")
            toolButton(.pencil, title: "Pencil", symbol: "pencil")
            toolButton(.marker, title: "Marker", symbol: "paintbrush.pointed")
            toolButton(.highlighter, title: "Highlighter", symbol: "highlighter")
            toolButton(.eraser, title: "Eraser", symbol: "eraser")
        }
    }

    private func toolButton(_ tool: InkTool, title: String, symbol: String) -> some View {
        Button {
            selectedTool = tool.rawValue
            switch tool {
            case .pen: inkWidth = 2.5
            case .line: inkWidth = 2.5; inkColor = "#30343B"
            case .pencil: inkWidth = 1.5
            case .marker: inkWidth = 4
            case .highlighter: inkWidth = 4.5; inkColor = "#E2B84D"
            case .text, .eraser: break
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 30)
                .background(inkTool == tool ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .help(tool == .line ? "Draw a straight line. Nearby horizontal and vertical lines snap into place; hold Shift on Mac to lock an axis." : "\(title) tool")
            .accessibilityLabel("\(title) tool")
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
                Button("Fine") { inkWidth = 1.5 }
                Button("Medium") { inkWidth = 2.5 }
                Button("Broad") { inkWidth = 7 }
                Button("Highlighter width") { inkWidth = 4.5 }
                Divider()
                ForEach(PaperStyle.allCases, id: \.self) { style in
                    Button { store.update(sheetID) { $0.paperStyle = style } } label: {
                        Label(style.rawValue.capitalized + " paper", systemImage: style == sheet?.paperStyle ? "checkmark" : "square")
                    }
                }
                Divider()
                Text("Appearance")
                ForEach(["system", "light", "dark"], id: \.self) { choice in
                    Button { appearance = choice } label: {
                        Label(choice == "system" ? "Match system" : choice.capitalized,
                              systemImage: appearance == choice ? "checkmark" : "circle.lefthalf.filled")
                    }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
            .help("Stroke width, paper style, and appearance").accessibilityLabel("Paper and appearance")
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
        exportData = BackupDocument(data: Data((sheet.title + "\n\n" + sheet.body).utf8))
        exportType = .plainText
        exportName = sheet.title
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
