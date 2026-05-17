import Foundation
import XCTest
@testable import OsaurusCLICore

func temporaryPaths(file: StaticString = #filePath, line: UInt = #line) throws -> CoordinatorPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-coord-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return CoordinatorPaths(root: root)
}

func posixMode(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber, file: file, line: line).intValue & 0o777
}
