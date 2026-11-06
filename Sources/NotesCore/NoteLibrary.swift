import Foundation

public struct NoteLibrary: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 4
    public var formatVersion: Int
    public private(set) var nodes: [NoteNode]
    public private(set) var modifiedAt: Date

    // Keep new notebooks readable by previous releases until newer objects are added.
    public init(nodes: [NoteNode] = [], modifiedAt: Date = Date(), formatVersion: Int = 2) {
        self.formatVersion = formatVersion; self.nodes = nodes; self.modifiedAt = modifiedAt
        // Invalid programmatically constructed libraries remain available to validate(), which
        // reports their error. Never discard nodes if their numbering cannot be migrated.
        var migrated = self
        if (try? migrated.migrateLegacySheetNumbers()) != nil { self = migrated }
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, nodes, modifiedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        nodes = try values.decode([NoteNode].self, forKey: .nodes)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        try migrateLegacySheetNumbers()
    }

    public func node(id: UUID) -> NoteNode? { nodes.first { $0.id == id } }

    public func children(of parentID: UUID?, includingTrash: Bool = false) -> [NoteNode] {
        nodes.filter { $0.parentID == parentID && (includingTrash || !$0.isTrashed) }
            .sorted(by: Self.pageOrder)
    }

    public var roots: [NoteNode] { children(of: nil) }

    /// Includes the root and trashed descendants; callers apply their own view filters.
    /// Build one adjacency index per query so accepted deep, leaf-first archives
    /// cost O(nodes + edges), not a full-array search for each sheet's ancestors.
    public func subtreeIDs(rootID: UUID) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for node in nodes {
            if let parent = node.parentID { children[parent, default: []].append(node.id) }
        }
        var result: Set<UUID> = [rootID]
        var pending = [rootID]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }

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
    public mutating func create(kind: NoteKind, title: String = "", parentID: UUID? = nil) throws -> UUID {
        let clean = try Self.cleanTitle(title, kind: kind)
        try validateParent(kind: kind, parentID: parentID)
        guard nodes.count < 50_000 else { throw LibraryError.invalidData("Too many items.") }
        if let parentID, path(to: parentID).count >= 128 {
            throw LibraryError.invalidData("Topics are nested more than 128 levels deep.")
        }
        let nextOrder = try nextOrder(in: parentID)
        let number = kind == .sheet ? 1 : nil
        let node = NoteNode(parentID: parentID, kind: kind, title: clean, order: nextOrder, sheetNumber: number)
        var candidate = self
        candidate.nodes.append(node)
        if kind == .sheet, let parentID { try candidate.resequenceSheets(in: [parentID]) }
        candidate.touch(); self = candidate; return node.id
    }

    public mutating func rename(id: UUID, title: String) throws {
        guard let node = node(id: id) else { throw LibraryError.nodeNotFound }
        let title = try Self.cleanTitle(title, kind: node.kind)
        try mutate(id) { $0.title = title }
    }

    public mutating func update(_ node: NoteNode) throws {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { throw LibraryError.nodeNotFound }
        guard (1...Self.currentFormatVersion).contains(formatVersion) else { throw LibraryError.unsupportedVersion(formatVersion) }
        let previous = nodes[index]
        guard node.createdAt == previous.createdAt,
              node.sheetNumber == previous.sheetNumber,
              node.lastSheetNumber == previous.lastSheetNumber,
              node.kind == previous.kind else {
            throw LibraryError.invalidData("Creation dates and sheet numbering cannot be changed by a content edit.")
        }
        var candidate = self
        var replacement = node
        replacement.title = try Self.cleanTitle(replacement.title, kind: replacement.kind)
        if replacement.kind == .sheet, replacement.parentID != previous.parentID {
            try candidate.validateParent(kind: .sheet, parentID: replacement.parentID)
        }
        replacement.updatedAt = Date()
        candidate.nodes[index] = replacement
        if !replacement.diagrams.isEmpty { candidate.formatVersion = max(candidate.formatVersion, 4) }
        else if !replacement.images.isEmpty { candidate.formatVersion = max(candidate.formatVersion, 3) }
        else if !replacement.textBoxes.isEmpty || !replacement.equations.isEmpty {
            candidate.formatVersion = max(candidate.formatVersion, 2)
        }
        if previous.parentID == replacement.parentID, previous.kind == replacement.kind,
           previous.isTrashed == replacement.isTrashed, previous.order == replacement.order {
            // Existing structure is unchanged. Avoid scanning every other sheet's ink on each keypress.
            try Self.validatePayload(replacement, previous: previous)
        } else {
            if replacement.kind == .sheet {
                try candidate.resequenceSheets(in: Set([previous.parentID, replacement.parentID].compactMap { $0 }))
            }
            try candidate.validate()
        }
        candidate.touch(); self = candidate
    }

    public mutating func move(id: UUID, to parentID: UUID?, at order: Int? = nil) throws {
        guard let node = node(id: id) else { throw LibraryError.nodeNotFound }
        if parentID == id || parentID.map({ subtreeIDs(rootID: id).contains($0) }) == true { throw LibraryError.cycle }
        try validateParent(kind: node.kind, parentID: parentID)
        let siblings = children(of: parentID, includingTrash: true).filter { $0.id != id }
        let destination = max(0, min(order ?? siblings.count, siblings.count))
        var sorted = siblings.map(\.id)
        sorted.insert(id, at: destination)
        var candidate = self
        try candidate.mutate(id) { $0.parentID = parentID }
        let indices = Dictionary(uniqueKeysWithValues: candidate.nodes.indices.map { (candidate.nodes[$0].id, $0) })
        for (position, siblingID) in sorted.enumerated() {
            if let index = indices[siblingID] { candidate.nodes[index].order = position }
        }
        if node.kind == .sheet {
            try candidate.resequenceSheets(in: Set([node.parentID, parentID].compactMap { $0 }))
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
                if !item.title.isEmpty { item.title = String(item.title.prefix(249)) + " (copy)" }
                item.order = copyOrder
                if item.kind == .sheet { item.sheetNumber = 1 }
            }
            // Attachment/stroke IDs are local to a sheet, so their bytes need no rewriting.
            candidate.nodes.append(item)
        }
        let copiedIDs = Set(mapping.values)
        let parents = Set(candidate.nodes.filter { copiedIDs.contains($0.id) && $0.kind == .sheet }.compactMap(\.parentID))
        try candidate.resequenceSheets(in: parents)
        candidate.touch()
        _ = try LibraryArchive.encode(candidate)
        self = candidate
        return mapping[id]!
    }

    public mutating func trash(id: UUID) throws {
        guard node(id: id) != nil else { throw LibraryError.nodeNotFound }
        let ids = subtreeIDs(rootID: id)
        let now = Date()
        var candidate = self
        var parents = Set<UUID>()
        for index in candidate.nodes.indices where ids.contains(candidate.nodes[index].id) {
            if candidate.nodes[index].kind == .sheet, let parent = candidate.nodes[index].parentID { parents.insert(parent) }
            candidate.nodes[index].isTrashed = true; candidate.nodes[index].updatedAt = now
        }
        try candidate.resequenceSheets(in: parents)
        candidate.touch(); self = candidate
    }

    public mutating func restore(id: UUID) throws {
        guard node(id: id) != nil else { throw LibraryError.nodeNotFound }
        let ids = Set(path(to: id).map(\.id)).union(subtreeIDs(rootID: id))
        let now = Date()
        var candidate = self
        var parents = Set<UUID>()
        for index in candidate.nodes.indices where ids.contains(candidate.nodes[index].id) {
            if candidate.nodes[index].kind == .sheet, let parent = candidate.nodes[index].parentID { parents.insert(parent) }
            candidate.nodes[index].isTrashed = false; candidate.nodes[index].updatedAt = now
        }
        try candidate.resequenceSheets(in: parents)
        try candidate.validate()
        candidate.touch(); self = candidate
    }

    public mutating func permanentlyDelete(id: UUID) throws {
        guard let existing = node(id: id), existing.isTrashed else { throw LibraryError.invalidData("Only items in Trash can be permanently deleted.") }
        let ids = subtreeIDs(rootID: id)
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
            let haystack = ([item.title, item.body] + item.tags + item.textBoxes.map(\.text) + item.equations.map(\.latex)
                + item.diagrams.map(\.plainText)).joined(separator: "\n")
            return tokens.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func validate() throws {
        guard (1...Self.currentFormatVersion).contains(formatVersion) else { throw LibraryError.unsupportedVersion(formatVersion) }
        if formatVersion == 1, nodes.contains(where: { !$0.textBoxes.isEmpty || !$0.equations.isEmpty }) {
            throw LibraryError.invalidData("Movable text and equations require archive format 2.")
        }
        if formatVersion < 3, nodes.contains(where: { !$0.images.isEmpty }) {
            throw LibraryError.invalidData("Page images require archive format 3.")
        }
        if formatVersion < 4, nodes.contains(where: { !$0.diagrams.isEmpty }) {
            throw LibraryError.invalidData("Shapes, connectors, and tables require archive format 4.")
        }
        guard nodes.count <= 50_000 else { throw LibraryError.invalidData("Too many items.") }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw LibraryError.duplicateID }
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var ancestorDepths: [UUID: Int] = [:]
        var usedSheetNumbers: [UUID: Set<Int>] = [:]
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
                if node.kind == .sheet {
                    guard let number = node.sheetNumber,
                          number <= parent.lastSheetNumber,
                          usedSheetNumbers[parentID, default: []].insert(number).inserted else {
                        throw LibraryError.invalidData("A chapter or topic has missing or duplicate sheet numbers.")
                    }
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

    private static func cleanTitle(_ title: String, kind: NoteKind) throws -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (kind == .sheet || !clean.isEmpty), clean.count <= 256 else { throw LibraryError.invalidTitle }
        return clean
    }

    private static func validatePayload(_ node: NoteNode, previous: NoteNode? = nil) throws {
        _ = try cleanTitle(node.title, kind: node.kind)
        if previous?.images != node.images { try PageImageLimits.validate(node.images) }
        if previous?.diagrams != node.diagrams { try PageDiagramLimits.validate(node.diagrams) }
        guard node.lastSheetNumber >= 0,
              (node.kind == .chapter || node.kind == .topic || node.lastSheetNumber == 0),
              (node.kind == .sheet ? node.sheetNumber.map { $0 > 0 } == true : node.sheetNumber == nil) else {
            throw LibraryError.invalidData("Invalid sheet numbering.")
        }
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
            try InkGeometryLimits.validate(node.strokes)
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

    private static func pageOrder(_ first: NoteNode, _ second: NoteNode) -> Bool {
        if first.order != second.order { return first.order < second.order }
        if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
        return first.id.uuidString < second.id.uuidString
    }

    /// Number active pages in visible sibling order. Work from one index for all affected
    /// parents, including whole-folder restore; never rescan the library for each sheet.
    /// Only numbering metadata changes here, leaving content, dates and array order intact.
    private mutating func resequenceSheets(in parents: Set<UUID>? = nil) throws {
        var groups: [UUID: [Int]] = [:]
        var folderIndices: [UUID: Int] = [:]
        for index in nodes.indices {
            let node = nodes[index]
            if node.kind == .chapter || node.kind == .topic { folderIndices[node.id] = index }
            if node.kind == .sheet, let parent = node.parentID, parents?.contains(parent) ?? true {
                guard node.createdAt.timeIntervalSince1970.isFinite else { throw LibraryError.invalidData("Invalid note date.") }
                groups[parent, default: []].append(index)
            }
        }
        for (parent, siblings) in groups {
            guard let folder = folderIndices[parent] else { throw LibraryError.invalidParent }
            let active = siblings.filter { !nodes[$0].isTrashed }.sorted { Self.pageOrder(nodes[$0], nodes[$1]) }
            let trashed = siblings.filter { nodes[$0].isTrashed }
            for (offset, index) in active.enumerated() { nodes[index].sheetNumber = offset + 1 }
            // Keep stored sibling numbers unique for previous archive readers. Trash is
            // outside the active page sequence and never prevents it starting at Sheet 1.
            var occupied = Set(trashed.compactMap { nodes[$0].sheetNumber }.filter { $0 > active.count })
            var assignedArchiveNumbers = Set<Int>()
            var nextArchiveNumber = active.count + 1
            for index in trashed.sorted(by: { Self.pageOrder(nodes[$0], nodes[$1]) }) {
                if let number = nodes[index].sheetNumber, number > active.count,
                   assignedArchiveNumbers.insert(number).inserted { continue }
                else {
                    while occupied.contains(nextArchiveNumber) { nextArchiveNumber += 1 }
                    nodes[index].sheetNumber = nextArchiveNumber
                    occupied.insert(nextArchiveNumber)
                    assignedArchiveNumbers.insert(nextArchiveNumber)
                }
            }
            let highest = max(active.count, occupied.max() ?? 0)
            nodes[folder].lastSheetNumber = max(nodes[folder].lastSheetNumber, highest)
        }
    }

    /// Older archives have neither field. Allocate in creation order, not array, edit, or
    /// display order; retained Trash entries participate so restoring never creates a collision.
    private mutating func migrateLegacySheetNumbers() throws {
        guard nodes.count <= 50_000 else { throw LibraryError.invalidData("Too many items.") }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw LibraryError.duplicateID }
        guard nodes.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite }) else {
            throw LibraryError.invalidData("Invalid note date.")
        }
        let indices = Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, $0) })
        var counters: [UUID: Int] = [:]
        for node in nodes where node.kind == .chapter || node.kind == .topic {
            guard node.lastSheetNumber >= 0 else { throw LibraryError.invalidData("Invalid sheet numbering.") }
            counters[node.id] = node.lastSheetNumber
        }
        for node in nodes where node.kind == .sheet {
            if let number = node.sheetNumber {
                guard number > 0 else { throw LibraryError.invalidData("Invalid sheet numbering.") }
                if let parent = node.parentID, let counter = counters[parent] { counters[parent] = max(counter, number) }
            }
        }
        let missing = nodes.indices.filter { nodes[$0].kind == .sheet && nodes[$0].sheetNumber == nil }
            .sorted {
                let first = nodes[$0], second = nodes[$1]
                if first.createdAt != second.createdAt {
                    return first.createdAt < second.createdAt
                }
                return first.id.uuidString < second.id.uuidString
            }
        for index in missing {
            guard let parent = nodes[index].parentID, let previous = counters[parent] else { continue }
            let (number, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { throw LibraryError.invalidData("This chapter or topic has reached its sheet number limit.") }
            nodes[index].sheetNumber = number
            counters[parent] = number
        }
        for (id, counter) in counters { if let index = indices[id] { nodes[index].lastSheetNumber = counter } }
        // Reject corrupt numbering/graphs before normalizing valid older gaps. This keeps
        // migration from disguising duplicate numbers or invalid dates as a repaired file.
        try validate()
        try resequenceSheets()
    }

    private func nextOrder(in parentID: UUID?) throws -> Int {
        let (next, overflow) = (children(of: parentID, includingTrash: true).map(\.order).max() ?? -1).addingReportingOverflow(1)
        guard !overflow else { throw LibraryError.invalidData("An item has an invalid position. Move it to reset its position.") }
        return next
    }
}
