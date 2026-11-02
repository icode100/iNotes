import SwiftUI
import UniformTypeIdentifiers
import NotesCore

// Disambiguate the classic property wrapper from newer SDK State macros.
typealias ViewState<Value> = SwiftUI.State<Value>

extension NoteKind {
    var symbol: String {
        switch self { case .workbook: "books.vertical"; case .chapter: "rectangle.stack"; case .topic: "folder"; case .sheet: "doc.text" }
    }
}

struct NameRequest: Identifiable {
    let id = UUID()
    var kind: NoteKind
    var parent: UUID?
    var renameID: UUID?
    var title = ""
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.iNotesArchive, .json] }
    static var writableContentTypes: [UTType] { [.iNotesArchive, .json, .plainText, .data] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension UTType { static var iNotesArchive: UTType { UTType(exportedAs: "io.inotes.archive", conformingTo: .json) } }
extension Notification.Name {
    static let newSheet = Notification.Name("iNotes.newSheet")
    static let newWorkbook = Notification.Name("iNotes.newWorkbook")
    static let focusSearch = Notification.Name("iNotes.focusSearch")
}

struct ContentView: View {
    @EnvironmentObject private var store: NotesStore
    @StateObject private var presentation: EditorPresentation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("workspaceTheme") private var workspaceTheme = "classic"
    @ViewState private var nameRequest: NameRequest?
    @ViewState private var showImporter = false
    @ViewState private var backupFolderDestination: BackupDestination?
    @ViewState private var backupCleanupDestination: BackupDestination?
    @ViewState private var showExporter = false
    @ViewState private var exportDocument = BackupDocument()
    @ViewState private var showSettings = false
    @ViewState private var showRecovery = false
    @ViewState private var showEmptyTrash = false
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all
    @ViewState private var previousColumns: NavigationSplitViewVisibility = .all
    @ViewState private var previousSheetsColumns: NavigationSplitViewVisibility = .all
    @ViewState private var navigationLeadingInset: CGFloat = 0
    @FocusState private var searchFocused: Bool

    @MainActor
    init(presentation: EditorPresentation? = nil) {
        _presentation = StateObject(wrappedValue: presentation ?? EditorPresentation())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 310)
        } content: {
            sheetList.navigationSplitViewColumnWidth(min: 120, ideal: 260, max: 480)
        } detail: {
            // A real, stable container owns navigation chrome. Group forwards
            // its modifiers into the sheet-keyed child and would dismantle the
            // native split observer every time selection changes.
            ZStack {
                if let sheet = store.selectedSheet {
                    SheetDetail(sheetID: sheet.id).id(sheet.id)
                } else {
                    ContentUnavailableView {
                        Label("Room for a new idea", systemImage: "square.and.pencil")
                    } description: {
                        Text("Choose a sheet, or make a new one in a chapter or topic.")
                    } actions: {
                        Button("New sheet", action: newSheet).buttonStyle(.borderedProminent)
                    }
                }
            }
            #if os(macOS)
            .padding(.leading, navigationLeadingInset)
            .background {
                WorkspaceNavigationChrome(fullPage: presentation.fullPage, sheetsVisible: presentation.sheetsVisible,
                    onSheetsVisibilityChange: { presentation.sheetsVisible = $0 },
                    onLeadingInsetChange: { navigationLeadingInset = $0 })
            }
            #endif
        }
        .environmentObject(presentation)
        .tint((WorkspaceTheme(rawValue: workspaceTheme) ?? .classic).accent(isDark: colorScheme == .dark))
        #if !os(macOS)
        .onChange(of: presentation.fullPage) { _, fullPage in
            if fullPage { previousColumns = columnVisibility; columnVisibility = .detailOnly }
            else { columnVisibility = presentation.sheetsVisible ? previousColumns : .detailOnly }
        }
        .onChange(of: presentation.sheetsVisible) { _, visible in
            guard !presentation.fullPage else { return }
            if visible { columnVisibility = previousSheetsColumns == .detailOnly ? .all : previousSheetsColumns }
            else { previousSheetsColumns = columnVisibility; columnVisibility = .detailOnly }
        }
        #endif
        .onChange(of: store.selectedSheet?.id) { _, selectedID in
            if selectedID == nil { presentation.fullPage = false }
        }
        #if os(macOS)
        .toolbar(presentation.fullPage ? .hidden : .visible, for: .windowToolbar)
        #else
        .toolbar(presentation.fullPage ? .hidden : .visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { presentation.toggleSheets() } label: {
                    Label(presentation.sheetsVisible ? "Hide sheets pane" : "Show sheets pane", systemImage: "rectangle.split.3x1")
                }.help(presentation.sheetsVisible ? "Hide sheets pane" : "Show sheets pane")
                AppearanceMenu()
                Menu {
                    Button("New sheet", systemImage: "doc.badge.plus", action: newSheet)
                    if let folder = store.folders.first(where: { $0.id == store.folderID }) {
                        Button(folder.kind == .workbook ? "New chapter" : "New topic", systemImage: "folder.badge.plus") {
                            nameRequest = NameRequest(kind: folder.kind == .workbook ? .chapter : .topic, parent: folder.id)
                        }
                    }
                } label: { Label("Create", systemImage: "plus") }
                .help("Create a sheet or notebook folder")
                Menu {
                    ForEach([BackupDestination.iCloudDrive, .googleDrive]) { destination in
                        Menu {
                            Button(store.backupFolder(for: destination) == nil ? "Connect folder…" : "Change folder…") { chooseBackupFolder(destination) }
                            if store.backupFolder(for: destination) != nil {
                                Button("Back up now") { store.backupNow(to: destination) }
                                Button("Review older backups…") { backupCleanupDestination = destination }
                                Button("Disconnect folder") { store.disconnectBackup(destination) }
                            }
                        } label: { Label(destination.title, systemImage: destination.symbol) }
                    }
                    Divider()
                    Button("Export library backup…") { exportLibrary() }
                    Button("Import library backup…") { backupFolderDestination = nil; showImporter = true }
                    Divider()
                    if store.recoveryAvailable {
                        Button("Recover previous local version…") { showRecovery = true }
                    }
                    Button("About storage & backups") { showSettings = true }
                } label: {
                    Label("Automatic backups", systemImage: BackupDestination.allCases.contains(where: { store.backupFolder(for: $0) != nil }) ? "externaldrive.badge.checkmark" : "externaldrive")
                }
                .help("Library backups and Google Drive")
            }
        }
        .sheet(item: $nameRequest) { request in
            NameDialog(request: request) { title in
                if let id = request.renameID { store.rename(id, to: title) }
                else { store.create(request.kind, title: title, parent: request.parent) }
            }
        }
        .sheet(isPresented: $showSettings) { StorageInfoView() }
        .sheet(item: $backupCleanupDestination) { destination in
            BackupCleanupView(destination: destination)
        }
        .confirmationDialog("Restore the previous local version?", isPresented: $showRecovery, titleVisibility: .visible) {
            Button("Restore Previous Version") { store.recoverPreviousVersion() }
        } message: { Text("The damaged library will be preserved in a separate file before the previous version is restored.") }
        .confirmationDialog("Permanently empty Trash?", isPresented: $showEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { store.emptyTrash() }
        } message: { Text("Deleted folders, sheets, and their attachments will be removed from this library. Keep an exported backup if you might need them.") }
        .alert("iNotes needs your attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: backupFolderDestination == nil ? [.iNotesArchive, .json] : [.folder], allowsMultipleSelection: false) { result in
            defer { backupFolderDestination = nil }
            do {
                guard let url = try result.get().first else { return }
                if let destination = backupFolderDestination {
                    store.rememberBackupFolder(url, for: destination)
                    return
                }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                store.importArchive(try LibraryArchive.read(from: url))
            } catch {
                if (error as NSError).code != NSUserCancelledError { store.errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .iNotesArchive, defaultFilename: "iNotes Backup") { result in
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSheet)) { _ in newSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkbook)) { _ in nameRequest = NameRequest(kind: .workbook) }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            presentation.fullPage = false
            presentation.sheetsVisible = true
            searchFocused = true
        }
    }

    private var sidebarSecondary: AnyShapeStyle {
        (WorkspaceTheme(rawValue: workspaceTheme) ?? .classic).sidebarSecondary(isDark: colorScheme == .dark)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(LibraryFilter.allCases, id: \.self) { filter in
                        Button {
                            store.folderID = nil; store.filter = filter; store.search = ""
                            store.sheetID = store.visibleSheets.first?.id
                        } label: {
                            HStack {
                                Label(filter.rawValue, systemImage: filter == .all ? "square.stack" : filter == .favorites ? "star" : "trash")
                                Spacer()
                                if store.folderID == nil && store.filter == filter { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                }
                Section {
                    ForEach(store.children(nil)) { root in folderRow(root) }
                    Button { nameRequest = NameRequest(kind: .workbook) } label: { Label("New workbook", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(sidebarSecondary).padding(.vertical, 5)
                } header: {
                    Text("NOTEBOOK HIERARCHY").foregroundStyle(sidebarSecondary)
                }
                if store.filter == .trash {
                    Section {
                        ForEach(store.library.nodes.filter { $0.isTrashed && $0.kind != .sheet && (parentIsVisible($0)) }) { node in
                            HStack {
                                Label(node.title, systemImage: node.kind.symbol)
                                Spacer()
                                Button("Restore") { store.restore(node.id) }.buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Deleted folders").foregroundStyle(sidebarSecondary)
                    }
                    Button("Empty Trash…", role: .destructive) { showEmptyTrash = true }
                        .disabled(!store.library.nodes.contains { $0.isTrashed })
                }
            }.listStyle(.sidebar).scrollContentBackground(workspaceTheme == "classic" ? .visible : .hidden)
            VStack(alignment: .leading, spacing: 5) {
                Label(store.saveStatus, systemImage: store.dirty ? "circle.dotted" : "checkmark.circle")
                    .font(.caption).foregroundStyle(store.dirty ? AnyShapeStyle(Color.orange) : sidebarSecondary)
                ForEach(BackupDestination.allCases) { destination in
                    if store.backupFolder(for: destination) != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            if let last = store.lastBackup(for: destination) {
                                Text("\(destination.title): \(last, style: .relative) ago")
                            } else { Text("\(destination.title): backup pending") }
                            Text(store.backupStatus(for: destination)).lineLimit(2)
                        }.font(.caption2).foregroundStyle(sidebarSecondary)
                            .help(store.backupStatus(for: destination))
                    }
                }
                Text("iNotes · local first").font(.caption2)
                    #if os(macOS)
                    .foregroundStyle(workspaceTheme == "classic" ? AnyShapeStyle(.tertiary) : sidebarSecondary)
                    #else
                    .foregroundStyle(.tertiary)
                    #endif
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.background { WorkspaceScenery(readableSidebar: true) }.navigationTitle("iNotes")
    }

    private func parentIsVisible(_ node: NoteNode) -> Bool {
        guard let parent = store.library.node(id: node.parentID ?? UUID()) else { return true }
        return !parent.isTrashed
    }

    private func folderRow(_ node: NoteNode) -> some View {
        FolderTreeRow(node: node, choose: { store.chooseFolder($0) }, request: { nameRequest = $0 })
    }

    private var sheetList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all notes", text: $store.search).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search all notes")
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(12).background(.quaternary.opacity(0.35))
            List(selection: $store.sheetID) {
                ForEach(store.visibleSheets) { sheet in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Text(sheet.displayTitle).font(.headline).lineLimit(2)
                            if sheet.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                if !sheet.title.isEmpty {
                                    Text("Sheet \(store.sheetNumber(sheet.id) ?? 1)")
                                    Text("·")
                                }
                                Text(sheet.createdAt, format: .dateTime.day().month(.abbreviated).year())
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if !sheet.title.isEmpty { Text("Sheet \(store.sheetNumber(sheet.id) ?? 1)") }
                                Text(sheet.createdAt, format: .dateTime.day().month(.abbreviated).year())
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel((sheet.title.isEmpty ? "" : "Sheet \(store.sheetNumber(sheet.id) ?? 1), ") + "Created \(sheet.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        Text(sheet.plainTextExport.isEmpty ? (sheet.images.isEmpty ? (sheet.strokes.isEmpty && sheet.pencilKitData == nil ? "Empty sheet" : "Handwritten notes") : "Image notes") : sheet.plainTextExport.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(store.breadcrumb(sheet.parentID)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background {
                        if workspaceTheme != "classic", store.sheetID != sheet.id {
                            RoundedRectangle(cornerRadius: 10)
                                .fill((WorkspaceTheme(rawValue: workspaceTheme) ?? .classic)
                                    .surface(isDark: colorScheme == .dark).opacity(0.92))
                        }
                    }
                    .contentShape(Rectangle())
                    .tag(sheet.id)
                    .contextMenu {
                        if sheet.isTrashed { Button("Restore sheet") { store.restore(sheet.id) } }
                        else {
                            Button(sheet.isFavorite ? "Remove from favorites" : "Add to favorites") { store.update(sheet.id) { $0.isFavorite.toggle() } }
                            Button("Rename…") { nameRequest = NameRequest(kind: .sheet, renameID: sheet.id, title: sheet.title) }
                            Button("Duplicate") { store.duplicate(sheet.id) }
                            MoveMenu(node: sheet)
                            Divider()
                            Button("Move to Trash", role: .destructive) { store.trash(sheet.id) }
                        }
                    }
                }
            }.listStyle(.inset).scrollContentBackground(workspaceTheme == "classic" ? .visible : .hidden)
            if store.visibleSheets.isEmpty {
                Text(store.filter == .trash ? "Trash is empty" : store.search.isEmpty ? "No sheets here yet" : "No matching notes")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            HStack {
                Text("\(store.visibleSheets.count) sheets").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.filter != .trash { Button(action: newSheet) { Label("New sheet", systemImage: "square.and.pencil") }.labelStyle(.iconOnly).buttonStyle(.plain).help("New sheet (⌘N)") }
            }.padding(12)
        }
        .background { WorkspaceScenery() }
        .navigationTitle(store.search.isEmpty ? (store.library.node(id: store.folderID ?? UUID())?.title ?? store.filter.rawValue) : "Search results")
    }

    private func newSheet() {
        let current = store.folders.first { $0.id == store.folderID }
        let target = (current?.kind == .chapter || current?.kind == .topic) ? current?.id
            : store.folders.first(where: { $0.kind == .chapter && (current == nil || $0.parentID == current?.id) })?.id
        if let target { nameRequest = NameRequest(kind: .sheet, parent: target) }
        else if let workbook = current?.kind == .workbook ? current : store.folders.first(where: { $0.kind == .workbook }) {
            nameRequest = NameRequest(kind: .chapter, parent: workbook.id)
        } else { nameRequest = NameRequest(kind: .workbook) }
    }

    private func exportLibrary() {
        do { exportDocument = BackupDocument(data: try store.archiveData()); showExporter = true }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func chooseBackupFolder(_ destination: BackupDestination) {
        #if os(macOS)
        MacFileActions.chooseBackupFolder(store, destination: destination)
        #else
        backupFolderDestination = destination
        showImporter = true
        #endif
    }
}

struct FolderTreeRow: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("workspaceTheme") private var workspaceTheme = "classic"
    var node: NoteNode
    var choose: (UUID) -> Void
    var request: (NameRequest) -> Void
    @ViewState private var expanded = true

    private var sidebarSecondary: AnyShapeStyle {
        (WorkspaceTheme(rawValue: workspaceTheme) ?? .classic).sidebarSecondary(isDark: colorScheme == .dark)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(store.children(node.id)) { child in
                FolderTreeRow(node: child, choose: choose, request: request)
            }
        } label: {
            HStack(spacing: 4) {
                Button { choose(node.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: node.kind.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title).lineLimit(1).fontWeight(store.folderID == node.id ? .semibold : .regular)
                            Text(node.kind.rawValue.capitalized).font(.caption2).foregroundStyle(sidebarSecondary)
                        }
                        Spacer(minLength: 0)
                    }.foregroundStyle(store.folderID == node.id ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 4)
                    .accessibilityLabel("\(node.kind.rawValue.capitalized): \(node.title)")
                    .contextMenu {
                        Button(node.kind == .workbook ? "New chapter…" : "New topic…") { request(NameRequest(kind: childKind, parent: node.id)) }
                        if node.kind != .workbook { Button("New sheet…") { request(NameRequest(kind: .sheet, parent: node.id)) } }
                        Divider()
                        Button("Rename…") { request(NameRequest(kind: node.kind, renameID: node.id, title: node.title)) }
                        MoveMenu(node: node)
                        Divider()
                        Button("Move to Trash", role: .destructive) { store.trash(node.id) }
                    }
                Button {
                    expanded = true
                    request(NameRequest(kind: childKind, parent: node.id))
                } label: { Image(systemName: "plus.circle").frame(width: 26, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(sidebarSecondary)
                    .help("Add \(childKind.rawValue) to \(node.title)")
                    .accessibilityLabel("Add \(childKind.rawValue) to \(node.title)")
            }
        }
        .onChange(of: store.folderID) { _, selected in reveal(selected) }
        .onChange(of: store.sheetID) { _, selected in reveal(selected) }
        .onChange(of: store.children(node.id).map(\.id)) { previous, current in
            if current.contains(where: { !previous.contains($0) }) { expanded = true }
        }
    }

    private var childKind: NoteKind { node.kind == .workbook ? .chapter : .topic }
    private func reveal(_ selected: UUID?) {
        if let selected, store.isDescendant(selected, of: node.id) { expanded = true }
    }
}

struct MoveMenu: View {
    @EnvironmentObject private var store: NotesStore
    let node: NoteNode
    private var destinations: [NoteNode] {
        store.folders.filter { destination in
            destination.id != node.parentID && !store.isDescendant(destination.id, of: node.id) &&
            (node.kind == .chapter ? destination.kind == .workbook : (node.kind == .sheet || node.kind == .topic) && destination.kind != .workbook)
        }
    }
    var body: some View {
        if node.kind != .workbook {
            Menu("Move to") {
                ForEach(destinations) { folder in
                    Button(store.breadcrumb(folder.id)) { store.move(node.id, to: folder.id) }
                }
                if destinations.isEmpty { Text("No other destinations") }
            }
        }
    }
}

struct NameDialog: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState var request: NameRequest
    var completion: (String) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(request.renameID == nil ? "New \(request.kind.rawValue)" : "Rename \(request.kind.rawValue)", systemImage: request.kind.symbol)
                .font(.title2.weight(.semibold))
            TextField(request.kind == .sheet ? "Title (optional)" : "Name", text: $request.title).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { submit() }
            if request.kind == .sheet {
                Text("Leave the title blank to identify this sheet by its number.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.renameID == nil ? "Create" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled((request.kind != .sheet && request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || request.title.count > 256)
            }
        }.padding(28).frame(minWidth: 340).onAppear { focused = true }
    }
    private func submit() {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (request.kind == .sheet || !title.isEmpty), title.count <= 256 else { return }
        completion(title); dismiss()
    }
}

