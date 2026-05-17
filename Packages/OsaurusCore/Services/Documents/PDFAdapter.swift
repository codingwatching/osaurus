//
//  PDFAdapter.swift
//  osaurus
//
//  Wraps the text-layer extraction path in `DocumentParser.parsePDFWithFallback`.
//  Intentionally does NOT cover the image-rendering fallback — when a PDF has
//  no extractable text, this adapter throws `.emptyContent` and the
//  `DocumentParser` shim falls through to the legacy switch, which still
//  renders each page as PNG. Moving that path onto the adapter surface is
//  deferred to stage-4 PR 8 (layout-aware table extraction), where the
//  typed `PDFDocument` representation gets introduced.
//

import Foundation
import PDFKit

public struct PDFAdapter: DocumentFormatAdapter {
    public let formatId = "pdf"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        guard let document = PDFDocument(url: url) else {
            throw DocumentAdapterError.readFailed(underlying: "PDFKit could not open document")
        }

        let pages = Self.extractTextPages(from: document)
        let extracted = pages.map(\.text).joined(separator: "\n\n")
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No text layer — let the shim fall through to the legacy image-
            // render fallback. Don't claim a result we can't produce.
            throw DocumentAdapterError.emptyContent
        }

        let truncated = PlainTextAdapter.applyCharacterCap(extracted)
        let pageTexts = pages.map { DocumentPageText(pageIndex: $0.pageIndex, text: $0.text) }
        let structure = Self.structureForTextFallback(
            filename: url.lastPathComponent,
            pages: pageTexts,
            extractedText: extracted,
            textFallback: truncated
        )
        let securitySignals = Self.securitySignals(for: document)
        let securityFindings =
            securitySignals.findings
            + Self.truncationFindings(extractedText: extracted, textFallback: truncated)
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId,
            inspectionStatus: .partiallyInspected,
            isEncrypted: document.isEncrypted || document.isLocked,
            findings: securityFindings,
            activeContentTypes: securitySignals.activeContentTypes
        )

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PlainTextRepresentation(text: truncated)
            ),
            structure: structure,
            security: security,
            textFallback: truncated
        )
    }

    private static func extractTextPages(from document: PDFDocument) -> [ExtractedPageText] {
        var pages: [ExtractedPageText] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                let text = page.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            pages.append(ExtractedPageText(pageIndex: index, text: text))
        }
        return pages
    }

    static func structureForTextFallback(
        filename: String,
        pages: [DocumentPageText],
        extractedText: String,
        textFallback: String
    ) -> DocumentStructure {
        guard !pages.isEmpty else {
            return DocumentStructure.plainText(filename: filename, text: textFallback)
        }
        return Self.paginatedTextStructure(
            filename: filename,
            pages: pages,
            extractedText: extractedText,
            textFallback: textFallback
        )
    }

    private static func paginatedTextStructure(
        filename: String,
        pages: [DocumentPageText],
        extractedText: String,
        textFallback: String
    ) -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: filename)
        let visiblePrefixLength = Self.visibleExtractedPrefixUTF16Length(
            extractedText: extractedText,
            textFallback: textFallback
        )
        var extractedOffset = 0
        var elements: [DocumentElement] = []

        for (order, page) in pages.enumerated() {
            if order > 0 {
                extractedOffset += Self.pageSeparatorUTF16Length
            }

            let sourceLength = page.text.utf16.count
            let visibleLength = min(sourceLength, max(0, visiblePrefixLength - extractedOffset))
            let fallbackStart = min(extractedOffset, visiblePrefixLength)
            let range = DocumentTextRange(startUTF16Offset: fallbackStart, length: visibleLength)
            let clippedText = Self.prefix(page.text, maxUTF16Length: visibleLength)
            let wasClipped = visibleLength < sourceLength
            let metadata = Self.pageMetadata(
                pageIndex: page.pageIndex,
                order: order,
                sourceLength: sourceLength,
                visibleLength: visibleLength,
                range: range,
                wasClipped: wasClipped
            )
            let anchor = DocumentAnchor(
                kind: .page,
                path: [
                    .init(kind: .document),
                    .init(kind: .page, index: page.pageIndex),
                ],
                textRange: range,
                sourceRange: .init(
                    start: .init(pageIndex: page.pageIndex, characterOffset: 0),
                    end: .init(pageIndex: page.pageIndex, characterOffset: visibleLength)
                ),
                label: "Page \(page.pageIndex + 1)",
                metadata: metadata
            )
            elements.append(
                DocumentElement(
                    kind: .page,
                    anchor: anchor,
                    text: clippedText.isEmpty ? nil : clippedText,
                    attributes: .init(metadata: metadata)
                )
            )
            extractedOffset += sourceLength
        }

        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: elements
        )
        return DocumentStructure(root: root, textLengthUTF16: textFallback.utf16.count)
    }

    private static func visibleExtractedPrefixUTF16Length(
        extractedText: String,
        textFallback: String
    ) -> Int {
        if extractedText == textFallback {
            return textFallback.utf16.count
        }

        // The fallback may contain the truncation marker, which is not source
        // PDF text. Only the shared prefix can safely receive page anchors.
        var extractedIndex = extractedText.startIndex
        var fallbackIndex = textFallback.startIndex
        var length = 0
        while extractedIndex < extractedText.endIndex,
            fallbackIndex < textFallback.endIndex,
            extractedText[extractedIndex] == textFallback[fallbackIndex]
        {
            let nextExtractedIndex = extractedText.index(after: extractedIndex)
            length += extractedText[extractedIndex ..< nextExtractedIndex].utf16.count
            extractedIndex = nextExtractedIndex
            fallbackIndex = textFallback.index(after: fallbackIndex)
        }
        return length
    }

    private static func prefix(_ text: String, maxUTF16Length: Int) -> String {
        guard maxUTF16Length > 0 else { return "" }
        guard text.utf16.count > maxUTF16Length else { return text }

        var endIndex = text.startIndex
        var length = 0
        while endIndex < text.endIndex {
            let nextIndex = text.index(after: endIndex)
            let nextLength = text[endIndex ..< nextIndex].utf16.count
            guard length + nextLength <= maxUTF16Length else { break }
            length += nextLength
            endIndex = nextIndex
        }
        return String(text[..<endIndex])
    }

    private static func pageMetadata(
        pageIndex: Int,
        order: Int,
        sourceLength: Int,
        visibleLength: Int,
        range: DocumentTextRange,
        wasClipped: Bool
    ) -> [String: String] {
        [
            "pageIndex": "\(pageIndex)",
            "pageNumber": "\(pageIndex + 1)",
            "pageOrder": "\(order)",
            "fallbackStartUTF16Offset": "\(range.startUTF16Offset)",
            "fallbackEndUTF16Offset": "\(range.endUTF16Offset)",
            "sourceTextUTF16Length": "\(sourceLength)",
            "visibleTextUTF16Length": "\(visibleLength)",
            "truncatedByFallbackCap": "\(wasClipped)",
        ]
    }

    private static func securitySignals(
        for document: PDFDocument
    ) -> (findings: [DocumentSecurityFinding], activeContentTypes: Set<DocumentActiveContentType>) {
        var findings: [DocumentSecurityFinding] = [
            DocumentSecurityFinding(
                kind: .unsupportedFeature,
                severity: .informational,
                message:
                    "PDF active content, embedded files, and annotations are not fully inspected by the text-layer adapter."
            )
        ]
        let activeContentTypes: Set<DocumentActiveContentType> = []

        if document.isEncrypted || document.isLocked {
            findings.append(
                DocumentSecurityFinding(
                    kind: .encryptedContent,
                    severity: document.isLocked ? .high : .low,
                    message: "PDF reports encrypted or locked content."
                )
            )
        }

        if !document.allowsCopying {
            findings.append(
                DocumentSecurityFinding(
                    kind: .permissionRestriction,
                    severity: .low,
                    message: "PDF permissions disallow copying."
                )
            )
        }

        return (findings, activeContentTypes)
    }

    private static func truncationFindings(
        extractedText: String,
        textFallback: String
    ) -> [DocumentSecurityFinding] {
        guard extractedText != textFallback else { return [] }
        return [
            DocumentSecurityFinding(
                kind: .truncatedContent,
                severity: .low,
                message: "PDF text fallback was character-capped; page anchors were clipped to visible fallback text.",
                metadata: [
                    "extractedUTF16Length": "\(extractedText.utf16.count)",
                    "fallbackUTF16Length": "\(textFallback.utf16.count)",
                ]
            )
        ]
    }

    private struct ExtractedPageText {
        let pageIndex: Int
        let text: String
    }

    private static let pageSeparatorUTF16Length = "\n\n".utf16.count
}
