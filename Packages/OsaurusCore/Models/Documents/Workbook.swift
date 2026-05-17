//
//  Workbook.swift
//  osaurus
//
//  Typed workbook representation for spreadsheet readers. The first XLSX
//  adapter only fills the stable cell surface that can be extracted without
//  style evaluation: sheet order/names, sparse rows, scalar cell values, and
//  formula source text. Styling, number formats, charts, and workbook-level
//  calculation metadata stay outside this model until a later fidelity slice
//  can preserve them without guessing.
//

import Foundation

/// Spreadsheet-native representation carried by `StructuredDocument` so XLSX
/// ingestion can preserve cell identity while the legacy attachment flow keeps
/// consuming a plain-text fallback.
public struct Workbook: StructuredRepresentation, Codable, Equatable, Sendable {
    public let sheets: [Sheet]
    public let sharedStrings: [String]

    public init(sheets: [Sheet], sharedStrings: [String] = []) {
        self.sheets = sheets
        self.sharedStrings = sharedStrings
    }

    /// A worksheet is anchored separately from its cells so callers can cite a
    /// whole tab even when a prompt only includes its rendered text fallback.
    public struct Sheet: Codable, Equatable, Sendable {
        public let name: String
        public let index: Int
        public let rows: [Row]
        public let mergedRanges: [CellRange]
        public let anchor: DocumentAnchor

        public init(
            name: String,
            index: Int,
            rows: [Row],
            mergedRanges: [CellRange] = [],
            anchor: DocumentAnchor
        ) {
            precondition(index >= 0, "Workbook sheet index must be non-negative")
            self.name = name
            self.index = index
            self.rows = rows
            self.mergedRanges = mergedRanges
            self.anchor = anchor
        }
    }

    /// XLSX rows are sparse; `number` preserves the one-based worksheet row
    /// reference instead of implying that array position equals source row.
    public struct Row: Codable, Equatable, Sendable {
        public let number: Int
        public let cells: [Cell]
        public let anchor: DocumentAnchor

        public init(number: Int, cells: [Cell], anchor: DocumentAnchor) {
            precondition(number >= 1, "Workbook row number must be one-based")
            self.number = number
            self.cells = cells
            self.anchor = anchor
        }
    }

    /// A cell keeps both its A1 reference and numeric coordinates because text
    /// citations prefer A1 while source anchors need stable row/column indexes.
    public struct Cell: Codable, Equatable, Sendable {
        public let reference: String
        public let rowNumber: Int
        public let columnNumber: Int
        public let value: CellValue
        public let formula: String?
        public let anchor: DocumentAnchor

        public init(
            reference: String,
            rowNumber: Int,
            columnNumber: Int,
            value: CellValue,
            formula: String? = nil,
            anchor: DocumentAnchor
        ) {
            precondition(rowNumber >= 1, "Workbook cell row number must be one-based")
            precondition(columnNumber >= 1, "Workbook cell column number must be one-based")
            self.reference = reference
            self.rowNumber = rowNumber
            self.columnNumber = columnNumber
            self.value = value
            self.formula = formula
            self.anchor = anchor
        }
    }

    /// Scalar cell values intentionally avoid date/style inference. Most XLSX
    /// writers encode dates as numbers plus styles, and guessing at this layer
    /// would make typed output less trustworthy than the source package.
    public enum CellValue: Codable, Equatable, Sendable {
        case empty
        case number(Double)
        case string(String)
        case bool(Bool)

        public var fallbackText: String {
            switch self {
            case .empty:
                return ""
            case .number(let value):
                return value.isFinite
                    && value >= Double(Int64.min)
                    && value <= Double(Int64.max)
                    && value.rounded(.towardZero) == value
                    ? String(Int64(value))
                    : String(value)
            case .string(let value):
                return value
            case .bool(let value):
                return value ? "TRUE" : "FALSE"
            }
        }
    }

    /// Merged ranges stay as A1 strings for now because the reader does not yet
    /// need to split or validate range endpoints to preserve source identity.
    public struct CellRange: Codable, Equatable, Hashable, Sendable {
        public let reference: String

        public init(reference: String) {
            self.reference = reference
        }
    }
}
