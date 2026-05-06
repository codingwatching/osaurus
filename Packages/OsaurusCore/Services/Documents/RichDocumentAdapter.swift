//
//  RichDocumentAdapter.swift
//  osaurus
//
//  Wraps the `NSAttributedString(url:documentType:)` path in
//  `DocumentParser.parseRichDocument`. A single adapter covers DOCX, DOC,
//  RTF, RTFD, and HTML today because they share the same underlying
//  framework call and produce the same plain-text output. When stage-4
//  PR 11 lands a high-fidelity DOCX reader (tables, tracked changes,
//  comments) this adapter splits along format lines and this one becomes
//  the RTF/HTML-only path.
//

import AppKit
import Foundation

public struct RichDocumentAdapter: DocumentFormatAdapter {
    public let formatId = "richdoc"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let documentType = Self.documentType(forExtension: url.pathExtension.lowercased())
        let extracted: String
        do {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let documentType {
                options[.documentType] = documentType
            }
            let attributed = try NSAttributedString(
                url: url,
                options: options,
                documentAttributes: nil
            )
            extracted = attributed.string
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }

        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    // MARK: - Helpers

    static let supportedExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "html", "htm",
    ]

    private static func documentType(
        forExtension ext: String
    ) -> NSAttributedString.DocumentType? {
        switch ext {
        case "docx": return nil  // NSAttributedString auto-detects OOXML
        case "doc": return .docFormat
        case "rtf", "rtfd": return .rtf
        case "html", "htm": return .html
        default: return nil
        }
    }
}
