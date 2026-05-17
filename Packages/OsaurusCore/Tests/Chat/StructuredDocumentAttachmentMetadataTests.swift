//
//  StructuredDocumentAttachmentMetadataTests.swift
//  osaurusTests
//
//  Verifies that typed document parses keep their cheap routing metadata
//  on the attachment without changing the legacy text-document surface.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Structured document attachment metadata", .serialized)
struct StructuredDocumentAttachmentMetadataTests {
    private static let fixtureFormatId = "test-structured-attachment"
    private static let fixtureExtension = "structuredattachment"
    private static let createdAt = Date(timeIntervalSince1970: 1_783_939_200)

    @Test func factoryKeepsLegacyDocumentFallback() {
        let document = Self.sampleStructuredDocument(filename: "report.csv", text: "a,b\n1,2\n")
        let attachment = Attachment.structuredDocument(document)

        #expect(attachment.isDocument)
        #expect(attachment.filename == "report.csv")
        #expect(attachment.documentContent == "a,b\n1,2\n")
        #expect(attachment.loadDocumentContent() == "a,b\n1,2\n")

        guard case .document(let filename, let content, let fileSize) = attachment.kind else {
            Issue.record("structured document should keep using the legacy document attachment kind")
            return
        }

        #expect(filename == "report.csv")
        #expect(content == "a,b\n1,2\n")
        #expect(fileSize == Int(document.fileSize))
        #expect(attachment.structuredDocumentMetadata?.formatId == "csv")
        #expect(attachment.structuredDocumentMetadata?.representationFormatId == "csv")
    }

    @Test func metadataSurvivesCodableRoundTrip() throws {
        let attachment = Attachment.structuredDocument(
            Self.sampleStructuredDocument(filename: "ledger.csv", text: "debit,credit", fileSize: 128)
        )

        let encoded = try JSONEncoder().encode(attachment)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let kind = object["kind"] as? [String: Any] ?? [:]
        let metadata = object["structuredDocumentMetadata"] as? [String: Any] ?? [:]

        #expect(kind["type"] as? String == "document")
        #expect(kind["content"] as? String == "debit,credit")
        #expect(metadata["formatId"] as? String == "csv")

        let decoded = try JSONDecoder().decode(Attachment.self, from: encoded)
        #expect(decoded.documentContent == "debit,credit")
        #expect(decoded.structuredDocumentMetadata == attachment.structuredDocumentMetadata)
    }

    @Test func legacyDocumentDecodesWithoutMetadata() throws {
        let json = """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "kind": {
                "type": "document",
                "filename": "notes.txt",
                "content": "plain fallback",
                "fileSize": 14
              }
            }
            """

        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(decoded.documentContent == "plain fallback")
        #expect(decoded.structuredDocumentMetadata == nil)
    }

    @Test func parseAllAttachesMetadataFromRegistryAdapter() throws {
        DocumentFormatRegistry.shared.register(
            adapter: FixtureAdapter(
                formatId: Self.fixtureFormatId,
                extensions: [Self.fixtureExtension],
                createdAt: Self.createdAt
            )
        )
        defer { DocumentFormatRegistry.shared.unregisterAll(formatId: Self.fixtureFormatId) }

        let url = try writeFile(content: "ignored", ext: Self.fixtureExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachments = try DocumentParser.parseAll(url: url)
        let metadata = attachments.first?.structuredDocumentMetadata

        #expect(attachments.first?.documentContent == "typed fallback")
        #expect(metadata?.formatId == Self.fixtureFormatId)
        #expect(metadata?.representationFormatId == Self.fixtureFormatId)
        #expect(metadata?.filename == url.lastPathComponent)
        #expect(metadata?.createdAt == Self.createdAt)
    }

    private func writeFile(content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-structured-attachment-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func sampleStructuredDocument(
        filename: String = "sample.csv",
        text: String = "sample text",
        fileSize: Int64 = 42
    ) -> StructuredDocument {
        StructuredDocument(
            formatId: "csv",
            filename: filename,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: "csv",
                underlying: PlainTextRepresentation(text: text)
            ),
            textFallback: text,
            createdAt: createdAt
        )
    }

    private struct FixtureAdapter: DocumentFormatAdapter {
        let formatId: String
        let extensions: Set<String>
        let createdAt: Date

        func canHandle(url: URL, uti: String?) -> Bool {
            extensions.contains(url.pathExtension.lowercased())
        }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: 15,
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: "typed fallback")
                ),
                textFallback: "typed fallback",
                createdAt: createdAt
            )
        }
    }
}
