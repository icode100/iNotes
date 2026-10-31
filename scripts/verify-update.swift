#!/usr/bin/env swift
import CryptoKit
import Foundation

func fail(_ reason: String) -> Never { fputs("Update verification failed: \(reason)\n", stderr); exit(1) }
guard CommandLine.arguments.count == 4 else { fail("Usage: verify-update.swift public-key.txt appcast.xml archive.dmg") }
let publicText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let publicData = Data(base64Encoded: publicText), publicData.count == 32 else { fail("Invalid public key") }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard let block = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
      let text = String(data: feed[block.lowerBound...], encoding: .utf8) else { fail("Missing signed feed") }
let pattern = try NSRegularExpression(pattern: "^<!-- sparkle-signatures:\\nedSignature: ([A-Za-z0-9+/=]+)\\nlength: ([0-9]+)\\n-->\\n?$")
guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let signatureRange = Range(match.range(at: 1), in: text), let lengthRange = Range(match.range(at: 2), in: text),
      let signature = Data(base64Encoded: String(text[signatureRange])),
      let length = Int(text[lengthRange]), length == block.lowerBound,
      publicKey.isValidSignature(signature, for: feed.prefix(length)) else { fail("Feed signature does not match the project's public key") }

final class EnclosureParser: NSObject, XMLParserDelegate {
    var enclosure: [String: String]?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "enclosure", enclosure == nil { enclosure = attributes }
    }
}
let delegate = EnclosureParser()
let parser = XMLParser(data: feed.prefix(length))
parser.shouldResolveExternalEntities = false
parser.delegate = delegate
guard parser.parse(), let enclosure = delegate.enclosure,
      let signatureText = enclosure["sparkle:edSignature"], let archiveSignature = Data(base64Encoded: signatureText),
      let expectedLengthText = enclosure["length"], let expectedLength = Int(expectedLengthText),
      let download = enclosure["url"], let url = URL(string: download), url.scheme == "https", url.host != nil else {
    fail("Missing signed HTTPS update enclosure")
}
let archiveURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard url.lastPathComponent == archiveURL.lastPathComponent else { fail("Enclosure names a different archive") }
let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
guard archive.count == expectedLength, publicKey.isValidSignature(archiveSignature, for: archive) else {
    fail("Archive signature or size does not match")
}
print("Verified Ed25519 signatures for the feed and update archive against the committed public key.")
