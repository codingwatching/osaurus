//
//  PDFPPTXWorkflowServiceTests.swift
//  osaurusTests
//
//  Exercises the workflow layer that turns typed PDF/PPTX reads into bounded
//  previews and explicit creation availability diagnostics.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PDFPPTXWorkflowService")
struct PDFPPTXWorkflowServiceTests {

    @Test func pdfPreviewSummarizesPagesTablesAndMissingEmitter() throws {
        let document = Self.pdfDocument()
        let service = PDFPPTXWorkflowService(registry: DocumentFormatRegistry())

        let preview = try service.preview(document)
        guard case let .pdf(pdf) = preview else {
            Issue.record("Expected PDF preview")
            return
        }

        #expect(pdf.filename == "report.pdf")
        #expect(pdf.pageCount == 2)
        #expect(pdf.sampledPageCount == 2)
        #expect(pdf.tableCount == 1)
        #expect(pdf.tableCellCount == 4)
        #expect(pdf.creationAvailability.reasonCode == .missingEmitter)
        #expect(pdf.creationAvailability.isAvailable == false)

        let page = try #require(pdf.pages.first)
        #expect(page.pageIndex == 0)
        #expect(page.text.text.contains("Revenue by region"))
        #expect(page.tableCount == 1)
        #expect(page.tables.first?.sourceKind == .pdfPage)
        #expect(page.tables.first?.rowCount == 2)
        #expect(page.tables.first?.columnCount == 2)
        #expect(page.tables.first?.sampleRows.first?.cells.map(\.text.text) == ["Region", "Revenue"])
    }

    @Test func presentationPreviewSummarizesSlidesNotesTablesAndHiddenState() throws {
        let document = Self.presentationDocument()
        let service = PDFPPTXWorkflowService(registry: DocumentFormatRegistry())

        let preview = try service.preview(document)
        guard case let .presentation(presentation) = preview else {
            Issue.record("Expected presentation preview")
            return
        }

        #expect(presentation.filename == "roadmap.pptx")
        #expect(presentation.kind == .presentation)
        #expect(presentation.slideCount == 2)
        #expect(presentation.hiddenSlideCount == 1)
        #expect(presentation.speakerNotesCount == 1)
        #expect(presentation.tableCount == 1)
        #expect(presentation.tableCellCount == 4)
        #expect(presentation.creationAvailability.reasonCode == .missingEmitter)

        let firstSlide = try #require(presentation.slides.first)
        #expect(firstSlide.slideNumber == 1)
        #expect(firstSlide.text.text == "Roadmap\nNext steps")
        #expect(firstSlide.speakerNotes?.text == "Mention pilot feedback")
        #expect(firstSlide.tables.first?.sourceKind == .presentationSlide)
        #expect(firstSlide.tables.first?.sampleRows.last?.cells.map(\.text.text) == ["Q2", "Workbook workflow"])

        let hiddenSlide = try #require(presentation.slides.last)
        #expect(hiddenSlide.isHidden)
    }

    @Test func previewPolicyCapsPagesSlidesRowsColumnsAndText() throws {
        let document = Self.pdfDocument(
            firstPageText: "Long page text that should be truncated",
            cellText: "oversized-cell-value"
        )
        let service = PDFPPTXWorkflowService(registry: DocumentFormatRegistry())
        let policy = PDFPPTXPreviewPolicy(
            maxSections: 1,
            maxTablesPerSection: 1,
            maxRowsPerTable: 1,
            maxColumnsPerTable: 1,
            maxTextPreviewUTF16Units: 9,
            maxCellTextUTF16Units: 8
        )

        let preview = try service.preview(document, policy: policy)
        guard case let .pdf(pdf) = preview else {
            Issue.record("Expected PDF preview")
            return
        }

        #expect(pdf.sampledPageCount == 1)
        #expect(pdf.isPageSampleTruncated)
        let page = try #require(pdf.pages.first)
        #expect(page.text.text == "Long page")
        #expect(page.text.isTruncated)
        let table = try #require(page.tables.first)
        #expect(table.sampleRows.count == 1)
        #expect(table.isRowSampleTruncated)
        #expect(table.isColumnSampleTruncated)
        let cell = try #require(table.sampleRows.first?.cells.first)
        #expect(cell.text.text == "oversize")
        #expect(cell.text.isTruncated)
    }

    @Test func creationAvailabilityUsesRegisteredStructuredEmitter() {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: FakePDFEmitter())
        let service = PDFPPTXWorkflowService(registry: registry)

        let availability = service.creationAvailability(for: Self.pdfDocument())

