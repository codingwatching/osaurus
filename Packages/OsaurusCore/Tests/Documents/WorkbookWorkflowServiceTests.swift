//
//  WorkbookWorkflowServiceTests.swift
//  osaurusTests
//
//  Pins the workbook workflow layer that sits between typed workbook
//  representations and explicit export/plugin surfaces.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workbook workflow service")
struct WorkbookWorkflowServiceTests {

    @Test func inspectReportsCountsValidationAndEmitterAvailability() throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let document = Self.document(workbook: Self.workbook(includeFormula: true))

        let inspection = try WorkbookWorkflowService.inspect(document, registry: registry)

        #expect(inspection.sheetSummaries.map(\.name) == ["Revenue", "Notes"])
        #expect(inspection.totalRows == 3)
        #expect(inspection.totalCells == 5)
        #expect(inspection.formulaCellCount == 1)
        #expect(inspection.mergedRangeCount == 1)
        #expect(inspection.exportAvailability.reason == .invalidWorkbook)
        #expect(inspection.validationIssues.contains { $0.code == .formulaNotWritable })
    }

    @Test func exportWritesXLSXThroughRegisteredEmitterAndRoundTrips() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await WorkbookWorkflowService.export(
            Self.document(workbook: Self.workbook()),
            to: url,
            registry: registry
        )

        #expect(result.formatId == "xlsx")
        #expect(result.bytesWritten > 0)
        #expect(result.inspection.exportAvailability.canExport)

        let parsed = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        let parsedWorkbook = try #require(parsed.representation.underlying as? Workbook)
        let revenue = try #require(parsedWorkbook.sheets.first { $0.name == "Revenue" })
        #expect(revenue.cell("A1")?.value == .string("Month"))
        #expect(revenue.cell("B2")?.value == .number(1200))
        #expect(revenue.mergedRanges.map(\.reference) == ["A3:B3"])
    }

    @Test func exportRequiresRegisteredEmitterWithoutTouchingTarget() async throws {
        let registry = DocumentFormatRegistry()
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await WorkbookWorkflowService.export(
                Self.document(workbook: Self.workbook()),
                to: url,
                registry: registry
            )
            Issue.record("expected missing emitter error")
        } catch WorkbookWorkflowError.missingEmitter(let formatId) {
            #expect(formatId == "xlsx")
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } catch {
            Issue.record("expected missing emitter error, got \(error)")
        }
    }

    @Test func validationSurfacesReferencesRangesBoundsAndFormulaErrors() {
        let workbook = Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Bad",
                    index: 0,
                    rows: [
                        Self.row(
                            number: 1,
                            sheetName: "Bad",
                            sheetIndex: 0,
                            cells: [
                                Self.cell(
                                    "B2",
                                    row: 1,
                                    column: 1,
                                    value: .string("mismatch\u{0001}"),
                                    sheetName: "Bad",
                                    sheetIndex: 0
                                ),
                                Self.cell(
                                    "C1",
                                    row: 1,
                                    column: 3,
                                    value: .number(.infinity),
                                    formula: "SUM(A1:A1)",
                                    sheetName: "Bad",
                                    sheetIndex: 0
                                ),
                            ]
                        )
                    ],
                    mergedRanges: [Workbook.CellRange(reference: "B2:A1")],
                    anchor: Self.sheetAnchor(name: "Bad", index: 0)
                )
            ]
        )

        let issues = WorkbookWorkflowService.validationIssues(
            for: workbook,
            policy: WorkbookExportPolicy(maxCells: 1, maxMergedRanges: 0)
        )
        let codes = Set<WorkbookValidationIssue.Code>(issues.map(\.code))

        #expect(codes.contains(.invalidCellReference))
        #expect(codes.contains(.invalidXMLText))
        #expect(codes.contains(.formulaNotWritable))
        #expect(codes.contains(.nonFiniteNumber))
        #expect(codes.contains(.invalidMergedRange))
        #expect(codes.contains(.tooManyCells))
        #expect(codes.contains(.tooManyMergedRanges))
    }

    private static func document(workbook: Workbook) -> StructuredDocument {
        StructuredDocument(
            formatId: "xlsx",
            filename: "workbook.xlsx",
            fileSize: 0,
            representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
            security: .notInspected(
                formatId: "xlsx",
                fileExtension: "xlsx",
                sourceTrust: .generatedArtifact
            ),
            textFallback: ""
        )
    }

    private static func workbook(includeFormula: Bool = false) -> Workbook {
        Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Revenue",
                    index: 0,
                    rows: [
                        row(
                            number: 1,
                            sheetName: "Revenue",
                            sheetIndex: 0,
                            cells: [
                                cell(
                                    "A1",
                                    row: 1,
                                    column: 1,
                                    value: .string("Month"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                                cell(
                                    "B1",
                                    row: 1,
                                    column: 2,
                                    value: .string("Amount"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                            ]
                        ),
                        row(
                            number: 2,
                            sheetName: "Revenue",
                            sheetIndex: 0,
                            cells: [
                                cell(
                                    "A2",
                                    row: 2,
                                    column: 1,
                                    value: .string("January"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                                cell(
                                    "B2",
                                    row: 2,
                                    column: 2,
                                    value: .number(1200),
                                    formula: includeFormula ? "SUM(B2:B2)" : nil,
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                            ]
                        ),
                    ],
                    mergedRanges: [Workbook.CellRange(reference: "A3:B3")],
                    anchor: sheetAnchor(name: "Revenue", index: 0)
                ),
                Workbook.Sheet(
                    name: "Notes",
                    index: 1,
                    rows: [
                        row(
                            number: 1,
                            sheetName: "Notes",
                            sheetIndex: 1,
                            cells: [
                                cell(
                                    "A1",
                                    row: 1,
                                    column: 1,
                                    value: .string("Owner"),
                                    sheetName: "Notes",
                                    sheetIndex: 1
                                )
                            ]
                        )
                    ],
                    anchor: sheetAnchor(name: "Notes", index: 1)
                ),
            ]
        )
    }

    private static func row(
        number: Int,
        sheetName: String,
        sheetIndex: Int,
        cells: [Workbook.Cell]
    ) -> Workbook.Row {
        Workbook.Row(
            number: number,
            cells: cells,
            anchor: DocumentAnchor(
                kind: .row,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                    .init(kind: .row, index: number - 1),
                ],
                sourceRange: DocumentSourceRange(
                    start: DocumentSourceLocation(sheetIndex: sheetIndex, sheetName: sheetName, rowIndex: number - 1)
                ),
                label: "\(sheetName) row \(number)"
            )
        )
    }

    private static func cell(
        _ reference: String,
        row: Int,
        column: Int,
        value: Workbook.CellValue,
        formula: String? = nil,
        sheetName: String,
        sheetIndex: Int
    ) -> Workbook.Cell {
        Workbook.Cell(
            reference: reference,
            rowNumber: row,
            columnNumber: column,
            value: value,
            formula: formula,
            anchor: DocumentAnchor(
                kind: .cell,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                    .init(kind: .cell, identifier: reference),
                ],
                sourceRange: DocumentSourceRange(
                    start: .cell(sheetName: sheetName, rowIndex: row - 1, columnIndex: column - 1)
                ),
                label: "\(sheetName)!\(reference)"
            )
        )
    }

    private static func sheetAnchor(name: String, index: Int) -> DocumentAnchor {
        DocumentAnchor(
            kind: .sheet,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: name, index: index),
            ],
            sourceRange: DocumentSourceRange(
                start: DocumentSourceLocation(sheetIndex: index, sheetName: name)
            ),
            label: name,
            metadata: ["sheetIndex": "\(index)"]
        )
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-workflow.xlsx")
    }
}

private extension Workbook.Sheet {
    func cell(_ reference: String) -> Workbook.Cell? {
        rows.flatMap(\.cells).first { $0.reference == reference }
    }
}
