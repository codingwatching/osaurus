//
//  MethodToolsTests.swift
//  osaurus
//
//  Tests for Method agent tools: verifies parameter validation and
//  error paths that don't require full service initialization.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MethodsSaveToolTests {

    @Test func rejectsMissingName() async throws {
        let tool = MethodsSaveTool()
        let result = try await tool.execute(argumentsJSON: "{\"description\": \"test\"}")
        #expect(result.contains("Error"))
    }

    @Test func rejectsMissingDescription() async throws {
        let tool = MethodsSaveTool()
        let result = try await tool.execute(argumentsJSON: "{\"name\": \"test\"}")
        #expect(result.contains("Error"))
    }

    @Test func rejectsWhitespaceOnlyName() async throws {
        let tool = MethodsSaveTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"name\": \"   \", \"description\": \"valid desc\"}"
        )
        #expect(result.contains("Error"))
        #expect(result.contains("blank"))
    }

    @Test func rejectsWhitespaceOnlyDescription() async throws {
        let tool = MethodsSaveTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"name\": \"valid-name\", \"description\": \"  \\n  \"}"
        )
        #expect(result.contains("Error"))
        #expect(result.contains("blank"))
    }

    @Test func rejectsEmptyName() async throws {
        let tool = MethodsSaveTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"name\": \"\", \"description\": \"valid desc\"}"
        )
        #expect(result.contains("Error"))
        #expect(result.contains("blank"))
    }

    @Test func rejectsEmptyDescription() async throws {
        let tool = MethodsSaveTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"name\": \"valid-name\", \"description\": \"\"}"
        )
        #expect(result.contains("Error"))
        #expect(result.contains("blank"))
    }
}

struct MethodsReportToolTests {

    @Test func rejectsMissingId() async throws {
        let tool = MethodsReportTool()
        let result = try await tool.execute(argumentsJSON: "{\"outcome\": \"succeeded\"}")
        #expect(result.contains("Error"))
    }

    @Test func rejectsInvalidOutcome() async throws {
        let tool = MethodsReportTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"id\": \"some-id\", \"outcome\": \"invalid\"}"
        )
        #expect(result.contains("Error"))
    }

    @Test func rejectsMissingOutcome() async throws {
        let tool = MethodsReportTool()
        let result = try await tool.execute(argumentsJSON: "{\"id\": \"some-id\"}")
        #expect(result.contains("Error"))
    }
}
