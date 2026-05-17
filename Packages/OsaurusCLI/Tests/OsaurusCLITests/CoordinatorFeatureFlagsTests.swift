import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorFeatureFlagsTests: XCTestCase {
    func testLoadMissingFlagsReturnsDefaults() throws {
        let store = CoordinatorFeatureFlagsStore(paths: try temporaryPaths())
        let flags = try store.load()

        XCTAssertEqual(flags["coordinator"], true)
        XCTAssertEqual(flags["heartbeat"], false)
    }

    func testSetPersistsFeatureFlag() throws {
        let paths = try temporaryPaths()
        let store = CoordinatorFeatureFlagsStore(paths: paths)

        _ = try store.set("heartbeat", enabled: true)
        let reloaded = try CoordinatorFeatureFlagsStore(paths: paths).load()

        XCTAssertEqual(reloaded["heartbeat"], true)
    }
}
