//
//  ThemeJSONEditorCodecTests.swift
//  osaurusTests
//
//  Focused coverage for the raw JSON theme editor codec.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme JSON editor codec")
struct ThemeJSONEditorCodecTests {
    @Test("encodes pretty sorted JSON and round trips")
    func encodeRoundTripsTheme() throws {
        var theme = CustomTheme.darkDefault
        theme.metadata.name = "Raw JSON Theme"
        theme.metadata.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        theme.metadata.updatedAt = Date(timeIntervalSince1970: 1_700_000_001)
        theme.colors.buttonBackground = "#123456"

        let json = try ThemeJSONEditorCodec.encode(theme)
        let decoded = try ThemeJSONEditorCodec.decode(json)

        #expect(json.contains("\n"))
        #expect(json.contains("\"buttonBackground\" : \"#123456\""))
        #expect(decoded == theme)
    }

    @Test("rejects empty and malformed JSON")
    func rejectsInvalidJSON() {
        #expect(throws: ThemeJSONEditorError.empty) {
            _ = try ThemeJSONEditorCodec.decode("   \n")
        }

        #expect(throws: ThemeJSONEditorError.self) {
            _ = try ThemeJSONEditorCodec.decode(#"{"metadata": true}"#)
        }
    }

    @Test("preserves editor identity fields when applying raw JSON")
    func preservingEditorIdentityKeepsSaveTargetStable() throws {
        var current = CustomTheme.darkDefault
        current.metadata.name = "Current"
        current.isBuiltIn = true

        var pasted = CustomTheme.lightDefault
        pasted.metadata.name = "Pasted"
        pasted.metadata.id = UUID()
        pasted.metadata.createdAt = Date(timeIntervalSince1970: 0)
        pasted.isBuiltIn = false
        pasted.colors.accentColor = "#abcdef"

        let applied = try ThemeJSONEditorCodec.decodePreservingEditorIdentity(
            ThemeJSONEditorCodec.encode(pasted),
            currentTheme: current
        )

        #expect(applied.metadata.id == current.metadata.id)
        #expect(applied.metadata.createdAt == current.metadata.createdAt)
        #expect(applied.isBuiltIn == current.isBuiltIn)
        #expect(applied.metadata.name == "Pasted")
        #expect(applied.colors.accentColor == "#abcdef")
    }
}
