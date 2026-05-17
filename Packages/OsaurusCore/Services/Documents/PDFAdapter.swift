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
        guard extractedText == textFallback else {
            return DocumentStructure.plainText(filename: filename, text: textFallback)
        }
        return DocumentStructure.paginatedText(filename: filename, pages: pages)
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
                message: "PDF text fallback was character-capped; page-level text ranges were not preserved.",
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
}
