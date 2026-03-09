//
//  WorkExecutionEngineTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkExecutionEngineTests {

    @Test func truncateToolResult_shortResult_unchanged() async {
        let engine = WorkExecutionEngine()
        let short = String(repeating: "a", count: 100)
        let result = await engine.truncateToolResult(short)
        #expect(result == short)
    }

    @Test func truncateToolResult_exactLimit_unchanged() async {
        let engine = WorkExecutionEngine()
        let exact = String(repeating: "b", count: 8000)
        let result = await engine.truncateToolResult(exact)
        #expect(result == exact)
    }

    @Test func truncateToolResult_longResult_truncatedWithMarker() async {
        let engine = WorkExecutionEngine()
        let long = String(repeating: "c", count: 20000)
        let result = await engine.truncateToolResult(long)
        #expect(result.count < 20000)
        #expect(result.contains("[... 12000 characters omitted"))
        #expect(result.hasPrefix(String(repeating: "c", count: 6000)))
        #expect(result.hasSuffix(String(repeating: "c", count: 2000)))
    }
}