        #expect(availability.reasonCode == .available)
        #expect(availability.emitterFormatId == "pdf")
        #expect(availability.isAvailable)
    }

    @Test func unsupportedDocumentReportsUnsupportedAvailabilityAndPreviewError() throws {
        let service = PDFPPTXWorkflowService(registry: DocumentFormatRegistry())
        let document = StructuredDocument(
            formatId: "plaintext",
            filename: "note.txt",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: "plaintext",
                underlying: PlainTextRepresentation(text: "hello")
            ),
            textFallback: "hello"
        )

        #expect(service.creationAvailability(for: document).reasonCode == .unsupportedFormat)

        do {
            _ = try service.preview(document)
            Issue.record("Expected unsupported representation error")
        } catch let error as PDFPPTXWorkflowError {
            #expect(error == .unsupportedRepresentation(formatId: "plaintext"))
        }
    }

    // MARK: - Fixtures

    private static func pdfDocument(
        firstPageText: String = "Revenue by region\nNorth 120\nSouth 90",
        cellText: String = "Region"
    ) -> StructuredDocument {
        let pageBounds = box(width: 612, height: 792, space: .page)
        let tableBounds = box(x: 32, y: 120, width: 400, height: 80, space: .page)
        let rowBounds = box(x: 32, y: 120, width: 400, height: 40, space: .page)
        let cellBounds = box(x: 32, y: 120, width: 200, height: 40, space: .page)
        let table = PDFTable(
            pageIndex: 0,
            index: 0,
            rows: [
                PDFTableRow(
                    index: 0,
                    cells: [
                        PDFTableCell(
                            rowIndex: 0,
                            columnIndex: 0,
                            text: cellText,
                            bounds: cellBounds,
                            anchor: anchor(kind: .cell, components: [.page(0), .table(0), .row(0), .cell(0)])
                        ),
                        PDFTableCell(
                            rowIndex: 0,
                            columnIndex: 1,
                            text: "Revenue",
                            bounds: cellBounds,
                            anchor: anchor(kind: .cell, components: [.page(0), .table(0), .row(0), .cell(1)])
                        ),
                    ],
                    bounds: rowBounds,
                    anchor: anchor(kind: .row, components: [.page(0), .table(0), .row(0)])
                ),
                PDFTableRow(
                    index: 1,
                    cells: [
                        PDFTableCell(
                            rowIndex: 1,
                            columnIndex: 0,
                            text: "North",
                            bounds: cellBounds,
                            anchor: anchor(kind: .cell, components: [.page(0), .table(0), .row(1), .cell(0)])
                        ),
                        PDFTableCell(
                            rowIndex: 1,
                            columnIndex: 1,
                            text: "120",
                            bounds: cellBounds,
                            anchor: anchor(kind: .cell, components: [.page(0), .table(0), .row(1), .cell(1)])
                        ),
                    ],
                    bounds: rowBounds,
                    anchor: anchor(kind: .row, components: [.page(0), .table(0), .row(1)])
                ),
            ],
            bounds: tableBounds,
            anchor: anchor(kind: .table, components: [.page(0), .table(0)])
        )
        let pages = [
            PDFPageRepresentation(
                pageIndex: 0,
                text: firstPageText,
                bounds: pageBounds,
                tables: [table],
                anchor: anchor(kind: .page, components: [.page(0)])
            ),
            PDFPageRepresentation(
                pageIndex: 1,
                text: "Appendix",
                bounds: pageBounds,
                anchor: anchor(kind: .page, components: [.page(1)])
            ),
        ]

        return StructuredDocument(
            formatId: "pdf",
            filename: "report.pdf",
            fileSize: 100,
            representation: AnyStructuredRepresentation(
                formatId: "pdf",
                underlying: PDFDocumentRepresentation(pages: pages)
            ),
            textFallback: pages.map(\.text).joined(separator: "\n\n")
        )
    }

    private static func presentationDocument() -> StructuredDocument {
        let table = PresentationTable(
            index: 0,
            sourcePart: "ppt/slides/slide1.xml",
            anchorId: "slide1/table0",
            rows: [
                PresentationTableRow(
                    index: 0,
                    anchorId: "slide1/table0/row0",
                    cells: [
                        PresentationTableCell(
                            rowIndex: 0,
                            columnIndex: 0,
                            text: "Quarter",
                            paragraphIndexes: [0],
                            anchorId: "slide1/table0/cell0"
                        ),
                        PresentationTableCell(
                            rowIndex: 0,
                            columnIndex: 1,
                            text: "Feature",
                            paragraphIndexes: [1],
                            anchorId: "slide1/table0/cell1"
                        ),
                    ]
                ),
                PresentationTableRow(
                    index: 1,
                    anchorId: "slide1/table0/row1",
                    cells: [
                        PresentationTableCell(
                            rowIndex: 1,
                            columnIndex: 0,
                            text: "Q2",
                            paragraphIndexes: [2],
                            anchorId: "slide1/table0/cell2"
                        ),
                        PresentationTableCell(
                            rowIndex: 1,
                            columnIndex: 1,
                            text: "Workbook workflow",
                            paragraphIndexes: [3],
                            anchorId: "slide1/table0/cell3"
                        ),
                    ]
                ),
            ]
        )
        let slides = [
            PresentationSlide(
                index: 0,
                number: 1,
                sourcePart: "ppt/slides/slide1.xml",
                label: "Slide 1",
                textRuns: [
                    run("Roadmap", paragraphIndex: 0, runIndex: 0, sourcePart: "ppt/slides/slide1.xml"),
                    run("Next steps", paragraphIndex: 1, runIndex: 0, sourcePart: "ppt/slides/slide1.xml"),
                ],
                tables: [table],
                speakerNotes: PresentationSpeakerNotes(
                    sourcePart: "ppt/notesSlides/notesSlide1.xml",
                    anchorId: "slide1/notes",
                    textRuns: [
                        run(
                            "Mention pilot feedback",
                            paragraphIndex: 0,
                            runIndex: 0,
                            sourcePart: "ppt/notesSlides/notesSlide1.xml"
                        )
                    ]
                )
            ),
            PresentationSlide(
                index: 1,
                number: 2,
                sourcePart: "ppt/slides/slide2.xml",
                label: "Slide 2",
                isHidden: true,
                textRuns: [
                    run("Hidden appendix", paragraphIndex: 0, runIndex: 0, sourcePart: "ppt/slides/slide2.xml")
                ]
            ),
        ]
        let presentation = PresentationDocument(
            kind: .presentation,
            sourceName: "roadmap.pptx",
            slides: slides
        )

        return StructuredDocument(
            formatId: "pptx",
            filename: "roadmap.pptx",
            fileSize: 200,
            representation: AnyStructuredRepresentation(
                formatId: "pptx",
                underlying: presentation
            ),
            textFallback: slides.map(\.text).joined(separator: "\n\n")
        )
    }

    private static func run(
        _ text: String,
        paragraphIndex: Int,
        runIndex: Int,
        sourcePart: String
    ) -> PresentationTextRun {
        PresentationTextRun(
            text: text,
            paragraphIndex: paragraphIndex,
            runIndex: runIndex,
            sourcePart: sourcePart,
            anchorId: "\(sourcePart)#p\(paragraphIndex)-r\(runIndex)"
        )
    }

    private static func box(
        x: Double = 0,
        y: Double = 0,
        width: Double,
        height: Double,
        space: DocumentBoundingBox.CoordinateSpace
    ) -> DocumentBoundingBox {
        DocumentBoundingBox(x: x, y: y, width: width, height: height, coordinateSpace: space)
    }

    private static func anchor(kind: DocumentAnchor.Kind, components: [AnchorComponent]) -> DocumentAnchor {
        var path: [DocumentAnchor.PathComponent] = [.init(kind: .document)]
        for component in components {
            path.append(component.pathComponent)
        }
        return DocumentAnchor(
            kind: kind,
            path: path,
            sourceRange: sourceRange(for: components),
            label: kind.rawValue
        )
    }

    private static func sourceRange(for components: [AnchorComponent]) -> DocumentSourceRange? {
        guard let page = components.compactMap(\.pageIndex).first else { return nil }
        return DocumentSourceRange(start: .page(page))
    }

    private enum AnchorComponent {
        case page(Int)
        case table(Int)
        case row(Int)
        case cell(Int)

        var pageIndex: Int? {
            if case let .page(index) = self { return index }
            return nil
        }

        var pathComponent: DocumentAnchor.PathComponent {
            switch self {
            case let .page(index):
                return .init(kind: .page, index: index)
            case let .table(index):
                return .init(kind: .table, index: index)
            case let .row(index):
                return .init(kind: .row, index: index)
            case let .cell(index):
                return .init(kind: .cell, index: index)
            }
        }
    }

    private struct FakePDFEmitter: DocumentFormatEmitter {
        let formatId = "pdf"

        func canEmit(_ document: StructuredDocument) -> Bool {
            document.representation.underlying is PDFDocumentRepresentation
        }

        func emit(_ document: StructuredDocument, to url: URL) async throws {}
    }
}
