import Foundation
import Testing

@testable import OsaurusEvalsKit

struct ComputerUseWebFormProofTests {
    private let rawFieldValues = [
        "Synthetic Platform Team",
        "ops@example.com",
        "Automate a repetitive access request.",
    ]

    @Test func fixturePagesAreStaticAndLocalOnly() throws {
        let fixtureDir = repoRoot()
            .appendingPathComponent("Packages/OsaurusCore/Tests/ComputerUse/Fixtures/WebForm", isDirectory: true)
        let request = try String(
            contentsOf: fixtureDir.appendingPathComponent("request.html"),
            encoding: .utf8
        )
        let submitted = try String(
            contentsOf: fixtureDir.appendingPathComponent("submitted.html"),
            encoding: .utf8
        )
        let combined = request + "\n" + submitted

        #expect(request.contains(#"action="./submitted.html""#))
        #expect(request.contains(#"autocomplete="off""#))
        #expect(request.contains(#"method="post""#))
        #expect(request.contains("form-action 'self'"))
        #expect(submitted.contains(#"href="./request.html""#))

        for forbidden in ["http://", "https://", "fetch(", "XMLHttpRequest", "sendBeacon", "src="] {
            #expect(!combined.localizedCaseInsensitiveContains(forbidden))
        }
        for raw in rawFieldValues {
            #expect(!combined.contains(raw))
        }
    }

    @Test func scriptedWebFormCaseProvesPerceiveGateActVerify() async throws {
        let report = try await runWebFormCase()

        #expect(report.outcome == .passed)
        #expect(report.notes.contains { $0.contains("telemetry:") && $0.contains("acted=5") })
        #expect(report.notes.contains { $0.contains("verifyChanged=5") })
        #expect(report.notes.contains { $0.contains("confirms=1") })
        #expect(report.notes.contains { $0.contains("axResolvableRate: 1.00 (5/5)") })
        #expect(report.notes.contains { $0.contains("verbs: [set_value,set_value,set_value,click,click]") })
        #expect(report.notes.contains { $0.contains("value[team] matched exact expectation") })
        #expect(report.notes.contains { $0.contains("value[status] matched exact expectation") })
        #expect(report.notes.contains { $0.contains("summaryLength=") })
    }

    @Test func webFormReportAndScorecardOmitRawFieldValues() async throws {
        let caseReport = try await runWebFormCase()
        let evalReport = EvalReport(
            modelId: "local-fixture-scripted",
            startedAt: "2026-06-28T00:00:00Z",
            cases: [caseReport]
        )
        let reportJSON = try #require(String(data: evalReport.toJSON(prettyPrinted: true), encoding: .utf8))

        #expect(reportJSON.contains("computer_use_loop.web-form-proof-lab"))
        #expect(reportJSON.contains("verifyChanged=5"))
        #expect(!reportJSON.localizedCaseInsensitiveContains("screenshot"))
        #expect(!reportJSON.localizedCaseInsensitiveContains("base64"))
        for raw in rawFieldValues {
            #expect(!reportJSON.contains(raw))
        }

        let scorecard = ComputerUseScorecardBuilder.build(
            from: [
                ComputerUseScorecardBuilder.InputReport(
                    report: evalReport,
                    path: "build/computer-use-evidence/web-form-proof-report.json"
                )
            ],
            generatedAt: "2026-06-28T00:00:00Z"
        )
        let markdown = scorecard.formatMarkdown()
        let scorecardJSON = try #require(String(data: scorecard.toJSON(prettyPrinted: true), encoding: .utf8))

        #expect(markdown.contains("computer_use_loop.web-form-proof-lab"))
        #expect(scorecardJSON.contains("computer_use_loop.web-form-proof-lab"))
        for raw in rawFieldValues {
            #expect(!markdown.contains(raw))
            #expect(!scorecardJSON.contains(raw))
        }
    }

    private func runWebFormCase() async throws -> EvalCaseReport {
        let suite = try EvalSuite.load(
            from: packageRoot()
                .appendingPathComponent("Suites/ComputerUseLoop", isDirectory: true)
        )
        let testCase = try #require(
            suite.cases.first { $0.id == "computer_use_loop.web-form-proof-lab" }
        )
        #expect(testCase.expect.computerUseLoop?.redactEvidenceValues == true)

        return await EvalRunner.runComputerUseLoopCase(testCase, modelId: "local-fixture-scripted")
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
    }

    private func repoRoot() -> URL {
        packageRoot()
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repository root
    }
}
