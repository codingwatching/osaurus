//
//  DocumentStructure.swift
//  osaurus
//
//  Format-neutral document structure used by adapters that can preserve
//  layout and source identity. Existing plain-text adapters can publish a
//  shallow tree today; PDF/DOCX/XLSX/PPTX lanes can replace those leaves with
//  richer page, table, cell, slide, and shape subtrees without changing the
//  registry or attachment boundary.
//

import Foundation

public struct DocumentElementAttributes: Codable, Equatable, Hashable, Sendable {
    public let role: String?
    public let level: Int?
    public let styleName: String?
    public let languageCode: String?
    public let isHidden: Bool
    public let metadata: [String: String]

    public init(
        role: String? = nil,
        level: Int? = nil,
        styleName: String? = nil,
        languageCode: String? = nil,
        isHidden: Bool = false,
        metadata: [String: String] = [:]
    ) {
        if let level {
            precondition(level >= 0, "Document element level must be non-negative")
        }
        self.role = role
        self.level = level
        self.styleName = styleName
        self.languageCode = languageCode
        self.isHidden = isHidden
        self.metadata = metadata
    }
}

public struct DocumentElement: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case document
        case section
        case page
        case slide
        case sheet
        case paragraph
        case heading
        case list
        case listItem
        case table
        case tableRow
        case tableCell
        case run
        case image
        case chart
        case shape
        case textBox
        case speakerNotes
        case metadata
        case unknown
    }

    public let id: String
    public let kind: Kind
    public let anchor: DocumentAnchor
    public let text: String?
    public let attributes: DocumentElementAttributes
    public let children: [DocumentElement]

    public init(
        id: String? = nil,
        kind: Kind,
        anchor: DocumentAnchor,
        text: String? = nil,
        attributes: DocumentElementAttributes = .init(),
        children: [DocumentElement] = []
    ) {
        self.id = id ?? anchor.id
        self.kind = kind
        self.anchor = anchor
        self.text = text
        self.attributes = attributes
        self.children = children
    }
}

public struct DocumentPageText: Codable, Equatable, Hashable, Sendable {
    public let pageIndex: Int
    public let text: String

    public init(pageIndex: Int, text: String) {
        precondition(pageIndex >= 0, "Document page index must be non-negative")
        self.pageIndex = pageIndex
        self.text = text
    }
}

public struct DocumentStructure: Codable, Equatable, Sendable {
    public let root: DocumentElement
    public let anchors: [DocumentAnchor]
    public let textLengthUTF16: Int

    public init(
        root: DocumentElement,
        anchors: [DocumentAnchor]? = nil,
        textLengthUTF16: Int? = nil
    ) {
        self.root = root
        self.anchors = Self.deduplicated(anchors ?? root.collectedAnchors())
        self.textLengthUTF16 = textLengthUTF16 ?? Self.derivedTextLength(from: self.anchors)
    }

    public func anchor(id: String) -> DocumentAnchor? {
        anchors.first { $0.id == id }
    }

    public func elements(kind: DocumentElement.Kind) -> [DocumentElement] {
        root.descendants(matching: kind)
    }

    public static func plainText(filename: String, text: String) -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: filename)
        let textAnchor = DocumentAnchor(
            id: "document/body",
            kind: .text,
            path: [
                .init(kind: .document),
                .init(kind: .text, identifier: "body"),
            ],
            textRange: .entireText(text),
            label: filename
        )
        let textElement = DocumentElement(
            kind: .paragraph,
            anchor: textAnchor,
            text: text
        )
        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: [textElement]
        )
        return DocumentStructure(root: root, textLengthUTF16: text.utf16.count)
    }

    public static func paginatedText(filename: String, pages: [DocumentPageText]) -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: filename)
        var offset = 0
        var elements: [DocumentElement] = []

        for page in pages {
            if !elements.isEmpty {
                offset += 2  // Matches the "\n\n" separator in the text fallback.
            }
            let range = DocumentTextRange(startUTF16Offset: offset, length: page.text.utf16.count)
            let anchor = DocumentAnchor(
                kind: .page,
                path: [
                    .init(kind: .document),
                    .init(kind: .page, index: page.pageIndex),
                ],
                textRange: range,
                sourceRange: .init(start: .page(page.pageIndex)),
                label: "Page \(page.pageIndex + 1)"
            )
            elements.append(
                DocumentElement(
                    kind: .page,
                    anchor: anchor,
                    text: page.text,
                    attributes: .init(metadata: ["pageIndex": "\(page.pageIndex)"])
                )
            )
            offset += page.text.utf16.count
        }

        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: elements
        )
        return DocumentStructure(root: root, textLengthUTF16: offset)
    }

    private static func deduplicated(_ anchors: [DocumentAnchor]) -> [DocumentAnchor] {
        var seen: Set<String> = []
        var result: [DocumentAnchor] = []
        for anchor in anchors where !seen.contains(anchor.id) {
            seen.insert(anchor.id)
            result.append(anchor)
        }
        return result
    }

    private static func derivedTextLength(from anchors: [DocumentAnchor]) -> Int {
        anchors.compactMap(\.textRange?.endUTF16Offset).max() ?? 0
    }
}

private extension DocumentElement {
    func collectedAnchors() -> [DocumentAnchor] {
        [anchor] + children.flatMap { $0.collectedAnchors() }
    }

    func descendants(matching kind: DocumentElement.Kind) -> [DocumentElement] {
        let current = self.kind == kind ? [self] : []
        return current + children.flatMap { $0.descendants(matching: kind) }
    }
}
