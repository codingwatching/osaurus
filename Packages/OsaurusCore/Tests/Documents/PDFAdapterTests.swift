//
//  PDFAdapterTests.swift
//  osaurusTests
//
//  Exercises the text-layer PDF adapter. Synthesises tiny PDFs via Core
//  Graphics so the test bundle doesn't carry binary fixtures. The
//  image-only fallback path stays in the legacy `DocumentParser` switch
//  for now; the adapter intentionally throws `.emptyContent` when there's
//  no text layer so the shim can fall through.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@Suite("PDFAdapter")
struct PDFAdapterTests {

    @Test func canHandle_acceptsPDFExtensionOnly() {
        let adapter = PDFAdapter()
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.pdf"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.PDF"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.txt"), uti: nil) == false)
    }

    @Test func parse_readsTextLayer() async throws {
        let url = try Self.writePDF(text: "Hello PDF body content")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.formatId == "pdf")
        #expect(doc.textFallback.contains("Hello PDF body content"))
    }

    @Test func parse_throwsEmptyContentForPDFWithNoTextLayer() async throws {
        let url = try Self.writeBlankPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        }
    }

    @Test func parse_throwsSizeLimitExceededAboveCap() async throws {
        let url = try Self.writePDF(text: "tiny")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PDFAdapter().parse(url: url, sizeLimit: 1)
        }
    }

    // MARK: - Fixtures

    private static func writePDF(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)

        // Draw the text into the PDF context via NSAttributedString so PDFKit
        // can recover it from the text layer on read-back.
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let font = NSFont.systemFont(ofSize: 14)
        NSAttributedString(string: text, attributes: [.font: font])
            .draw(at: NSPoint(x: 20, y: 100))
        NSGraphicsContext.restoreGraphicsState()

        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func writeBlankPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-blank-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private enum FixtureError: Error { case contextCreationFailed }
}
