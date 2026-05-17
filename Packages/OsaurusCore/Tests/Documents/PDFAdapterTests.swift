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
        #expect(doc.structure.elements(kind: .page).count == 1)
        #expect(doc.structure.elements(kind: .page).first?.anchor.sourceRange?.start.pageIndex == 0)
        #expect(doc.security.inspectionStatus == .partiallyInspected)
        #expect(doc.security.findings.contains { $0.kind == .unsupportedFeature })
    }

    @Test func parse_preservesPageSourceLocationsForMultiPagePDF() async throws {
        let url = try Self.writePDF(pages: [
            "First page text",
            "Second 😀 page",
            "Third page text",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let pages = doc.structure.elements(kind: .page)
        #expect(pages.count == 3)
        #expect(doc.structure.textLengthUTF16 == doc.textFallback.utf16.count)
        try Self.expectAnchorRangesWithinFallback(pages, fallbackLength: doc.textFallback.utf16.count)

        let firstText = try #require(pages[0].text)
        let secondText = try #require(pages[1].text)
        let firstRange = try #require(pages[0].anchor.textRange)
        let secondRange = try #require(pages[1].anchor.textRange)
        let thirdRange = try #require(pages[2].anchor.textRange)

        #expect(firstRange.startUTF16Offset == 0)
        #expect(secondRange.startUTF16Offset == firstText.utf16.count + 2)
        #expect(thirdRange.startUTF16Offset == secondRange.endUTF16Offset + 2)
        #expect(pages.map { $0.anchor.sourceRange?.start.pageIndex ?? -1 } == [0, 1, 2])
        #expect(pages.map { $0.anchor.sourceRange?.end?.pageIndex ?? -1 } == [0, 1, 2])
        #expect(pages[0].anchor.sourceRange?.start.characterOffset == 0)
        #expect(pages[1].anchor.sourceRange?.end?.characterOffset == secondText.utf16.count)
        #expect(pages.map { $0.anchor.metadata["pageOrder"] ?? "" } == ["0", "1", "2"])
    }

    @Test func parse_skipsBlankPagesButKeepsOriginalPageNumbers() async throws {
        let url = try Self.writePDF(pages: [
            "Visible first page",
            "",
            "Visible third page",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let pages = doc.structure.elements(kind: .page)

        #expect(pages.count == 2)
        #expect(pages.map { $0.anchor.sourceRange?.start.pageIndex ?? -1 } == [0, 2])
        #expect(pages.map { $0.anchor.label ?? "" } == ["Page 1", "Page 3"])
        #expect(pages.map { $0.anchor.metadata["pageOrder"] ?? "" } == ["0", "1"])
    }

    @Test func structureForTextFallback_clipsPageAnchorsWhenFallbackIsCapped() throws {
        let pages = [
            DocumentPageText(pageIndex: 0, text: "first"),
            DocumentPageText(pageIndex: 1, text: "😀second"),
            DocumentPageText(pageIndex: 2, text: "third"),
        ]
        let extracted = "first\n\n😀second\n\nthird"
        let fallback = "first\n\n😀se"

        let structure = PDFAdapter.structureForTextFallback(
            filename: "long.pdf",
            pages: pages,
            extractedText: extracted,
            textFallback: fallback
        )

        let pageElements = structure.elements(kind: .page)
        #expect(pageElements.count == 3)
        #expect(structure.elements(kind: .paragraph).isEmpty)
        #expect(structure.textLengthUTF16 == fallback.utf16.count)
        try Self.expectAnchorRangesWithinFallback(pageElements, fallbackLength: fallback.utf16.count)

        let firstRange = try #require(pageElements[0].anchor.textRange)
        let secondRange = try #require(pageElements[1].anchor.textRange)
        let thirdRange = try #require(pageElements[2].anchor.textRange)

        #expect(firstRange == DocumentTextRange(startUTF16Offset: 0, length: "first".utf16.count))
        #expect(secondRange.startUTF16Offset == "first\n\n".utf16.count)
        #expect(secondRange.length == "😀se".utf16.count)
        #expect(thirdRange.startUTF16Offset == fallback.utf16.count)
        #expect(thirdRange.isEmpty)
        #expect(pageElements[1].text == "😀se")
        #expect(pageElements[2].text == nil)
        #expect(pageElements[1].anchor.sourceRange?.end?.characterOffset == "😀se".utf16.count)
        #expect(pageElements[2].anchor.metadata["truncatedByFallbackCap"] == "true")
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
        try Self.writePDF(pages: [text])
    }

    private static func writePDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        for text in pages {
            ctx.beginPDFPage(nil)

            if !text.isEmpty {
                // Draw the text into the PDF context via NSAttributedString so
                // PDFKit can recover it from the text layer on read-back.
                let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                let font = NSFont.systemFont(ofSize: 14)
                NSAttributedString(string: text, attributes: [.font: font])
                    .draw(at: NSPoint(x: 20, y: 100))
                NSGraphicsContext.restoreGraphicsState()
            }

            ctx.endPDFPage()
        }
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

    private static func expectAnchorRangesWithinFallback(
        _ pages: [DocumentElement],
        fallbackLength: Int
    ) throws {
        for page in pages {
            let range = try #require(page.anchor.textRange)
            #expect(range.startUTF16Offset <= fallbackLength)
            #expect(range.endUTF16Offset <= fallbackLength)
        }
    }
}
