import Foundation

/// A value-only snapshot of export order and safe relative output paths.
/// It never changes note IDs, content, ordering, or archive format.
public struct GroupedExportPlan: Equatable, Sendable {
    public enum Format: String, Sendable { case pdf, zip }

    public struct Bookmark: Equatable, Sendable {
        public let title: String
        /// Zero-based index in this output PDF.
        public let pageIndex: Int
        public let children: [Bookmark]
    }

    public enum Page: Equatable, Sendable {
        case cover(title: String)
        case chapter(number: Int, title: String)
        /// Each topic heading appears on its first active note page, which can
        /// belong to a descendant when the topic has no direct pages.
        case sheet(id: UUID, topicHeadings: [String])
    }

    public struct Document: Equatable, Sendable {
        public let relativePath: [String]
        public let title: String
        public let pages: [Page]
        public let bookmarks: [Bookmark]
        public var sheetIDs: [UUID] {
            pages.compactMap { page in
                guard case let .sheet(id, _) = page else { return nil }
                return id
            }
        }
    }

    public let format: Format
    public let suggestedFilename: String
    public let documents: [Document]
    /// Includes empty active folders in a ZIP. No entry is an absolute path.
    public let directories: [[String]]
    public var sheetCount: Int { documents.reduce(0) { $0 + $1.sheetIDs.count } }
    public var outputPageCount: Int { documents.reduce(0) { $0 + $1.pages.count } }

    public enum PlanningError: Error, LocalizedError, Equatable {
        case notAFolder, noSheets, invalidHierarchy
        public var errorDescription: String? {
            switch self {
            case .notAFolder: return "Choose an active workbook, chapter, or topic to export."
            case .noSheets: return "This selection has no active pages to export."
            case .invalidHierarchy: return "The notebook hierarchy could not be exported safely."
            }
        }
    }

