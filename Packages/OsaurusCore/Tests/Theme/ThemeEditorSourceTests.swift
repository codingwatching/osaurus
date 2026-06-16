// Copyright © 2026 osaurus.

import Foundation
import Testing

@Suite("Theme editor source")
struct ThemeEditorSourceTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Theme/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("theme editor exposes button colors and previews affected controls")
    func buttonColorsAreEditableAndPreviewed() throws {
        let source = try Self.source("Views/Theme/ThemeEditorView.swift")

        #expect(source.contains(#"colorRow("Button BG", hex: $editingTheme.colors.buttonBackground)"#))
        #expect(source.contains(#"colorRow("Button Border", hex: $editingTheme.colors.buttonBorder)"#))
        #expect(source.contains("previewButtonTray"))
        #expect(source.contains("theme.colors.buttonBackground"))
        #expect(source.contains("theme.colors.buttonBorder"))
        #expect(source.contains("previewToast"))
        #expect(source.contains("struct ThemeSample"))
    }
}
