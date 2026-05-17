//
//  PlainTextAdapterTests.swift
//  osaurusTests
//
//  Covers the plain-text migration adapter. Same behavioural contract as
//  the legacy `DocumentParser.parsePlainText` — UTF-8, ISO-Latin-1 retry,
//  character-cap truncation — plus the size-limit contract from the new
//  adapter protocol.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PlainTextAdapter")
struct PlainTextAdapterTests {

    @Test func canHandle_acceptsCommonTextExtensions() {
        let adapter = PlainTextAdapter()
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.txt"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.MD"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.swift"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.pdf"), uti: nil) == false)
    }

    @Test func parse_readsUtf8Content() async throws {
        let url = try Self.write("hello\nutf8\n", filename: "hello.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PlainTextAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.formatId == "plaintext")
        #expect(doc.filename.hasSuffix("hello.txt"))
        #expect(doc.textFallback.contains("hello"))
        #expect(doc.textFallback.contains("utf8"))
        #expect(doc.structure.root.kind == .document)
        #expect(doc.structure.anchor(id: "document/body")?.textRange?.length == doc.textFallback.utf16.count)
        #expect(doc.security.inspectionStatus == .inspected)
        #expect(doc.security.sha256?.isEmpty == false)
    }

    @Test func parse_fallsBackToLatin1ForNonUtf8Bytes() async throws {
        // A single 0xE9 byte (`é` in latin-1) is illegal standalone UTF-8.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latin-\(UUID().uuidString).txt")
        try Data([0xE9, 0x0A]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PlainTextAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.textFallback.contains("é"))
    }

    @Test func parse_throwsEmptyContentForWhitespaceOnly() async throws {
        let url = try Self.write("   \n\t\n", filename: "empty.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PlainTextAdapter().parse(url: url, sizeLimit: 0)
        }
    }

    @Test func parse_throwsSizeLimitExceededAboveCap() async throws {
        let url = try Self.write("hello world", filename: "big.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PlainTextAdapter().parse(url: url, sizeLimit: 1)
        }
    }

    @Test func parse_truncatesLongContentWithMarker() async throws {
        let payload = String(repeating: "a", count: 500_002)
        let url = try Self.write(payload, filename: "long.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PlainTextAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.textFallback.hasSuffix("character limit]"))
    }

    // MARK: - Helpers

    private static func write(_ content: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
