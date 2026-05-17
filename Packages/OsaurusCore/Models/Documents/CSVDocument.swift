//
//  CSVDocument.swift
//  osaurus
//
//  Typed CSV/TSV representation for the document adapter stack. The
//  normalized text fallback is still what chat ingress consumes, but the
//  row/cell model keeps enough source identity for later table-aware tools
//  to reason about the original delimited text without reparsing it.
//

import Foundation

/// Delimited text uses a tiny delimiter enum so a TSV table can share the
/// same row/cell model as CSV while preserving the user's source format.
public enum CSVDelimiter: String, Codable, Equatable, Hashable, Sendable {
    case comma = ","
    case tab = "\t"

    public var formatId: String {
        switch self {
        case .comma: return "csv"
        case .tab: return "tsv"
        }
    }

    public var fileExtension: String {
        formatId
    }
}

/// A parsed cell stores both normalized cell text and source/fallback ranges
/// because quoting and escaped quotes make byte-equivalent reconstruction
/// lossy once the user-facing text fallback is generated.
public struct CSVCell: Codable, Equatable, Hashable, Sendable {
    public let rowIndex: Int
    public let columnIndex: Int
    public let text: String
    public let wasQuoted: Bool
    public let sourceRange: DocumentTextRange
    public let textRange: DocumentTextRange
    public let anchorId: String

    public init(
        rowIndex: Int,
        columnIndex: Int,
        text: String,
        wasQuoted: Bool,
        sourceRange: DocumentTextRange,
        textRange: DocumentTextRange,
        anchorId: String
    ) {
        precondition(rowIndex >= 0, "CSV row index must be non-negative")
        precondition(columnIndex >= 0, "CSV column index must be non-negative")
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.text = text
        self.wasQuoted = wasQuoted
        self.sourceRange = sourceRange
        self.textRange = textRange
        self.anchorId = anchorId
    }
}

/// Rows are first-class because blank lines are meaningful in delimited text
/// imports and because row anchors let later table tools cite entire records.
public struct CSVRow: Codable, Equatable, Hashable, Sendable {
    public let rowIndex: Int
    public let cells: [CSVCell]
    public let sourceRange: DocumentTextRange
    public let textRange: DocumentTextRange
    public let anchorId: String

    public init(
        rowIndex: Int,
        cells: [CSVCell],
        sourceRange: DocumentTextRange,
        textRange: DocumentTextRange,
        anchorId: String
    ) {
        precondition(rowIndex >= 0, "CSV row index must be non-negative")
        self.rowIndex = rowIndex
        self.cells = cells
        self.sourceRange = sourceRange
        self.textRange = textRange
        self.anchorId = anchorId
    }
}

/// The adapter's typed payload keeps the parsed table plus the exact delimiter
/// and UTF-16 source length so callers can validate anchors against the source
/// string if they still have access to the file contents.
public struct CSVDocument: StructuredRepresentation, Codable, Equatable, Sendable {
    public let delimiter: CSVDelimiter
    public let rows: [CSVRow]
    public let sourceTextLengthUTF16: Int
    public let textFallback: String

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.map(\.cells.count).max() ?? 0 }

    public init(
        delimiter: CSVDelimiter,
        rows: [CSVRow],
        sourceTextLengthUTF16: Int,
        textFallback: String
    ) {
        precondition(sourceTextLengthUTF16 >= 0, "CSV source text length must be non-negative")
        self.delimiter = delimiter
        self.rows = rows
        self.sourceTextLengthUTF16 = sourceTextLengthUTF16
        self.textFallback = textFallback
    }
}
