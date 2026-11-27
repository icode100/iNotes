#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import NotesCore

/// Produces files without retaining a PDFDocument containing the whole book.
/// Every native sheet renderer and source PDF is released before the next page.
@MainActor
enum GroupedPageExport {
    struct Progress {
        let completedPages: Int
        let totalPages: Int
        let currentTitle: String
    }
    struct Summary {
        let documentCount: Int
        let sheetCount: Int
        let bytesWritten: Int64
    }
    enum ExportError: Error, LocalizedError {
        case invalidPlan, renderingFailed, archiveFailed(String), destinationUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidPlan: return "The selected notebook changed. Start the export again."
            case .renderingFailed: return "A page could not be rendered as PDF. Your destination has not been changed."
            case .archiveFailed(let detail): return "The ZIP could not be created. \(detail)"
            case .destinationUnavailable: return "The export destination is unavailable."
            }
        }
    }
    static func write(plan: GroupedExportPlan, library: NoteLibrary, to destination: URL,
                      theme: PageTheme = .light, shouldCancel: () -> Bool = { false },
                      progress: (Progress) -> Void = { _ in }) async throws -> Summary {
        try checkCancellation(shouldCancel)
        let totalPages = plan.outputPageCount
        guard destination.isFileURL, totalPages > 0, !plan.documents.isEmpty,
              plan.format != .pdf || plan.documents.count == 1 else { throw ExportError.invalidPlan }
        try library.validate()
        let scopedAccess = destination.startAccessingSecurityScopedResource()
        defer { if scopedAccess { destination.stopAccessingSecurityScopedResource() } }
        let lookup = Dictionary(uniqueKeysWithValues: library.nodes.map { ($0.id, $0) })
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("iNotes-export-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        var completed = 0
        var files: [(GroupedExportPlan.Document, URL)] = []
        progress(Progress(completedPages: 0, totalPages: totalPages, currentTitle: "Preparing export"))
        for (index, document) in plan.documents.enumerated() {
            try checkCancellation(shouldCancel)
            // Only short generated names touch the native filesystem. The ZIP
            // maps these files to the full logical hierarchy through mtree.
            let url = staging.appendingPathComponent("document-\(index).pdf")
            let info = [kCGPDFContextTitle as String: document.title,
                        kCGPDFContextCreator as String: "iNotes"] as CFDictionary
            guard let context = CGContext(url as CFURL, mediaBox: nil, info) else { throw ExportError.renderingFailed }
            var closed = false
            defer { if !closed { context.closePDF() } }
            for plannedPage in document.pages {
                try checkCancellation(shouldCancel)
                let title = try autoreleasepool {
                    switch plannedPage {
                    case let .cover(title):
                        try WorkbookPDFPage.drawTitle(title, chapterNumber: nil, into: context)
                        return title
                    case let .chapter(number, title):
                        try WorkbookPDFPage.drawTitle(title, chapterNumber: number, into: context)
                        return title
                    case let .sheet(id, topicHeadings):
                        guard let sheet = lookup[id], sheet.kind == .sheet, !sheet.isTrashed else {
                            throw ExportError.invalidPlan
                        }
                        try drawNote(sheet, topicHeadings: topicHeadings, theme: theme, into: context)
                        return sheet.displayTitle
                    }
                }
                completed += 1
                progress(Progress(completedPages: completed, totalPages: totalPages, currentTitle: title))
                // Permit native progress/cancel controls between bounded pages.
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            func outline(_ mark: GroupedExportPlan.Bookmark) -> [String: Any] {
                var value: [String: Any] = [kCGPDFOutlineTitle as String: mark.title,
                                           kCGPDFOutlineDestination as String: mark.pageIndex + 1]
                if !mark.children.isEmpty { value[kCGPDFOutlineChildren as String] = mark.children.map(outline) }
                return value
            }
            CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: document.bookmarks.map(outline)] as CFDictionary)
            context.closePDF(); closed = true
            // Core Graphics' URL consumer does not throw write errors. Check
            // the completed file before it can enter a ZIP or replace a target.
            let readbackValid = autoreleasepool {
                CGPDFDocument(url as CFURL)?.numberOfPages == document.pages.count
            }
            guard readbackValid else { throw ExportError.renderingFailed }
            files.append((document, url))
        }
        try checkCancellation(shouldCancel)
        let artifact: URL
        if plan.format == .pdf { artifact = files[0].1 }
        else {
            let manifest = staging.appendingPathComponent("entries.mtree")
            try await writeManifest(plan: plan, files: files, to: manifest, shouldCancel: shouldCancel)
            artifact = staging.appendingPathComponent("notebook.zip")
            try await compress(manifest: manifest, output: artifact, staging: staging, shouldCancel: shouldCancel)
        }
        let size = try artifact.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ExportError.renderingFailed }
        try await installAtomically(artifact, at: destination, shouldCancel: shouldCancel)
        return Summary(documentCount: files.count, sheetCount: plan.sheetCount, bytesWritten: Int64(size))
    }

    private static func drawNote(_ sheet: NoteNode, topicHeadings: [String], theme: PageTheme,
                                 into context: CGContext) throws {
        let data = UnifiedPageExport.pdf(text: sheet.body, rtfData: sheet.richTextRTF, strokes: sheet.strokes,
            paper: InkPaper(rawValue: sheet.paperStyle.rawValue) ?? .dotted, theme: theme,
            pageTemplate: sheet.pageTemplate, templateLinePattern: sheet.templateLinePattern,
            textBoxes: sheet.textBoxes, equations: sheet.equations, images: sheet.images, diagrams: sheet.diagrams)
        guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider),
              source.numberOfPages == 1, let page = source.page(at: 1) else { throw ExportError.renderingFailed }
        let box = page.getBoxRect(.mediaBox)
        guard !box.isNull, !box.isInfinite, box.width > 0, box.height > 0,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width <= InkGeometryLimits.maximumPageDimension,
              box.height <= InkGeometryLimits.maximumPageDimension else { throw ExportError.renderingFailed }

        let header = try WorkbookPDFPage.TopicHeader(titles: topicHeadings, paperWidth: box.width)
        var output = box
        output.size.height += header?.height ?? 0
        WorkbookPDFPage.begin(in: context, bounds: output)
        header?.draw(above: box, into: context)
        context.saveGState()
        context.clip(to: box)
        context.drawPDFPage(page)
        context.restoreGState()
        context.endPDFPage()
    }

    private static func checkCancellation(_ shouldCancel: () -> Bool) throws {
        if Task.isCancelled || shouldCancel() { throw CancellationError() }
    }

    private static func writeManifest(plan: GroupedExportPlan, files: [(GroupedExportPlan.Document, URL)],
                                      to url: URL, shouldCancel: () -> Bool) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ExportError.destinationUnavailable
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("#mtree\n".utf8))
        for (index, path) in plan.directories.enumerated() {
            try checkCancellation(shouldCancel)
            try handle.write(contentsOf: Data(("./" + mtreeEscape(path.joined(separator: "/")) + " type=dir mode=0755\n").utf8))
            if index % 64 == 0 { await Task.yield() }
        }
        for (document, source) in files {
            try checkCancellation(shouldCancel)
            let line = "./" + mtreeEscape(document.relativePath.joined(separator: "/"))
                + " type=file mode=0644 contents=" + mtreeEscape(source.path) + "\n"
            try handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func mtreeEscape(_ value: String) -> String {
        value.utf8.map { byte in
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || [45, 46, 47, 95].contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "\\%03o", Int(byte))
        }.joined()
    }

    private static func compress(manifest: URL, output: URL, staging: URL,
                                 shouldCancel: () -> Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", output.path, "--format", "zip", "@" + manifest.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                               "COPYFILE_DISABLE": "1", "TMPDIR": staging.path]
        process.standardOutput = FileHandle.nullDevice
        let errorURL = staging.appendingPathComponent("archive-error.log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        process.standardError = errors
        try process.run()
        var cancellation: Error?
        var terminatedAt: TimeInterval?
        while process.isRunning {
            if cancellation == nil, Task.isCancelled || shouldCancel() {
                cancellation = CancellationError()
                terminatedAt = ProcessInfo.processInfo.systemUptime
                process.terminate()
            }
            if let terminatedAt, ProcessInfo.processInfo.systemUptime - terminatedAt > 1 {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            // Cancellation must still wait for the writer to exit before the
            // staging directory is removed. This pause is not Task-cancellable.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
            }
        }
        if let cancellation { throw cancellation }
        try checkCancellation(shouldCancel)
        guard process.terminationStatus == 0 else {
            let read = try FileHandle(forReadingFrom: errorURL)
            defer { try? read.close() }
            let detail = String(data: (try? read.read(upToCount: 4_096)) ?? Data(), encoding: .utf8) ?? ""
            throw ExportError.archiveFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func installAtomically(_ source: URL, at destination: URL,
                                          shouldCancel: () -> Bool) async throws {
        try checkCancellation(shouldCancel)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".iNotes-export-\(UUID()).partial")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? output.close()
            try? manager.removeItem(at: temporary)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try checkCancellation(shouldCancel)
            try output.write(contentsOf: data)
            await Task.yield()
        }
        try output.synchronize(); try output.close()
        try checkCancellation(shouldCancel)
        var coordinationError: NSError?
        var writeError: Error?
        var installed = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                try checkCancellation(shouldCancel)
                // The source is a fresh sibling on the destination volume.
                // rename replaces a file/link atomically; it never follows the
                // old destination into another file or exposes a partial PDF.
                guard Darwin.rename(temporary.path, coordinated.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                installed = true
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard installed else { throw ExportError.destinationUnavailable }
    }
}
#endif
