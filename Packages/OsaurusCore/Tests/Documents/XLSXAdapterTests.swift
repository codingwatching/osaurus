//
//  XLSXAdapterTests.swift
//  osaurusTests
//
//  Exercises the dependency-free XLSX reader against an in-test OOXML ZIP.
//  Keeping the fixture generated in code avoids a binary test artifact while
//  still covering the workbook, shared-string, worksheet, and relationship
//  parts real XLSX files use.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("XLSXAdapter")
struct XLSXAdapterTests {

    @Test func canHandle_acceptsXLSXOnly() {
        let adapter = XLSXAdapter()

        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.xlsx"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.XLSX"), uti: nil))
        #expect(
            adapter.canHandle(
                url: URL(fileURLWithPath: "/tmp/no-extension"),
                uti: "org.openxmlformats.spreadsheetml.sheet"
            )
        )
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.xls"), uti: nil) == false)
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.csv"), uti: nil) == false)
    }

    @Test func parse_surfacesTypedWorkbookValuesAndFallbackText() async throws {
        let url = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        guard let workbook = document.representation.underlying as? Workbook else {
            Issue.record("representation was not a Workbook")
            return
        }

        #expect(document.formatId == "xlsx")
        #expect(workbook.sheets.map(\.name) == ["Revenue", "Notes"])
        #expect(workbook.sharedStrings.contains("Month"))
        #expect(workbook.sharedStrings.contains("February"))

        let revenue = try #require(workbook.sheets.first { $0.name == "Revenue" })
        #expect(revenue.cell("A1")?.value == .string("Month"))
        #expect(revenue.cell("B2")?.value == .number(1200))
        #expect(revenue.cell("C2")?.value == .string("inline note"))
        #expect(revenue.cell("C4")?.value == .bool(true))
        #expect(revenue.cell("B4")?.formula == "SUM(B2:B3)")
        #expect(revenue.mergedRanges.map(\.reference).contains("A5:B5"))

        #expect(document.textFallback.contains("## Sheet: Revenue"))
        #expect(document.textFallback.contains("January\t1200\tinline note"))
        #expect(document.textFallback.contains("2500 [=SUM(B2:B3)]"))
        #expect(document.textFallback.contains("Merged: A5:B5"))
    }

    @Test func parse_preservesSheetAndCellAnchors() async throws {
        let url = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        let workbook = try #require(document.representation.underlying as? Workbook)
        let revenue = try #require(workbook.sheets.first { $0.name == "Revenue" })
        let b2 = try #require(revenue.cell("B2"))

        #expect(revenue.anchor.sourceRange?.start.sheetIndex == 0)
        #expect(revenue.anchor.sourceRange?.start.sheetName == "Revenue")
        #expect(b2.anchor.label == "Revenue!B2")
        #expect(b2.anchor.sourceRange?.start.rowIndex == 1)
        #expect(b2.anchor.sourceRange?.start.columnIndex == 1)
        #expect(b2.anchor.textRange?.isEmpty == false)
        #expect(document.structure.elements(kind: .sheet).count == 2)
        #expect(document.structure.elements(kind: .tableCell).contains { $0.anchor.id == b2.anchor.id })
    }

    @Test func parse_recordsFormulaSecuritySignal() async throws {
        let url = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)

        #expect(document.security.inspectionStatus == .partiallyInspected)
        #expect(document.security.activeContentTypes.contains(.formula))
        #expect(document.security.findings.contains { $0.kind == .formula })
    }

    @Test func parse_rejectsOversizedFilesBeforeReadingPackage() async throws {
        let url = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await XLSXAdapter().parse(url: url, sizeLimit: 1)
        }
    }

    @Test func bootstrap_registersXLSXAdapter() {
        let registry = DocumentFormatRegistry()

        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)

        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/workbook.xlsx"))?.formatId == "xlsx")
    }

    // MARK: - Fixture

    private static func writeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-workbook.xlsx")
        try makeWorkbookPackage().write(to: url)
        return url
    }

    private static func makeWorkbookPackage() -> Data {
        makeZip(
            entries: [
                (
                    "[Content_Types].xml",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                      <Default Extension="xml" ContentType="application/xml"/>
                      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                      <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
                      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                      <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                    </Types>
                    """
                ),
                (
                    "_rels/.rels",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
                    </Relationships>
                    """
                ),
                (
                    "xl/workbook.xml",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                      <sheets>
                        <sheet name="Revenue" sheetId="1" r:id="rId1"/>
                        <sheet name="Notes" sheetId="2" r:id="rId2"/>
                      </sheets>
                    </workbook>
                    """
                ),
                (
                    "xl/_rels/workbook.xml.rels",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
                    </Relationships>
                    """
                ),
                (
                    "xl/sharedStrings.xml",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="7" uniqueCount="7">
                      <si><t>Month</t></si>
                      <si><t>Amount</t></si>
                      <si><t>January</t></si>
                      <si><t>February</t></si>
                      <si><t>Total</t></si>
                      <si><t>Approved</t></si>
                      <si><t>Flag</t></si>
                    </sst>
                    """
                ),
                (
                    "xl/worksheets/sheet1.xml",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                      <sheetData>
                        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
                        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1200</v></c><c r="C2" t="inlineStr"><is><t>inline note</t></is></c></row>
                        <row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>1300</v></c></row>
                        <row r="4"><c r="A4" t="s"><v>4</v></c><c r="B4"><f>SUM(B2:B3)</f><v>2500</v></c><c r="C4" t="b"><v>1</v></c></row>
                      </sheetData>
                      <mergeCells count="1"><mergeCell ref="A5:B5"/></mergeCells>
                    </worksheet>
                    """
                ),
                (
                    "xl/worksheets/sheet2.xml",
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                      <sheetData>
                        <row r="1"><c r="A1" t="s"><v>5</v></c><c r="B1" t="b"><v>1</v></c></row>
                        <row r="2"><c r="A2" t="s"><v>6</v></c><c r="B2" t="b"><v>0</v></c></row>
                      </sheetData>
                    </worksheet>
                    """
                ),
            ]
        )
    }

    private static func makeZip(entries: [(path: String, contents: String)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var centralEntries = 0

        for entry in entries {
            let name = Data(entry.path.utf8)
            let payload = Data(entry.contents.utf8)
            let crc = crc32(payload)
            let localHeaderOffset = UInt32(archive.count)

            archive.appendUInt32LE(0x0403_4B50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(UInt32(payload.count))
            archive.appendUInt32LE(UInt32(payload.count))
            archive.appendUInt16LE(UInt16(name.count))
            archive.appendUInt16LE(0)
            archive.append(name)
            archive.append(payload)

            centralDirectory.appendUInt32LE(0x0201_4B50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(UInt32(payload.count))
            centralDirectory.appendUInt32LE(UInt32(payload.count))
            centralDirectory.appendUInt16LE(UInt16(name.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(name)
            centralEntries += 1
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x0605_4B50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(centralEntries))
        archive.appendUInt16LE(UInt16(centralEntries))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32Table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = (0 ..< 256).map { value in
        var crc = UInt32(value)
        for _ in 0 ..< 8 {
            if crc & 1 == 1 {
                crc = 0xEDB8_8320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}

private extension Workbook.Sheet {
    func cell(_ reference: String) -> Workbook.Cell? {
        rows.flatMap(\.cells).first { $0.reference == reference }
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0x00FF),
            UInt8((value >> 8) & 0x00FF),
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0x0000_00FF),
            UInt8((value >> 8) & 0x0000_00FF),
            UInt8((value >> 16) & 0x0000_00FF),
            UInt8((value >> 24) & 0x0000_00FF),
        ])
    }
}