    public static func make(library: NoteLibrary, rootID: UUID, format: Format) throws -> GroupedExportPlan {
        guard library.nodes.count <= 50_000, Set(library.nodes.map(\.id)).count == library.nodes.count else {
            throw PlanningError.invalidHierarchy
        }
        let lookup = Dictionary(uniqueKeysWithValues: library.nodes.map { ($0.id, $0) })
        guard let root = lookup[rootID], root.kind.canContainChildren, !root.isTrashed else { throw PlanningError.notAFolder }
        var ancestor = root.parentID, seenAncestors: Set<UUID> = [rootID]
        while let id = ancestor {
            guard seenAncestors.insert(id).inserted, seenAncestors.count <= 128,
                  let parent = lookup[id], !parent.isTrashed else { throw PlanningError.invalidHierarchy }
            ancestor = parent.parentID
        }
        var children: [UUID: [NoteNode]] = [:]
        for node in library.nodes where !node.isTrashed {
            guard node.createdAt.timeIntervalSince1970.isFinite else { throw PlanningError.invalidHierarchy }
            if let parent = node.parentID { children[parent, default: []].append(node) }
        }
        for id in Array(children.keys) {
            children[id]?.sort(by: NoteLibrary.pageOrder)
        }
        // ZIP paths are virtual entries mapped to flat temporary PDFs. Native
        // filesystem path limits therefore do not flatten deep notebooks.
        var visited = Set<UUID>(), pending: [(UUID, Int)] = [(rootID, 1)]
        while let (id, depth) = pending.popLast() {
            guard visited.insert(id).inserted, depth <= 128 else { throw PlanningError.invalidHierarchy }
            for child in children[id] ?? [] where child.kind.canContainChildren { pending.append((child.id, depth + 1)) }
        }
        let componentLimit = 120
        let rootName = safeComponent(root.title, fallback: root.kind.displayName, maximumBytes: componentLimit)
        var documents: [Document] = [], directories: [[String]] = []

        if format == .pdf {
            let isWorkbook = root.kind == .workbook
            var pages: [Page] = []
            var chapterNumber = 0
            func collect(_ folder: NoteNode, openingTopics: [String]) -> Bookmark? {
                let first = pages.count
                var headings = openingTopics
                if isWorkbook {
                    switch folder.kind {
                    case .workbook:
                        pages.append(.cover(title: folder.displayTitle))
                    case .chapter:
                        chapterNumber += 1
                        pages.append(.chapter(number: chapterNumber, title: folder.displayTitle))
                    case .topic:
                        headings.append(folder.displayTitle)
                    case .sheet: break
                    }
                }
                var marks: [Bookmark] = []
                for sheet in children[folder.id] ?? [] where sheet.kind == .sheet {
                    marks.append(Bookmark(title: sheet.displayTitle, pageIndex: pages.count, children: []))
                    pages.append(.sheet(id: sheet.id, topicHeadings: headings))
                    headings = []
                }
                for child in children[folder.id] ?? [] where child.kind.canContainChildren {
                    if let mark = collect(child, openingTopics: headings) {
                        marks.append(mark)
                        headings = []
                    }
                }
                guard pages.count > first else { return nil }
                return Bookmark(title: folder.displayTitle, pageIndex: first, children: marks)
            }
            guard let outline = collect(root, openingTopics: []) else { throw PlanningError.noSheets }
            documents = [Document(relativePath: [rootName + ".pdf"], title: root.displayTitle,
                                  pages: pages, bookmarks: [outline])]
        } else {
            func collect(_ folder: NoteNode, path: [String]) {
                directories.append(path)
                let sheets = (children[folder.id] ?? []).filter { $0.kind == .sheet }
                let pdfName = path.last! + ".pdf"
                if !sheets.isEmpty {
                    let marks = sheets.enumerated().map { Bookmark(title: $0.element.displayTitle, pageIndex: $0.offset, children: []) }
                    documents.append(Document(relativePath: path + [pdfName], title: folder.displayTitle,
                        pages: sheets.map { .sheet(id: $0.id, topicHeadings: []) },
                        bookmarks: [Bookmark(title: folder.displayTitle, pageIndex: 0, children: marks)]))
                }
                // A topic named "Chapter.pdf" can share a parent with its chapter PDF.
                var names = Set(sheets.isEmpty ? [] : [collisionKey(pdfName)])
                var nextSuffix: [String: Int] = [:]
                for child in children[folder.id] ?? [] where child.kind.canContainChildren {
                    let name = uniqueComponent(child.title, fallback: child.kind.displayName,
                                               maximumBytes: componentLimit, occupied: &names, nextSuffix: &nextSuffix)
                    collect(child, path: path + [name])
                }
            }
            collect(root, path: [rootName])
            guard !documents.isEmpty else { throw PlanningError.noSheets }
        }
        return GroupedExportPlan(format: format,
            suggestedFilename: rootName + (format == .pdf ? ".pdf" : ".zip"), documents: documents, directories: directories)
    }

    private static func safeComponent(_ title: String, fallback: String = "Untitled", maximumBytes: Int) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:<>\"|?*"))
        let scalars = title.precomposedStringWithCanonicalMapping.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        let clean = scalars.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let safeFallback = fallback.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = clean.isEmpty ? (safeFallback.isEmpty ? "Untitled" : safeFallback) : clean
        let limit = max(8, min(120, maximumBytes))
        var result = ""
        for character in base {
            let next = String(character)
            guard result.utf8.count + next.utf8.count <= limit else { break }
            result += next
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if result.isEmpty { result = "Untitled" }
        let stem = result.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        if reserved.contains(stem) {
            result = "_" + result
            while result.utf8.count > limit { result.removeLast() }
        }
        return result
    }

    private static func collisionKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func uniqueComponent(_ title: String, fallback: String, maximumBytes: Int,
                                         occupied: inout Set<String>, nextSuffix: inout [String: Int]) -> String {
        let base = safeComponent(title, fallback: fallback, maximumBytes: maximumBytes)
        let key = collisionKey(base)
        var candidate = base, suffix = nextSuffix[key] ?? 2
        while !occupied.insert(collisionKey(candidate)).inserted {
            let ending = " (\(suffix))"
            candidate = safeComponent(base, maximumBytes: maximumBytes - ending.utf8.count) + ending
            suffix += 1
        }
        nextSuffix[key] = suffix
        return candidate
    }
}
