import Foundation
#if os(macOS)
import Security
#endif

/// Holds exactly one security-scope access per connected target. iOS bookmarks
/// retain the implicit scope supplied by the Files folder picker.
final class BackupFolderAccess {
    private struct Envelope: Codable {
        enum Kind: String, Codable { case securityScoped, ordinary, provider }
        let version: Int
        let kind: Kind
        let data: Data
    }

    let url: URL
    private let accessed: Bool

    init(url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }

    static func restore(_ bookmark: Data) throws -> (access: BackupFolderAccess, stale: Bool) {
        var stale = false
        let data: Data
        let explicitScope: Bool
        if bookmark.first == UInt8(ascii: "{") {
            let envelope = try JSONDecoder().decode(Envelope.self, from: bookmark)
            guard envelope.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            data = envelope.data
            explicitScope = envelope.kind == .securityScoped
        } else {
            // Versions before this envelope stored a raw macOS scoped bookmark.
            data = bookmark
            explicitScope = true
        }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = explicitScope ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        #else
        _ = explicitScope // iOS retains the Files provider's implicit security scope.
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &stale)
        return (BackupFolderAccess(url: url), stale)
    }

    /// The injectable scoped creator lets the disposable native diagnostics prove
    /// the actual fallback path without changing process-wide OS permissions.
    func bookmark(scopedCreator: ((URL) throws -> Data)? = nil) throws -> Data {
        #if os(macOS)
        do {
            let data = try scopedCreator?(url) ?? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            return try JSONEncoder().encode(Envelope(version: 1, kind: .securityScoped, data: data))
        } catch {
            // Ordinary bookmarks retain an existing URL/access grant; they do
            // not grant access that this process lacks. Sandboxed apps must
            // keep the strict scoped-bookmark path.
            guard Self.isKnownNonSandboxed else { throw error }
            let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            return try JSONEncoder().encode(Envelope(version: 1, kind: .ordinary, data: data))
        }
        #else
        let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try JSONEncoder().encode(Envelope(version: 1, kind: .provider, data: data))
        #endif
    }

    #if os(macOS)
    static var isKnownNonSandboxed: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        let sandbox = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, &error)
        if let error { _ = error.takeRetainedValue(); return false }
        return (sandbox as? Bool) != true
    }
    #endif

    static func isOrdinaryBookmark(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data).kind) == .ordinary
    }

    static func diagnostic(_ error: Error) -> String {
        let value = error as NSError
        let primary = "\(value.domain) code \(value.code)"
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            return primary + " (underlying \(underlying.domain) code \(underlying.code))"
        }
        return primary
    }

    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}
