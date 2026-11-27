#if os(macOS)
import AppKit
import PDFKit
import NotesCore

@MainActor
enum NotebookExportDiagnostics {
    static func run() async throws -> String {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("iNotes-export-check-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        var checks = 0
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "iNotes.ExportChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        var library = NoteLibrary()
        let book = try library.create(kind: .workbook, title: "Workbook")
        let chapter = try library.create(kind: .chapter, title: "Theory", parentID: book)
        let nested = try library.create(kind: .topic, title: "Parsing", parentID: chapter)
        let first = try library.create(kind: .sheet, parentID: chapter)
        let second = try library.create(kind: .sheet, title: "Tokens", parentID: nested)
        var intro = library.node(id: first)!
        intro.body = "Chapter introduction"
        try library.update(intro)
        var annotated = library.node(id: second)!
        annotated.body = "Nested page"
        let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        annotated.images = [PageImage(x: 90, y: 120, width: 96, height: 96, imageData: redPNG)]
        annotated.strokes = [InkStroke(points: [InkPoint(x: 240, y: 200), InkPoint(x: 450, y: 200)],
                                       colorHex: "#0000FF", width: 15)]
        annotated.diagrams = [PageDiagram(y: 1450, text: "Syntax tree")]
        try library.update(annotated)

        let pdf = try GroupedExportPlan.make(library: library, rootID: chapter, format: .pdf)
        let pdfURL = temporary.appendingPathComponent(pdf.suggestedFilename)
        try Data("Previous export".utf8).write(to: pdfURL)
        let pdfSummary = try await GroupedPageExport.write(plan: pdf, library: library, to: pdfURL)
        let document = PDFDocument(url: pdfURL)
        try require(pdfSummary.sheetCount == 2 && document?.pageCount == 2, "Expected one PDF page per notebook page")
        let page1 = document?.page(at: 0), page2 = document?.page(at: 1)
        try require(page1?.string?.contains("Chapter introduction") == true && page2?.string?.contains("Nested page") == true,
                    "Pages must carry their original searchable content in notebook order")
        try require(page2?.string?.contains("Syntax tree") == true && (page2?.bounds(for: .mediaBox).height ?? 0) > 1450,
                    "A tall notebook page must keep the diagram at its bottom on the same PDF page")
        if let pdfPage = page2?.pageRef {
            let width = 320, height = 440
            let surface = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            surface.concatenate(pdfPage.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                            rotate: 0, preserveAspectRatio: true))
            surface.drawPDFPage(pdfPage)
            let pixels = surface.data!.assumingMemoryBound(to: UInt8.self)
            var red = 0, blue = 0
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                if pixels[i] > 180 && pixels[i+1] < 80 && pixels[i+2] < 80 { red += 1 }
                if pixels[i] < 80 && pixels[i+1] < 80 && pixels[i+2] > 180 { blue += 1 }
            }
            try require(red > 20 && blue > 20, "The grouped PDF must retain the pasted red image and blue ink")
        } else { try require(false, "Missing rendered PDF page") }
        func bookmark(_ title: String, in node: PDFOutline?) -> PDFOutline? {
            guard let node else { return nil }
            if node.label == title { return node }
            for index in 0..<node.numberOfChildren {
                if let found = bookmark(title, in: node.child(at: index)) { return found }
            }
            return nil
        }
        let topic = bookmark("Parsing", in: document?.outlineRoot)
        try require(bookmark("Page 1", in: document?.outlineRoot)?.destination?.page === page1,
                    "An untitled notebook page must have its numbered Page bookmark in the exported PDF")
        try require(topic != nil && topic?.destination?.page === page2 && bookmark("Tokens", in: topic)?.destination?.page === page2,
                    "Nested topic and page bookmarks must open their actual PDF page")

        let zip = try GroupedExportPlan.make(library: library, rootID: book, format: .zip)
        let zipURL = temporary.appendingPathComponent(zip.suggestedFilename)
        let result = try await GroupedPageExport.write(plan: zip, library: library, to: zipURL)
        try require(result.documentCount == 2 && result.sheetCount == 2 && result.bytesWritten > 0, "Workbook ZIP totals")
        let unpacked = temporary.appendingPathComponent("unpacked")
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", zipURL.path, unpacked.path]
        try extract.run()
        extract.waitUntilExit()
        try require(extract.terminationStatus == 0, "The saved workbook must be a readable ZIP")
        let files = try fm.subpathsOfDirectory(atPath: unpacked.path).filter { $0.hasSuffix(".pdf") }.sorted()
        let chapterPath = "Workbook/Theory/Theory.pdf"
        let topicPath = "Workbook/Theory/Parsing/Parsing.pdf"
        try require(files == [topicPath, chapterPath].sorted(), "Each folder must contain its own PDF at the expected path: \(files)")
        for (path, content) in [(chapterPath, "Chapter introduction"), (topicPath, "Syntax tree")] {
            let part = PDFDocument(url: unpacked.appendingPathComponent(path))
            try require(part?.pageCount == 1 && part?.string?.contains(content) == true, "Incorrect PDF in ZIP at \(path)")
        }

