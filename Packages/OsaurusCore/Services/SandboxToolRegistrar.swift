//
//  SandboxToolRegistrar.swift
//  osaurus
//
//  Bridges the sandbox infrastructure with the ToolRegistry by
//  registering/unregistering sandbox tools in response to agent
//  switches, plugin installs, and container lifecycle events.
//

import Combine
import Foundation

@MainActor
public final class SandboxToolRegistrar {
    public static let shared = SandboxToolRegistrar()

    private var observers: [NSObjectProtocol] = []
    private var statusCancellable: AnyCancellable?
    var provisionAgentOverride: ((UUID) async throws -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app startup (after sandbox auto-start attempt).
    /// Sets up all notification observers and performs initial registration.
    public func start() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.handleAgentChanged() } }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginInstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                let agentId = note.userInfo?["agentId"] as? String
                Task { @MainActor in await self?.handlePluginInstalled(pluginId: pluginId, agentId: agentId) }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginUninstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                Task { @MainActor in await self?.handlePluginUninstalled(pluginId: pluginId) }
            }
        )

        statusCancellable = SandboxManager.State.shared.$status
            .removeDuplicates()
            .sink { [weak self] newStatus in
                Task { @MainActor in await self?.handleContainerStatusChanged(newStatus) }
            }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .agentUpdated,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let agentId = note.object as? UUID
                Task { @MainActor in await self?.handleAgentUpdated(agentId: agentId) }
            }
        )

        Task { @MainActor in
            await self.registerToolsForCurrentAgent()
        }
    }

    // MARK: - Registration

    /// Unregisters all sandbox tools, then re-registers builtin + plugin
    /// tools for the current active agent only when the container is running.
    /// This ensures sandbox tools are never exposed in the LLM context when
    /// the sandbox is unavailable.
    public func registerToolsForCurrentAgent() async {
        await registerTools(for: AgentManager.shared.activeAgent.id)
    }

    /// Re-register sandbox tools for a specific agent. Chat sessions use this to
    /// avoid depending on whichever agent is globally active.
    public func registerTools(for agentId: UUID) async {
        ToolRegistry.shared.unregisterAllSandboxTools()

        guard SandboxManager.State.shared.status == .running else { return }

        let agent = AgentManager.shared.agent(for: agentId) ?? Agent.default
        let agentId = agent.id.uuidString
        let execConfig = AgentManager.shared.effectiveAutonomousExec(for: agent.id)
        let agentName = SandboxAgentProvisioner.linuxName(for: agentId)
        let plugins = SandboxPluginManager.shared.plugins(for: agentId)
        let needsProvisioning = (execConfig?.enabled == true) || plugins.contains { $0.status == .ready }

        if needsProvisioning {
            do {
                try await ensureProvisioned(agentId: agent.id)
            } catch {
                NSLog("[SandboxToolRegistrar] Failed to provision agent sandbox: \(error.localizedDescription)")
                return
            }
        }

        BuiltinSandboxTools.register(
            agentId: agentId,
            agentName: agentName,
            config: execConfig
        )

        for installed in plugins where installed.status == .ready {
            ToolRegistry.shared.registerSandboxPluginTools(
                plugin: installed.plugin,
                agentId: agentId,
                agentName: agentName
            )
        }
    }

    private func ensureProvisioned(agentId: UUID) async throws {
        if let provisionAgentOverride {
            try await provisionAgentOverride(agentId)
            return
        }
        try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
    }

    // MARK: - Event Handlers

    private func handleAgentChanged() async {
        await registerToolsForCurrentAgent()
    }

    private func handleAgentUpdated(agentId: UUID?) async {
        guard agentId == nil || agentId == AgentManager.shared.activeAgent.id else { return }
        await registerToolsForCurrentAgent()
    }

    private func handlePluginInstalled(pluginId: String?, agentId: String?) async {
        let currentAgentId = AgentManager.shared.activeAgent.id.uuidString
        guard let pluginId, let agentId,
            agentId == currentAgentId,
            let installed = SandboxPluginManager.shared.plugin(id: pluginId, for: agentId),
            installed.status == .ready
        else { return }

        do {
            try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
        } catch {
            NSLog("[SandboxToolRegistrar] Failed to provision agent for plugin install: \(error.localizedDescription)")
            return
        }

        ToolRegistry.shared.registerSandboxPluginTools(
            plugin: installed.plugin,
            agentId: agentId,
            agentName: SandboxAgentProvisioner.linuxName(for: agentId)
        )
    }

    private func handlePluginUninstalled(pluginId: String?) async {
        guard let pluginId else { return }
        ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId)
    }

    private func handleContainerStatusChanged(_: ContainerStatus) async {
        await registerToolsForCurrentAgent()
    }
}
