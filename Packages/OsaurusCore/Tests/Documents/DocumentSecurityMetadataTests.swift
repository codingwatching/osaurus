//
//  DocumentSecurityMetadataTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("DocumentSecurityMetadata")
struct DocumentSecurityMetadataTests {
    @Test func localFileSecurityMetadata_recordsDigestAndType() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: "plaintext"
        )

        #expect(metadata.inspectionStatus == .inspected)
        #expect(metadata.sourceTrust == .userSelectedLocalFile)
        #expect(metadata.fileExtension == "txt")
        #expect(metadata.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(metadata.findings.isEmpty)
    }

    @Test func htmlSecuritySignals_detectsScriptsAndExternalResources() {
        let html = """
            <html>
              <head><script src="https://example.com/app.js"></script></head>
              <body>
                <img src="https://example.com/image.png">
                <a href="javascript:alert(1)">bad</a>
              </body>
            </html>
            """

        let signals = DocumentFileInspector.htmlSecuritySignals(rawHTML: html)

        #expect(signals.activeContentTypes.contains(.script))
        #expect(signals.activeContentTypes.contains(.externalReference))
        #expect(signals.findings.contains { $0.kind == .script })
        #expect(signals.externalReferences.contains { $0.kind == .script })
        #expect(signals.externalReferences.contains { $0.kind == .image })
    }
}
