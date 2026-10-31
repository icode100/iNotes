#!/usr/bin/env swift
import CryptoKit
import Foundation

// Sparkle 2.10 accepts a base64-encoded 32-byte Ed25519 seed with --ed-key-file.
// Use a project-specific file rather than altering the user's login Keychain.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent(".private/updates", isDirectory: true)
let privateURL = directory.appendingPathComponent("ed25519.key")
let publicURL = root.appendingPathComponent("Resources/UpdatePublicEDKey.txt")
let manager = FileManager.default
try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let key: Curve25519.Signing.PrivateKey
if manager.fileExists(atPath: privateURL.path) {
    let text = try String(contentsOf: privateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: text), data.count == 32 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
} else {
    guard !manager.fileExists(atPath: publicURL.path) else {
        fputs("A public update key already exists. Restore its original private key; do not silently replace the release identity.\n", stderr)
        exit(2)
    }
    key = Curve25519.Signing.PrivateKey()
    // The containing directory is private before this atomic write is made.
    try (key.rawRepresentation.base64EncodedString() + "\n").write(to: privateURL, atomically: true, encoding: .utf8)
}
try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
let publicText = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
if manager.fileExists(atPath: publicURL.path), try String(contentsOf: publicURL, encoding: .utf8) != publicText {
    fputs("The private key does not match the committed public update key. No public key was changed.\n", stderr)
    exit(2)
}
try publicText.write(to: publicURL, atomically: true, encoding: .utf8)
print("Update signing identity ready. Private seed: .private/updates/ed25519.key (mode 600); public key: Resources/UpdatePublicEDKey.txt")