        try library.rename(id: book, title: "Compiler Design")
        try library.rename(id: chapter, title: "Syntax Analysis")
        let parentTopic = try library.create(kind: .topic, title: "Top-down Parsing", parentID: nested)
        let subtopic = try library.create(kind: .topic, title: "Predictive Parsing", parentID: parentTopic)
        func addNote(_ title: String, body: String, in folder: UUID) throws {
            let id = try library.create(kind: .sheet, title: title, parentID: folder)
            var node = library.node(id: id)!
            node.body = body
            try library.update(node)
        }
        try addNote("Lookahead", body: "Choose a production with one lookahead token.", in: subtopic)
        try addNote("Follow sets", body: "A follow set describes what may come next.", in: subtopic)
        let chapterTwo = try library.create(kind: .chapter, title: "Optimization", parentID: book)
        try addNote("Constants", body: "Fold constant expressions before code generation.", in: chapterTwo)
        _ = try library.create(kind: .chapter, title: "Code Generation", parentID: book)

        let workbookPlan = try GroupedExportPlan.make(library: library, rootID: book, format: .pdf)
        let workbookURL = temporary.appendingPathComponent(workbookPlan.suggestedFilename)
        var completedPages: [Int] = []
        let workbookSummary = try await GroupedPageExport.write(plan: workbookPlan, library: library, to: workbookURL, progress: {
            completedPages.append($0.completedPages)
        })
        guard let workbookPDF = PDFDocument(url: workbookURL) else { throw GroupedPageExport.ExportError.renderingFailed }
        try require(workbookPlan.suggestedFilename == "Compiler Design.pdf" && workbookPDF.pageCount == 9
                    && workbookSummary.documentCount == 1 && workbookSummary.sheetCount == 5,
                    "Expected a workbook cover, three chapter dividers and five original pages")
        try require(completedPages == Array(0...9), "Workbook progress should include each generated PDF page")
        func contains(_ index: Int, _ value: String) -> Bool {
            workbookPDF.page(at: index)?.string?.localizedCaseInsensitiveContains(value) == true
        }
        try require(contains(0, "Compiler Design") && !contains(0, "Chapter 1"), "The cover must carry the workbook title")
        for (index, sequence, title) in [(1, 1, "Syntax Analysis"), (6, 2, "Optimization"), (8, 3, "Code Generation")] {
            try require(contains(index, "Chapter \(sequence)") && contains(index, title),
                        "Expected numbered chapter divider for \(title)")
        }
        try require(contains(2, "Chapter introduction") && contains(3, "Nested page") && contains(3, "Syntax tree")
                    && contains(4, "one lookahead token") && contains(5, "what may come next")
                    && contains(7, "Fold constant expressions"), "Workbook notes lost searchable content or changed order")
        func textBounds(_ text: String, on page: PDFPage) -> CGRect? {
            workbookPDF.findString(text, withOptions: [.caseInsensitive])
                .first(where: { $0.pages.first === page })?.bounds(for: page)
        }
        guard let firstTopicPage = workbookPDF.page(at: 3), let firstSubtopicPage = workbookPDF.page(at: 4),
              let header = textBounds("Parsing", on: firstTopicPage), let body = textBounds("Nested page", on: firstTopicPage),
              let ancestorHeader = textBounds("Top-down Parsing", on: firstSubtopicPage),
              let subHeader = textBounds("Predictive Parsing", on: firstSubtopicPage),
              let subBody = textBounds("Choose a production", on: firstSubtopicPage) else {
            throw NSError(domain: "iNotes.ExportChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing workbook topic headings or page text"])
        }
        try require(header.minY >= body.maxY && min(ancestorHeader.minY, subHeader.minY) >= subBody.maxY,
                    "Topic headings must sit above the original note content")
        try require(!contains(5, "Predictive Parsing") && !contains(5, "Top-down Parsing"),
                    "A topic heading belongs only on the topic's first note")
        let annotatedBounds = firstTopicPage.bounds(for: .mediaBox)
        try require(annotatedBounds.width == page2?.bounds(for: .mediaBox).width
                    && annotatedBounds.height > (page2?.bounds(for: .mediaBox).height ?? .infinity),
                    "Adding a topic heading must preserve note width and provide extra vertical space")
        let workbookMarks = workbookPDF.outlineRoot
        try require(bookmark("Compiler Design", in: workbookMarks)?.destination?.page === workbookPDF.page(at: 0)
                    && bookmark("Optimization", in: workbookMarks)?.destination?.page === workbookPDF.page(at: 6)
                    && bookmark("Predictive Parsing", in: workbookMarks)?.destination?.page === firstSubtopicPage
                    && bookmark("Follow sets", in: workbookMarks)?.destination?.page === workbookPDF.page(at: 5),
                    "Workbook bookmarks must land on their cover, divider or original page")
        let savedBook = try Data(contentsOf: workbookURL)
        var stopAfterCover = false
        do {
            _ = try await GroupedPageExport.write(plan: workbookPlan, library: library, to: workbookURL,
                                                  shouldCancel: { stopAfterCover }, progress: { stopAfterCover = $0.completedPages == 1 })
            try require(false, "Workbook cancellation after the cover did not stop export")
        } catch is CancellationError {}
        try require(try Data(contentsOf: workbookURL) == savedBook, "Canceling a workbook PDF export must preserve the existing file")

        let original = try Data(contentsOf: zipURL)
        let originalEntries = try fm.contentsOfDirectory(atPath: temporary.path).sorted()
        var cancel = false
        do {
            _ = try await GroupedPageExport.write(plan: zip, library: library, to: zipURL,
                                                  shouldCancel: { cancel }, progress: { cancel = $0.completedPages >= 1 })
            try require(false, "A canceled export replaced the output")
        } catch is CancellationError {}
        try require(try Data(contentsOf: zipURL) == original, "Cancellation must preserve an existing destination")
        try require(try fm.contentsOfDirectory(atPath: temporary.path).sorted() == originalEntries, "Cancellation left staged files behind")
        return "\(checks) notebook PDF and ZIP checks passed"
    }
}
#endif