struct StorageInfoView: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
            Label("Your notes, close to home", systemImage: "externaldrive.badge.checkmark").font(.title2.weight(.semibold))
            Text("iNotes saves automatically on this device. Local saves keep a previous version for recovery. Export a library backup to keep an independent copy.")
            ForEach([BackupDestination.iCloudDrive, .googleDrive]) { destination in
                VStack(alignment: .leading, spacing: 5) {
                    Label("Auto-save to \(destination.title)", systemImage: destination.symbol).font(.headline)
                    Text("Connected folder: \(store.backupFolder(for: destination)?.lastPathComponent ?? "None")")
                    Text(store.backupStatus(for: destination)).foregroundStyle(.secondary)
                }.font(.callout)
            }
            #if os(macOS)
            Text("Use Automatic backups in the toolbar to connect a folder in iCloud Drive or Google Drive for desktop. Automatic backups start after connecting. Google Drive continues independently when iCloud Drive is unavailable.")
            #else
            Text("Use Automatic backups in the toolbar, choose a service, then select its folder in Files. Enable iCloud Drive or the Google Drive Files location first. Automatic backups start after connecting; Google Drive continues independently when iCloud Drive is unavailable. Some providers may ask you to reconnect their folder after restarting.")
            #endif
            Text("After changes, iNotes backs up at most once per minute and on normal quit, skipping identical copies. Automatic backups and Back up now share a rotating history: the latest 5 copies, up to 7 daily and 4 weekly copies, targeting 500 MiB per local library and destination. Older history is removed only after a current copy is verified; the newest two valid copies are kept. Files that cannot be safely removed are kept with a warning and may leave history above this budget. Export a library backup to keep a permanent copy.").font(.callout)
            Text("Backups from earlier versions stay untouched until you select Review older backups in the destination menu. Failed writes retry independently. The provider handles uploads; a successful folder write does not confirm cloud delivery.").font(.callout)
            Text("To transfer notes between devices, import an .inotes backup. Import adds a separate copy with new identifiers. Backups do not merge concurrent edits automatically.").font(.callout)
            Text("Attachments are embedded in the portable archive. The library limit is 64 MiB; individual attachments are limited to 10 MiB. Text and ink share one page. Rich text, paper style, portable pen paths, and native PencilKit data are preserved; advanced PencilKit tools can look different on Mac.").font(.caption).foregroundStyle(.secondary)
            Text("iNotes \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Open source under the MIT license")
                .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(maxWidth: 520, idealHeight: 620)
    }
}

