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

    @Test func parse_readsHTMLBodyAsPlainTextAndSafeStructure() async throws {
        let url = try Self.write(
            """
            <html>
              <head><script src="https://example.com/app.js"></script></head>
              <body>
                <h1>Title</h1>
                <p>Body text</p>
                <ul>
                  <li>First</li>
                  <li>Second</li>
                </ul>
              </body>
            </html>
            """,
            filename: "page.html"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await RichDocumentAdapter().parse(url: url, sizeLimit: 0)
        let rich = try #require(doc.representation.underlying as? RichDocumentRepresentation)

        #expect(doc.formatId == "richdoc")
        #expect(doc.textFallback.contains("Title"))
        #expect(doc.textFallback.contains("Body text"))
        #expect(doc.textFallback.contains("<h1>") == false)
        #expect(rich.text == doc.textFallback)
        #expect(rich.sourceFormat == .html)
        #expect(rich.sourceLabel == "HTML document")
        #expect(rich.blocks.contains { $0.kind == .heading && $0.headingLevel == 1 })
        #expect(rich.blocks.filter { $0.kind == .listItem }.count == 2)
        #expect(doc.structure.root.attributes.metadata["sourceFormat"] == "html")
        #expect(doc.structure.elements(kind: .heading).first?.text == "Title")
        #expect(doc.structure.elements(kind: .listItem).count == 2)
        #expect(doc.structure.textLengthUTF16 == doc.textFallback.utf16.count)
        #expect(doc.security.inspectionStatus == .inspected)
        #expect(doc.security.sourceTrust == .userSelectedLocalFile)
        #expect(doc.security.fileExtension == "html")
        #expect(doc.security.sha256 != nil)
        #expect(doc.security.activeContentTypes.contains(.script))
        #expect(doc.security.externalReferences.contains { $0.kind == .script })
    }

    @Test func parse_readsRTFAsPlainTextAndParagraphStructure() async throws {
        let rtf = "{\\rtf1\\ansi Hello {\\b bold} world}"
        let url = try Self.write(rtf, filename: "page.rtf")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await RichDocumentAdapter().parse(url: url, sizeLimit: 0)
        let rich = try #require(doc.representation.underlying as? RichDocumentRepresentation)

        #expect(doc.textFallback.contains("Hello"))
        #expect(doc.textFallback.contains("bold"))
        #expect(rich.text == doc.textFallback)
        #expect(rich.sourceFormat == .rtf)
        #expect(rich.blocks.first?.kind == .paragraph)
        #expect(doc.structure.elements(kind: .paragraph).first?.text == rich.blocks.first?.text)
        #expect(doc.structure.root.attributes.metadata["sourceLabel"] == "Rich Text Format")
        #expect(doc.security.inspectionStatus == .partiallyInspected)
        #expect(doc.security.findings.contains { $0.kind == .unsupportedFeature })
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
