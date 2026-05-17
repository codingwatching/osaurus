//
//  PlainTextAdapter.swift
//  osaurus
//
//  Wraps the existing plain-text ingress path in `DocumentParser`. Claims
//  roughly the 60 extensions that were previously handled by the inline
//  `case _ where isPlainText(ext:)` branch — `.txt`, `.md`, source code,
//  config files, etc. Behaviour is intentionally identical to the legacy
//  switch: UTF-8 first, ISO-Latin-1 retry, post-read character-count
//  truncation marker. This adapter is a migration bridge, not a fidelity
//  improvement.
//

import Foundation

public struct PlainTextAdapter: DocumentFormatAdapter {
    public let formatId = "plaintext"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        Self.plainTextExtensions.contains(url.pathExtension.lowercased())
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let rawContent: String
        do {
            rawContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Fall back to latin-1 for files that are "mostly text" with a few
            // non-UTF-8 bytes — same behaviour as the legacy path.
            guard let data = try? Data(contentsOf: url),
                let decoded = String(data: data, encoding: .isoLatin1)
            else {
                throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
            }
            rawContent = decoded
        }

        guard !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let truncated = Self.applyCharacterCap(rawContent)
        let structure = DocumentStructure.plainText(filename: url.lastPathComponent, text: truncated)
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId
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

    /// Preserves the legacy 500K-character UX — consumers already expect the
    /// trailing marker when a document is truncated mid-read. The cap on
    /// bytes-read is higher (see `DocumentLimits.plainText`), so the two
    /// interact: oversized files are refused outright; merely long files
    /// are surfaced with a truncation note.
    static func applyCharacterCap(_ text: String) -> String {
        let cap = 500_000
        guard text.count > cap else { return text }
        return String(text.prefix(cap))
            + "\n\n[Document truncated — exceeded \(cap) character limit]"
    }

    static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv",
        "json", "xml", "yaml", "yml", "toml",
        "log", "ini", "cfg", "conf", "env",
        "swift", "py", "js", "ts", "tsx", "jsx",
        "rs", "go", "java", "kt", "c", "cpp", "h", "hpp",
        "rb", "php", "sh", "bash", "zsh", "fish",
        "css", "scss", "less", "sql",
        "r", "m", "mm", "lua", "pl", "ex", "exs",
        "zig", "nim", "dart", "scala", "groovy",
        "tf", "hcl", "dockerfile",
        "gitignore", "editorconfig", "prettierrc",
    ]
}
