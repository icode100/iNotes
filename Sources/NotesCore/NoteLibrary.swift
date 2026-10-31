import Foundation

public struct NoteLibrary: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 2
    public var formatVersion: Int
    public private(set) var nodes: [NoteNode]
    public private(set) var modifiedAt: Date

    public init(nodes: [NoteNode] = [], modifiedAt: Date = Date(), formatVersion: Int = currentFormatVersion) {
        self.formatVersion = formatVersion; self.nodes = nodes; self.modifiedAt = modifiedAt
    }

    public func node(id: UUID) -> NoteNode? { nodes.first { $0.id == id } }

    public func children(of parentID: UUID?, includingTrash: Bool = false) -> [NoteNode] {
        nodes.filter { $0.parentID == parentID && (includingTrash || !$0.isTrashed) }
            .sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
    }

    public var roots: [NoteNode] { children(of: nil) }

    public func path(to id: UUID) -> [NoteNode] {
        var path: [NoteNode] = [], cursor = node(id: id), visited = Set<UUID>()
        while let item = cursor, visited.insert(item.id).inserted {
            path.insert(item, at: 0)
            cursor = item.parentID.flatMap { node(id: $0) }
        }
        return path
    }

    public func descendants(of id: UUID) -> [NoteNode] {
        var ids: Set<UUID> = [id], result: [NoteNode] = []
        var frontier: [UUID] = [id]
        while let parentID = frontier.popLast() {
            for child in children(of: parentID, includingTrash: true) where ids.insert(child.id).inserted {
                result.append(child); frontier.append(child.id)
            }
        }
        return result
    }

    @discardableResult
    public mutating func create(kind: NoteKind, title: String, parentID: UUID? = nil) throws -> UUID {
        let clean = try Self.cleanTitle(title)
        try validateParent(kind: kind, parentID: parentID)
        guard nodes.count < 50_000 else { throw LibraryError.invalidData("Too many items.") }
        if let parentID, path(to: parentID).count >= 128 {
            throw LibraryError.invalidData("Topics are nested more than 128 levels deep.")
        }
        let nextOrder = try nextOrder(in: parentID)
        let node = NoteNode(parentID: parentID, kind: kind, title: clean, order: nextOrder)
        nodes.append(node); touch(); return node.id
    }

    public mutating func rename(id: UUID, title: String) throws {
        let title = try Self.cleanTitle(title)
        try mutate(id) { $0.title = title }
    }

    public mutating func update(_ node: NoteNode) throws {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { throw LibraryError.nodeNotFound }
        guard (1...Self.currentFormatVersion).contains(formatVersion) else { throw LibraryError.unsupportedVersion(formatVersion) }
        let previous = nodes[index]
        var candidate = self
        var replacement = node
        replacement.title = try Self.cleanTitle(replacement.title)
        replacement.updatedAt = Date()
        candidate.nodes[index] = replacement
        if !replacement.textBoxes.isEmpty || !replacement.equations.isEmpty { candidate.formatVersion = Self.currentFormatVersion }
        if previous.parentID == replacement.parentID, previous.kind == replacement.kind,
           previous.isTrashed == replacement.isTrashed, previous.order == replacement.order {
            // Existing structure is unchanged. Avoid scanning every other sheet's ink on each keypress.
            try Self.validatePayload(replacement, previous: previous)
        } else {
            try candidate.validate()
        }
        candidate.touch(); self = candidate
    }

    public mutating func move(id: UUID, to parentID: UUID?, at order: Int? = nil) throws {
        guard let node = node(id: id) else { throw LibraryError.nodeNotFound }
        if parentID == id || descendants(of: id).contains(where: { $0.id == parentID }) { throw LibraryError.cycle }
        try validateParent(kind: node.kind, parentID: parentID)
        let siblings = children(of: parentID, includingTrash: true).filter { $0.id != id }
        let destination = max(0, min(order ?? siblings.count, siblings.count))
        var sorted = siblings.map(\.id)
        sorted.insert(id, at: destination)
        var candidate = self
        try candidate.mutate(id) { $0.parentID = parentID }
        for (position, siblingID) in sorted.enumerated() {
            if let index = candidate.nodes.firstIndex(where: { $0.id == siblingID }) { candidate.nodes[index].order = position }
        }
        try candidate.validate(); self = candidate
    }

    @discardableResult
    public mutating func duplicate(id: UUID) throws -> UUID {
        guard let original = node(id: id), !original.isTrashed else { throw LibraryError.nodeNotFound }
        let originals = [original] + descendants(of: id).filter { !$0.isTrashed }
        guard nodes.count + originals.count <= 50_000 else { throw LibraryError.invalidData("Too many items.") }
        let mapping = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        let now = Date()
        var candidate = self
        let copyOrder = try nextOrder(in: original.parentID)
        for var item in originals {
            let oldID = item.id
            item.id = mapping[oldID]!
            item.parentID = item.parentID.flatMap { mapping[$0] ?? $0 }
            item.createdAt = now; item.updatedAt = now
            if oldID == id {
                item.title = String(item.title.prefix(249)) + " (copy)"
                item.order = copyOrder
            }
            // Attachment/stroke IDs are local to a sheet, so their bytes need no rewriting.
            candidate.nodes.append(item)
        }
        candidate.touch()
        _ = try LibraryArchive.encode(candidate)
        self = candidate
        return mapping[id]!
    }

    public mutating func trash(id: UUID) throws {
        guard node(id: id) != nil else { throw LibraryError.nodeNotFound }
        let ids = Set([id] + descendants(of: id).map(\.id))
        let now = Date()
        for index in nodes.indices where ids.contains(nodes[index].id) {
            nodes[index].isTrashed = true; nodes[index].updatedAt = now
        }
        touch()
    }

    public mutating func restore(id: UUID) throws {
        guard node(id: id) != nil else { throw LibraryError.nodeNotFound }
        let ids = Set(path(to: id).map(\.id) + descendants(of: id).map(\.id))
        let now = Date()
        for index in nodes.indices where ids.contains(nodes[index].id) {
            nodes[index].isTrashed = false; nodes[index].updatedAt = now
        }
        touch()
    }

    public mutating func permanentlyDelete(id: UUID) throws {
        guard let existing = node(id: id), existing.isTrashed else { throw LibraryError.invalidData("Only items in Trash can be permanently deleted.") }
        let ids = Set([id] + descendants(of: id).map(\.id))
        nodes.removeAll { ids.contains($0.id) }; touch()
    }

    public mutating func emptyTrash() {
        nodes.removeAll { $0.isTrashed }; touch()
    }

    /// Imports a separate copy. Existing identifiers and notes are never overwritten.
    @discardableResult
    public mutating func merge(_ incoming: NoteLibrary) throws -> [UUID] {
        try incoming.validate()
        guard nodes.count + incoming.nodes.count <= 50_000 else { throw LibraryError.invalidData("Too many items.") }
        let mapping = Dictionary(uniqueKeysWithValues: incoming.nodes.map { ($0.id, UUID()) })
        let rootOffset = try nextOrder(in: nil)
        var imported: [NoteNode] = []
        for var item in incoming.nodes {
            item.id = mapping[item.id]!
            if let oldParent = item.parentID { item.parentID = mapping[oldParent]! }
            else {
                let (order, overflow) = item.order.addingReportingOverflow(rootOffset)
                guard !overflow else { throw LibraryError.invalidData("An imported item has an invalid position.") }
                item.order = order
            }
            imported.append(item)
        }
        let roots = imported.filter { $0.parentID == nil }.map(\.id)
        var candidate = self
        candidate.formatVersion = max(formatVersion, incoming.formatVersion)
        candidate.nodes.append(contentsOf: imported); candidate.touch()
        _ = try LibraryArchive.encode(candidate)
        self = candidate
        return roots
    }

    public func search(_ query: String, favoritesOnly: Bool = false, includingTrash: Bool = false) -> [NoteNode] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { String($0) }
        return nodes.filter { item in
            guard includingTrash || !item.isTrashed, !favoritesOnly || item.isFavorite else { return false }
            let haystack = ([item.title, item.body] + item.tags + item.textBoxes.map(\.text) + item.equations.map(\.latex)).joined(separator: "\n")
            return tokens.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func validate() throws {
        guard (1...Self.currentFormatVersion).contains(formatVersion) else { throw LibraryError.unsupportedVersion(formatVersion) }
        if formatVersion == 1, nodes.contains(where: { !$0.textBoxes.isEmpty || !$0.equations.isEmpty }) {
            throw LibraryError.invalidData("Movable text and equations require archive format 2.")
        }
        guard nodes.count <= 50_000 else { throw LibraryError.invalidData("Too many items.") }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw LibraryError.duplicateID }
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var ancestorDepths: [UUID: Int] = [:]
        for node in nodes {
            try Self.validatePayload(node)
            if node.kind == .workbook {
                guard node.parentID == nil else { throw LibraryError.invalidParent }
            } else {
                guard let parentID = node.parentID, let parent = lookup[parentID] else { throw LibraryError.invalidParent }
                switch node.kind {
                case .workbook: break
                case .chapter: guard parent.kind == .workbook else { throw LibraryError.invalidParent }
                case .topic, .sheet: guard parent.kind == .chapter || parent.kind == .topic else { throw LibraryError.invalidParent }
                }
            }
            if !node.isTrashed, let parentID = node.parentID, lookup[parentID]?.isTrashed == true {
                throw LibraryError.invalidData("A visible item has a trashed parent.")
            }
            var visited = Set<UUID>(), chain: [UUID] = [], cursor: UUID? = node.id
            while let id = cursor, ancestorDepths[id] == nil {
                guard visited.insert(id).inserted else { throw LibraryError.cycle }
                chain.append(id)
                cursor = lookup[id]?.parentID
            }
            var depth = cursor.flatMap { ancestorDepths[$0] } ?? 0
            for id in chain.reversed() {
                depth += 1
                guard depth <= 128 else { throw LibraryError.invalidData("Topics are nested more than 128 levels deep.") }
                ancestorDepths[id] = depth
            }
        }
    }

    public static func sample() -> NoteLibrary {
        var library = NoteLibrary()
        let workbook = try! library.create(kind: .workbook, title: "My Notebook")
        let chapter = try! library.create(kind: .chapter, title: "Getting started", parentID: workbook)
        let page = try! library.create(kind: .sheet, title: "Welcome to iNotes", parentID: chapter)
        var note = library.node(id: page)!
        note.body = "A quiet place for your ideas.\n\nOrganize workbooks into chapters, nested topics, and sheets. Write, sketch, attach files, and find everything with search.\n\nYour notes save automatically on this Mac. Connect a Google Drive folder to keep portable backups.\n\nTry creating a chapter for a project or course, then add a sheet to start writing."
        note.tags = ["welcome"]
        try! library.update(note)
        return library
    }

    private static func cleanTitle(_ title: String) throws -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 256 else { throw LibraryError.invalidTitle }
        return clean
    }

    private static func validatePayload(_ node: NoteNode, previous: NoteNode? = nil) throws {
        _ = try cleanTitle(node.title)
        if previous?.textBoxes != node.textBoxes {
            guard node.textBoxes.count <= 10_000,
                  Set(node.textBoxes.map(\.id)).count == node.textBoxes.count else { throw LibraryError.duplicateID }
            guard node.textBoxes.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite
                && (0...100_000).contains($0.x) && (0...100_000).contains($0.y)
                && (20...10_000).contains($0.width) && $0.text.utf8.count <= LibraryArchive.maximumBytes }) else {
                throw LibraryError.invalidData("A text box has invalid coordinates or content.")
            }
        }
        if previous?.equations != node.equations {
            guard node.equations.count <= 10_000,
                  Set(node.equations.map(\.id)).count == node.equations.count else { throw LibraryError.duplicateID }
            guard node.equations.allSatisfy({ !$0.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.latex.count <= NoteEquation.maximumSourceLength && $0.x.isFinite && $0.y.isFinite
                && $0.width.isFinite && $0.height.isFinite && $0.fontSize.isFinite
                && (0...100_000).contains($0.x) && (0...100_000).contains($0.y)
                && (20...10_000).contains($0.width) && (20...10_000).contains($0.height)
                && (8...120).contains($0.fontSize) }) else {
                throw LibraryError.invalidData("An equation has invalid source, coordinates, or font size.")
            }
        }
        if previous?.strokes != node.strokes {
            for stroke in node.strokes {
                guard stroke.width.isFinite, stroke.width > 0, stroke.width <= 100,
                      stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.pressure.isFinite && (0...1).contains($0.pressure) }) else {
                    throw LibraryError.invalidData("A drawing contains invalid coordinates or pressure.")
                }
            }
        }
        guard node.createdAt.timeIntervalSince1970.isFinite, node.updatedAt.timeIntervalSince1970.isFinite else {
            throw LibraryError.invalidData("Invalid note date.")
        }
        if previous?.attachments != node.attachments {
            guard Set(node.attachments.map(\.id)).count == node.attachments.count else { throw LibraryError.duplicateID }
            guard node.attachments.allSatisfy({ !$0.filename.isEmpty && $0.filename.count <= 1024 && !$0.filename.contains("/") && !$0.filename.contains("\\") && $0.filename != "." && $0.filename != ".." }) else {
                throw LibraryError.invalidData("An attachment filename is invalid.")
            }
        }
    }

    private func validateParent(kind: NoteKind, parentID: UUID?, allowTrashed: Bool = false) throws {
        if kind == .workbook {
            guard parentID == nil else { throw LibraryError.invalidParent }; return
        }
        guard let parentID, let parent = node(id: parentID), allowTrashed || !parent.isTrashed else { throw LibraryError.invalidParent }
        switch kind {
        case .workbook: break
        case .chapter: guard parent.kind == .workbook else { throw LibraryError.invalidParent }
        case .topic, .sheet: guard parent.kind == .chapter || parent.kind == .topic else { throw LibraryError.invalidParent }
        }
    }

    private mutating func mutate(_ id: UUID, _ body: (inout NoteNode) -> Void) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw LibraryError.nodeNotFound }
        body(&nodes[index]); nodes[index].updatedAt = Date(); touch()
    }

    private mutating func touch() { modifiedAt = Date() }

    private func nextOrder(in parentID: UUID?) throws -> Int {
        let (next, overflow) = (children(of: parentID, includingTrash: true).map(\.order).max() ?? -1).addingReportingOverflow(1)
        guard !overflow else { throw LibraryError.invalidData("An item has an invalid position. Move it to reset its position.") }
        return next
    }
}