struct BackupCleanupView: View {
    let destination: BackupDestination
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var preview: LegacyBackupPreview?
    @ViewState private var selected = Set<String>()
    @ViewState private var isBusy = false
    @ViewState private var showConfirmation = false
    @ViewState private var errorMessage: String?
    @ViewState private var resultMessage: String?

    private var selectedBytes: Int64 {
        preview?.entries.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.byteCount } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review older backups").font(.title2.weight(.semibold))
            Text("\(destination.title) · \(preview?.folderURL.lastPathComponent ?? store.backupFolder(for: destination)?.lastPathComponent ?? "Backup folder")")
                .font(.headline)
            Text("These copies were made before automatic rotation. They may include manual backups or copies from another device. Select only copies you no longer need. The two newest valid copies are kept for recovery.")
                .font(.callout)
            if isBusy { ProgressView("Checking backups…").controlSize(.small) }
            if let warning = preview?.warning { Text(warning).font(.callout).foregroundStyle(.orange) }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let resultMessage { Text(resultMessage).font(.callout) }
            if let preview {
                if preview.entries.isEmpty {
                    Text("No older backup copies were found. New automatic backups rotate on their own.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(preview.entries) { entry in
                        Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { value in
                            if value && entry.canDelete { selected.insert(entry.id) }
                            else { selected.remove(entry.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
                                }
                                Text(entry.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(entry.fileName)
                                if !entry.canDelete { Text("Kept for recovery").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .disabled(!entry.canDelete || isBusy)
                    }.frame(minHeight: 220, idealHeight: 300)
                    HStack {
                        Button("Select eligible copies") { selected = Set(preview.entries.filter(\.canDelete).map(\.id)) }
                        Button("Clear selection") { selected.removeAll() }
                    }.disabled(isBusy)
                }
            }
            HStack {
                Text("\(selected.count) selected · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
                Button("Delete selected…", role: .destructive) { showConfirmation = true }
                    .disabled(selected.isEmpty || isBusy)
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 640)
        .interactiveDismissDisabled(isBusy)
        .task { await reload() }
        .confirmationDialog("Permanently delete \(selected.count) older backups?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Delete selected backups", role: .destructive) { Task { await removeSelected() } }
        } message: {
            Text("This removes \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)) from the backup folder. Your cloud provider may sync these deletions to other devices. A current backup will be verified first. Your open notes are unchanged.")
        }
    }

    @MainActor private func reload() async {
        isBusy = true
        defer { isBusy = false }
        selected.removeAll()
        preview = nil
        do { preview = try await store.previewOlderBackups(for: destination) }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func removeSelected() async {
        guard let preview, !selected.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        resultMessage = nil
        do {
            let result = try await store.removeOlderBackups(selected, from: preview, destination: destination)
            resultMessage = "Removed \(result.removedCount) older backups (\(ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file)))."
            if let warning = result.warning { errorMessage = warning }
        } catch { errorMessage = error.localizedDescription }
        await reload()
    }
}
