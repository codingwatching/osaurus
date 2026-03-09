import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatViewSandboxTests {
    @Test
    func buildToolSpecs_sandboxDisabledExcludesBuiltInSandboxTools() {
        let session = ChatSession()

        withRegisteredSandboxBuiltins {
            let specs = session.buildToolSpecs(
                needsSelection: false,
                hasCapabilities: false,
                overrides: nil,
                executionMode: .none
            )

            #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }) == false)
            #expect(specs.contains(where: { $0.function.name == "sandbox_read_file" }) == false)
        }
    }

    @Test
    func buildToolSpecs_sandboxEnabledKeepsBuiltInsDuringCapabilitySelection() {
        let session = ChatSession()
        session.capabilitiesSelected = true
        session.selectedToolNames = ["search_working_memory"]

        withRegisteredSandboxBuiltins {
            let specs = session.buildToolSpecs(
                needsSelection: false,
                hasCapabilities: true,
                overrides: ["search_working_memory": false],
                executionMode: .sandbox
            )

            #expect(specs.contains(where: { $0.function.name == "search_working_memory" }))
            #expect(specs.contains(where: { $0.function.name == "select_capabilities" }))
            #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }))
        }
    }

    @Test
    func buildSystemPrompt_includesSandboxContextOnlyWhenExpected() {
        let session = ChatSession()

        let standardPrompt = session.buildSystemPrompt(
            base: "Base prompt",
            agentId: Agent.defaultId,
            needsSelection: false,
            executionMode: .none
        )
        let sandboxPrompt = session.buildSystemPrompt(
            base: "Base prompt",
            agentId: Agent.defaultId,
            needsSelection: false,
            executionMode: .sandbox
        )

        #expect(standardPrompt.contains("## Linux Sandbox Environment") == false)
        #expect(sandboxPrompt.contains("## Linux Sandbox Environment"))
        #expect(sandboxPrompt.contains("sandbox_run_script"))
    }

    @Test
    func workSpecs_excludeSelectCapabilitiesTool() {
        let specs = ToolRegistry.shared.workSpecs(withOverrides: nil, mode: .none)

        #expect(specs.contains(where: { $0.function.name == "select_capabilities" }) == false)
    }

    @Test
    func selectableCapabilityLists_excludeSelectCapabilitiesTool() {
        let tools = ToolRegistry.shared.listSelectableCapabilityTools(withOverrides: nil)
        let catalogEntries = ToolRegistry.shared.enabledCatalogEntries()

        #expect(tools.contains(where: { $0.name == "select_capabilities" }) == false)
        #expect(catalogEntries.contains(where: { $0.name == "select_capabilities" }) == false)
    }

    @Test
    func resolveSelection_rejectsInternalChatTools() async throws {
        let result = try await CapabilityService.shared.resolveSelection(
            argumentsJSON: #"{"tools":["select_capabilities"],"skills":[]}"#,
            agentId: Agent.defaultId
        )

        #expect(result.selectedTools.isEmpty)
        #expect(result.errors.contains("Tool 'select_capabilities' not found or not enabled"))
    }

    @Test
    func prepareChatExecutionMode_usesSessionAgentInsteadOfActiveAgent() async {
        let manager = AgentManager.shared
        let registrar = SandboxToolRegistrar.shared
        let originalActiveAgentId = manager.activeAgentId
        let originalStatus = SandboxManager.State.shared.status
        let originalProvisionOverride = registrar.provisionAgentOverride

        let inactiveAgent = Agent(name: "Chat Sandbox Off")
        let sandboxAgent = Agent(
            name: "Chat Sandbox On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        manager.setActiveAgent(inactiveAgent.id)

        SandboxManager.State.shared.status = .running
        registrar.provisionAgentOverride = { _ in }

        let session = ChatSession()
        let inactiveMode = await session.prepareChatExecutionMode(
            agentId: inactiveAgent.id,
            overrides: nil
        )
        let sandboxMode = await session.prepareChatExecutionMode(
            agentId: sandboxAgent.id,
            overrides: nil
        )

        #expect(inactiveMode.usesSandboxTools == false)
        #expect(sandboxMode.usesSandboxTools)

        let specs = session.buildToolSpecs(
            needsSelection: false,
            hasCapabilities: false,
            overrides: nil,
            executionMode: sandboxMode
        )
        #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }))

        ToolRegistry.shared.unregisterAllSandboxTools()
        SandboxManager.State.shared.status = originalStatus
        registrar.provisionAgentOverride = originalProvisionOverride
        manager.setActiveAgent(originalActiveAgentId)
        _ = await manager.delete(id: inactiveAgent.id)
        _ = await manager.delete(id: sandboxAgent.id)
    }
}

@MainActor
private func withRegisteredSandboxBuiltins(_ body: () -> Void) {
    BuiltinSandboxTools.register(
        agentId: "chat-sandbox-test",
        agentName: "chat-sandbox-test",
        config: AutonomousExecConfig(enabled: true)
    )
    defer {
        ToolRegistry.shared.unregisterAllSandboxTools()
    }
    body()
}
