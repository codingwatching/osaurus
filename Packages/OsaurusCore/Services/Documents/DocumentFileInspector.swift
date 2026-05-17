//
//  DocumentFileInspector.swift
//  osaurus
//
//  Shared provenance/security helpers for document adapters. The helpers keep
//  byte-level facts (UTI, digest) and lightweight active-content heuristics in
//  one place while higher-fidelity format lanes add deeper inspectors.
//

import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum DocumentFileInspector {
    public struct HTMLSecuritySignals: Sendable {
        public let findings: [DocumentSecurityFinding]
        public let externalReferences: [DocumentExternalReference]
        public let activeContentTypes: Set<DocumentActiveContentType>

        public init(
            findings: [DocumentSecurityFinding] = [],
            externalReferences: [DocumentExternalReference] = [],
            activeContentTypes: Set<DocumentActiveContentType> = []
        ) {
            self.findings = findings
            self.externalReferences = externalReferences
            self.activeContentTypes = activeContentTypes
        }
    }

    public static func localFileSecurityMetadata(
        url: URL,
        formatId: String,
        inspectionStatus: DocumentSecurityMetadata.InspectionStatus = .inspected,
        isEncrypted: Bool? = nil,
        findings initialFindings: [DocumentSecurityFinding] = [],
        externalReferences: [DocumentExternalReference] = [],
        activeContentTypes: Set<DocumentActiveContentType> = []
    ) -> DocumentSecurityMetadata {
        var findings = initialFindings
        var status = inspectionStatus
        let digest = try? sha256Hex(of: url)
        if digest == nil {
            findings.append(
                DocumentSecurityFinding(
                    kind: .integrityUnavailable,
                    severity: .low,
                    message: "Could not compute SHA-256 digest for the source document."
                )
            )
            if status == .inspected {
                status = .partiallyInspected
            }
        }

        let fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
        let type = fileExtension.flatMap { UTType(filenameExtension: $0) }
        return DocumentSecurityMetadata(
            inspectionStatus: status,
            sourceTrust: .userSelectedLocalFile,
            formatId: formatId,
            fileExtension: fileExtension,
            uti: type?.identifier,
            declaredMimeType: type?.preferredMIMEType,
            sha256: digest,
            isEncrypted: isEncrypted,
            activeContentTypes: activeContentTypes,
            externalReferences: externalReferences,
            findings: findings
        )
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func htmlSecuritySignals(rawHTML: String) -> HTMLSecuritySignals {
        let lowercased = rawHTML.lowercased()
        var findings: [DocumentSecurityFinding] = []
        var activeContentTypes: Set<DocumentActiveContentType> = []

        if lowercased.contains("<script") || lowercased.contains("javascript:") {
            activeContentTypes.insert(.script)
            findings.append(
                DocumentSecurityFinding(
                    kind: .script,
                    severity: .medium,
                    message: "HTML document contains script-bearing content."
                )
            )
        }

        if lowercased.contains("<iframe") || lowercased.contains("<object") || lowercased.contains("<embed") {
            activeContentTypes.insert(.embeddedFile)
            findings.append(
                DocumentSecurityFinding(
                    kind: .embeddedFile,
                    severity: .medium,
                    message: "HTML document contains embeddable active content."
                )
            )
        }

        let externalReferences = extractHTMLExternalReferences(rawHTML)
        if !externalReferences.isEmpty {
            activeContentTypes.insert(.externalReference)
            findings.append(
                DocumentSecurityFinding(
                    kind: .externalReference,
                    severity: .low,
                    message: "HTML document references external resources.",
                    metadata: ["count": "\(externalReferences.count)"]
                )
            )
        }

        return HTMLSecuritySignals(
            findings: findings,
            externalReferences: externalReferences,
            activeContentTypes: activeContentTypes
        )
    }

    private static func extractHTMLExternalReferences(_ rawHTML: String) -> [DocumentExternalReference] {
        let pattern = #"(?i)\b(href|src|action)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: rawHTML.utf16.count)
        return regex.matches(in: rawHTML, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                let attributeRange = Range(match.range(at: 1), in: rawHTML),
                let valueRange = Range(match.range(at: 2), in: rawHTML)
            else { return nil }
            let attribute = String(rawHTML[attributeRange]).lowercased()
            let urlString = String(rawHTML[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isExternalURL(urlString) else { return nil }
            return DocumentExternalReference(
                kind: htmlReferenceKind(attribute: attribute, urlString: urlString),
                urlString: urlString
            )
        }
    }

    private static func isExternalURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("//")
            || lowercased.hasPrefix("file://")
    }

    private static func htmlReferenceKind(attribute: String, urlString: String) -> DocumentExternalReference.Kind {
        let lowercased = urlString.lowercased()
        switch attribute {
        case "href" where lowercased.hasSuffix(".css"):
            return .stylesheet
        case "href":
            return .hyperlink
        case "src" where lowercased.hasSuffix(".js"):
            return .script
        case "src" where ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(lowercased.pathExtension):
            return .image
        case "src":
            return .media
        default:
            return .unknown
        }
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
