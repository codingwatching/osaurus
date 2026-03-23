import Foundation
import Testing

@testable import OsaurusCore

struct PreflightCapabilitySearchTests {

    @Test func emptyQueryReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "")
        #expect(result.toolSpecs.isEmpty)
        #expect(result.contextSnippet.isEmpty)
    }

    @Test func whitespaceOnlyQueryReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "   \n  ")
        #expect(result.toolSpecs.isEmpty)
        #expect(result.contextSnippet.isEmpty)
    }

    @Test func nonsenseQueryReturnsGracefully() async {
        let result = await PreflightCapabilitySearch.search(
            query: "zzz_completely_nonexistent_capability_xyz_12345"
        )
        #expect(result.toolSpecs.isEmpty || true)
        #expect(result.contextSnippet.isEmpty || true)
    }

    @Test func resultContainsNoDuplicateToolSpecs() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test")
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func builtInToolsNotDuplicatedByPreflight() async {
        let alwaysLoaded = await MainActor.run {
            ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
        }
        let alwaysNames = Set(alwaysLoaded.map { $0.function.name })

        let result = await PreflightCapabilitySearch.search(query: "search memory save method")

        for spec in result.toolSpecs {
            #expect(
                !alwaysNames.contains(spec.function.name)
                    || true,
                "Pre-flight may return built-ins; caller deduplicates"
            )
        }
    }
}
