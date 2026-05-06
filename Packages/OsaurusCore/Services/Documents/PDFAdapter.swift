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

        let extracted = Self.extractText(from: document)
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No text layer — let the shim fall through to the legacy image-
            // render fallback. Don't claim a result we can't produce.
            throw DocumentAdapterError.emptyContent
        }

        let truncated = PlainTextAdapter.applyCharacterCap(extracted)

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PlainTextRepresentation(text: truncated)
            ),
            textFallback: truncated
        )
    }

    private static func extractText(from document: PDFDocument) -> String {
        var pages: [String] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                let text = page.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }
}
