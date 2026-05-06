//
//  RichDocumentAdapterTests.swift
//  osaurusTests
//
//  Covers the NSAttributedString-backed migration adapter across the
//  extensions it claims today (DOCX, RTF, HTML). Uses HTML and RTF
//  fixtures authored inline; the DOCX path is exercised indirectly
//  through `canHandle` — building a real DOCX on the fly requires ZIP
//  plumbing that will come with the high-fidelity DOCX reader in stage-4
//  PR 11.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RichDocumentAdapter")
struct RichDocumentAdapterTests {

    @Test func canHandle_acceptsAllRichDocumentExtensions() {
        let adapter = RichDocumentAdapter()
        for ext in ["docx", "doc", "rtf", "rtfd", "html", "htm"] {
            #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.\(ext)"), uti: nil))
        }
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.txt"), uti: nil) == false)
    }

    @Test func parse_readsHTMLBodyAsPlainText() async throws {
        let url = try Self.write(
            "<html><body><h1>Title</h1><p>Body text</p></body></html>",
            filename: "page.html"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await RichDocumentAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.formatId == "richdoc")
        #expect(doc.textFallback.contains("Title"))
        #expect(doc.textFallback.contains("Body text"))
        #expect(doc.textFallback.contains("<h1>") == false)
    }

    @Test func parse_readsRTFAsPlainText() async throws {
        let rtf = "{\\rtf1\\ansi Hello {\\b bold} world}"
        let url = try Self.write(rtf, filename: "page.rtf")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await RichDocumentAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.textFallback.contains("Hello"))
        #expect(doc.textFallback.contains("bold"))
    }

    @Test func parse_throwsSizeLimitExceededAboveCap() async throws {
        let url = try Self.write("<html><body>hi</body></html>", filename: "big.html")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await RichDocumentAdapter().parse(url: url, sizeLimit: 1)
        }
    }

    // MARK: - Helpers

    private static func write(_ content: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
