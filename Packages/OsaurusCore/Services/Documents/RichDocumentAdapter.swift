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
        let structure = DocumentStructure.plainText(filename: url.lastPathComponent, text: truncated)
        let securitySignals = Self.securitySignals(url: url)
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId,
            inspectionStatus: securitySignals.inspectionStatus,
            findings: securitySignals.findings,
            externalReferences: securitySignals.externalReferences,
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

    private static func securitySignals(url: URL) -> RichSecuritySignals {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            guard let rawHTML = readTextSource(url: url) else {
                return RichSecuritySignals(
                    inspectionStatus: .partiallyInspected,
                    findings: [
                        DocumentSecurityFinding(
                            kind: .integrityUnavailable,
                            severity: .low,
                            message: "Could not inspect HTML source for active content."
                        )
                    ]
                )
            }
            let signals = DocumentFileInspector.htmlSecuritySignals(rawHTML: rawHTML)
            return RichSecuritySignals(
                inspectionStatus: .inspected,
                findings: signals.findings,
                externalReferences: signals.externalReferences,
                activeContentTypes: signals.activeContentTypes
            )
        }

        var findings: [DocumentSecurityFinding] = [
            DocumentSecurityFinding(
                kind: .unsupportedFeature,
                severity: .informational,
                message:
                    "Rich document package relationships and embedded objects are not fully inspected by the text-only adapter."
            )
        ]
        var activeContentTypes: Set<DocumentActiveContentType> = []
        if ext == "doc" {
            activeContentTypes.insert(.unknown)
            findings.append(
                DocumentSecurityFinding(
                    kind: .activeContent,
                    severity: .low,
                    message: "Legacy Word documents may contain macros or embedded active content."
                )
            )
        }

        return RichSecuritySignals(
            inspectionStatus: .partiallyInspected,
            findings: findings,
            activeContentTypes: activeContentTypes
        )
    }

    private static func readTextSource(url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    private struct RichSecuritySignals {
        let inspectionStatus: DocumentSecurityMetadata.InspectionStatus
        var findings: [DocumentSecurityFinding] = []
        var externalReferences: [DocumentExternalReference] = []
        var activeContentTypes: Set<DocumentActiveContentType> = []
    }
}
