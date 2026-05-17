//
//  DocumentStructureTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("DocumentStructure")
struct DocumentStructureTests {
    @Test func plainText_buildsRootAndBodyAnchorWithUTF16Range() {
        let text = "A😀B"
        let structure = DocumentStructure.plainText(filename: "note.txt", text: text)

        #expect(structure.root.kind == .document)
        #expect(structure.anchor(id: "document")?.label == "note.txt")
        #expect(structure.anchor(id: "document/body")?.textRange == .entireText(text))
        #expect(structure.textLengthUTF16 == text.utf16.count)
        #expect(structure.elements(kind: .paragraph).first?.text == text)
    }

    @Test func paginatedText_preservesPageSourceAndFallbackOffsets() {
        let structure = DocumentStructure.paginatedText(
            filename: "fixture.pdf",
            pages: [
                DocumentPageText(pageIndex: 0, text: "first"),
                DocumentPageText(pageIndex: 2, text: "second😀"),
            ]
        )

        let pages = structure.elements(kind: .page)
        #expect(pages.count == 2)
        #expect(pages[0].anchor.sourceRange?.start.pageIndex == 0)
        #expect(pages[0].anchor.textRange == DocumentTextRange(startUTF16Offset: 0, length: "first".utf16.count))
        #expect(pages[1].anchor.sourceRange?.start.pageIndex == 2)
        #expect(pages[1].anchor.textRange?.startUTF16Offset == "first\n\n".utf16.count)
        #expect(structure.textLengthUTF16 == "first\n\nsecond😀".utf16.count)
    }
}
