//
//  DocumentAnchor.swift
//  osaurus
//
//  Format-neutral source anchors for structured document I/O. The same
//  anchor model is used by PDF pages, DOCX paragraphs, workbook cells, and
//  presentation shapes so later high-fidelity adapters can reference source
//  locations without leaking a format-specific object graph upward.
//

import Foundation

public struct DocumentTextRange: Codable, Equatable, Hashable, Sendable {
    public let startUTF16Offset: Int
    public let length: Int

    public var endUTF16Offset: Int { startUTF16Offset + length }
    public var isEmpty: Bool { length == 0 }

    public init(startUTF16Offset: Int, length: Int) {
        precondition(startUTF16Offset >= 0, "Document text range start must be non-negative")
        precondition(length >= 0, "Document text range length must be non-negative")
        self.startUTF16Offset = startUTF16Offset
        self.length = length
    }

    public static func entireText(_ text: String) -> DocumentTextRange {
        DocumentTextRange(startUTF16Offset: 0, length: text.utf16.count)
    }
}

public struct DocumentBoundingBox: Codable, Equatable, Hashable, Sendable {
    public enum CoordinateSpace: String, Codable, Sendable {
        case page
        case slide
        case image
        case worksheet
        case unknown
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let coordinateSpace: CoordinateSpace

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        coordinateSpace: CoordinateSpace
    ) {
        precondition(width >= 0, "Document bounding box width must be non-negative")
        precondition(height >= 0, "Document bounding box height must be non-negative")
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.coordinateSpace = coordinateSpace
    }
}

public struct DocumentSourceLocation: Codable, Equatable, Hashable, Sendable {
    public let pageIndex: Int?
    public let slideIndex: Int?
    public let sheetIndex: Int?
    public let sheetName: String?
    public let rowIndex: Int?
    public let columnIndex: Int?
    public let paragraphIndex: Int?
    public let runIndex: Int?
    public let characterOffset: Int?
    public let namedRegion: String?

    public init(
        pageIndex: Int? = nil,
        slideIndex: Int? = nil,
        sheetIndex: Int? = nil,
        sheetName: String? = nil,
        rowIndex: Int? = nil,
        columnIndex: Int? = nil,
        paragraphIndex: Int? = nil,
        runIndex: Int? = nil,
        characterOffset: Int? = nil,
        namedRegion: String? = nil
    ) {
        Self.requireNonNegative(pageIndex, "pageIndex")
        Self.requireNonNegative(slideIndex, "slideIndex")
        Self.requireNonNegative(sheetIndex, "sheetIndex")
        Self.requireNonNegative(rowIndex, "rowIndex")
        Self.requireNonNegative(columnIndex, "columnIndex")
        Self.requireNonNegative(paragraphIndex, "paragraphIndex")
        Self.requireNonNegative(runIndex, "runIndex")
        Self.requireNonNegative(characterOffset, "characterOffset")
        self.pageIndex = pageIndex
        self.slideIndex = slideIndex
        self.sheetIndex = sheetIndex
        self.sheetName = sheetName
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.paragraphIndex = paragraphIndex
        self.runIndex = runIndex
        self.characterOffset = characterOffset
        self.namedRegion = namedRegion
    }

    public static func page(_ index: Int) -> DocumentSourceLocation {
        DocumentSourceLocation(pageIndex: index)
    }

    public static func slide(_ index: Int) -> DocumentSourceLocation {
        DocumentSourceLocation(slideIndex: index)
    }

    public static func cell(sheetName: String? = nil, rowIndex: Int, columnIndex: Int) -> DocumentSourceLocation {
        DocumentSourceLocation(sheetName: sheetName, rowIndex: rowIndex, columnIndex: columnIndex)
    }

    private static func requireNonNegative(_ value: Int?, _ label: String) {
        guard let value else { return }
        precondition(value >= 0, "Document source location \(label) must be non-negative")
    }
}

public struct DocumentSourceRange: Codable, Equatable, Hashable, Sendable {
    public let start: DocumentSourceLocation
    public let end: DocumentSourceLocation?
    public let boundingBox: DocumentBoundingBox?

    public init(
        start: DocumentSourceLocation,
        end: DocumentSourceLocation? = nil,
        boundingBox: DocumentBoundingBox? = nil
    ) {
        self.start = start
        self.end = end
        self.boundingBox = boundingBox
    }
}

public struct DocumentAnchor: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case document
        case section
        case page
        case slide
        case sheet
        case row
        case column
        case cell
        case table
        case paragraph
        case heading
        case list
        case listItem
        case run
        case text
        case image
        case chart
        case shape
        case speakerNotes
        case comment
        case footnote
        case endnote
        case header
        case footer
        case metadata
        case unknown
    }

    public struct PathComponent: Codable, Equatable, Hashable, Sendable {
        public let kind: Kind
        public let identifier: String?
        public let index: Int?

        public init(kind: Kind, identifier: String? = nil, index: Int? = nil) {
            if let index {
                precondition(index >= 0, "Document anchor path index must be non-negative")
            }
            self.kind = kind
            self.identifier = identifier
            self.index = index
        }

        fileprivate var stableFragment: String {
            let raw: String
            if let identifier, !identifier.isEmpty {
                raw = "\(kind.rawValue)=\(identifier)"
            } else if let index {
                raw = "\(kind.rawValue)[\(index)]"
            } else {
                raw = kind.rawValue
            }
            return raw.addingPercentEncoding(withAllowedCharacters: Self.idAllowedCharacters) ?? raw
        }

        private static let idAllowedCharacters: CharacterSet = {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~[]=")
            return allowed
        }()
    }

    public let id: String
    public let kind: Kind
    public let path: [PathComponent]
    public let textRange: DocumentTextRange?
    public let sourceRange: DocumentSourceRange?
    public let label: String?
    public let metadata: [String: String]

    public init(
        id: String? = nil,
        kind: Kind,
        path: [PathComponent],
        textRange: DocumentTextRange? = nil,
        sourceRange: DocumentSourceRange? = nil,
        label: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id ?? Self.stableId(kind: kind, path: path)
        self.kind = kind
        self.path = path
        self.textRange = textRange
        self.sourceRange = sourceRange
        self.label = label
        self.metadata = metadata
    }

    public static func root(label: String? = nil) -> DocumentAnchor {
        DocumentAnchor(
            id: "document",
            kind: .document,
            path: [.init(kind: .document)],
            label: label
        )
    }

    private static func stableId(kind: Kind, path: [PathComponent]) -> String {
        let fragments = [kind.rawValue] + path.map(\.stableFragment)
        return fragments.joined(separator: "/")
    }
}
