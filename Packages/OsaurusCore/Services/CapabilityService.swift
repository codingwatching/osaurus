//
//  CapabilityService.swift
//  osaurus
//
//  Service for building system prompts with capability catalog and skill instructions.
//  Supports two-phase loading: catalog-only for selection, full content for execution.
//

import Foundation

/// Service for managing ChatView capability (tools + skills) integration.
@MainActor
public final class CapabilityService {
    public static let shared = CapabilityService()

    private init() {}

    // MARK: - System Prompt Building

    /// Build an enhanced system prompt that includes enabled skill instructions.
    /// This is the simple integration path - all enabled skills are included.
    public func buildSystemPromptWithSkills(
        basePrompt: String,
        agentId: UUID?
    ) -> String {
        let effectivePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get enabled skills
        let enabledSkills = enabledSkills(for: agentId)

        guard !enabledSkills.isEmpty else {
            return effectivePrompt
        }

        // Build the enhanced prompt
        var enhanced = effectivePrompt

        if !enhanced.isEmpty {
            enhanced += "\n\n"
        }

        enhanced += "# Active Skills\n\n"
        enhanced += "Apply the following skill guidance contextually based on the task. "
        enhanced += "If multiple skills are relevant, synthesize their guidance coherently.\n\n"

        for skill in enabledSkills {
            enhanced += "## \(skill.name)\n"
            if !skill.description.isEmpty {
                enhanced += "*\(skill.description)*\n\n"
            }
            enhanced += skill.instructions
            enhanced += "\n\n---\n\n"
        }

        return enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chat Two-Phase Loading

    /// Build a capability catalog for the ChatView selection phase.
    /// Returns only metadata, not full content.
    public func buildCatalog() -> CapabilityCatalog {
        CapabilityCatalogBuilder.build()
    }

    /// Build a ChatView system prompt with capability catalog for two-phase loading.
    /// The model will see metadata only and can call `select_capabilities`.
    /// Uses agent-level overrides to filter available capabilities.
    public func buildSystemPromptWithCatalog(
        basePrompt: String,
        agentId: UUID?
    ) -> String {
        let effectiveAgentId = agentId ?? Agent.defaultId
        let effectivePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build catalog with agent-level overrides
        let catalog = CapabilityCatalogBuilder.build(for: effectiveAgentId)

        guard !catalog.isEmpty else {
            return effectivePrompt
        }

        var enhanced = effectivePrompt

        if !enhanced.isEmpty {
            enhanced += "\n\n"
        }

        enhanced += catalog.asSystemPromptSection()

        return enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveSelection(
        argumentsJSON: String,
        agentId: UUID?
    ) async throws -> CapabilitySelectionResult {
        let request = try SelectCapabilitiesTool.parse(argumentsJSON: argumentsJSON)
        let effectiveAgentId = agentId ?? Agent.defaultId
        let toolOverrides = AgentManager.shared.effectiveToolOverrides(for: effectiveAgentId)
        let selectableTools = Set(
            ToolRegistry.shared.listSelectableCapabilityTools(withOverrides: toolOverrides)
                .filter(\.enabled)
                .map(\.name)
        )

        var selectedTools: [String] = []
        var selectedSkills: [String] = []
        var loadedToolSchemas: [String: JSONValue] = [:]
        var loadedSkillInstructions: [String: String] = [:]
        var errors: [String] = []

        for toolName in request.tools {
            if selectableTools.contains(toolName),
                let params = ToolRegistry.shared.parametersForTool(name: toolName)
            {
                selectedTools.append(toolName)
                loadedToolSchemas[toolName] = params
            } else {
                errors.append("Tool '\(toolName)' not found or not enabled")
            }
        }

        let enabledRequestedSkills = request.skills.filter { skillName in
            isSkillEnabled(skillName, for: effectiveAgentId)
        }
        let skillInstructionsMap = SkillManager.shared.loadInstructions(for: enabledRequestedSkills)
        for skillName in request.skills {
            if enabledRequestedSkills.contains(skillName), let instructions = skillInstructionsMap[skillName] {
                selectedSkills.append(skillName)
                loadedSkillInstructions[skillName] = instructions
            } else {
                errors.append("Skill '\(skillName)' not found or not enabled")
            }
        }

        return CapabilitySelectionResult(
            selectedTools: selectedTools,
            selectedSkills: selectedSkills,
            loadedToolSchemas: loadedToolSchemas,
            loadedSkillInstructions: loadedSkillInstructions,
            errors: errors
        )
    }

    func combineSkillInstructions(_ loadedSkillInstructions: [String: String]) -> String {
        let formatted =
            loadedSkillInstructions
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "## \($0.key)\n\n\($0.value)" }
        return formatted.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Token Estimation

    /// Estimate the token count for enabled skills (full instructions).
    /// Uses rough heuristic of ~4 characters per token.
    public func estimateSkillTokens() -> Int {
        let enabledSkills = SkillManager.shared.skills.filter { $0.enabled }
        let totalChars = enabledSkills.reduce(0) { sum, skill in
            sum + skill.name.count + skill.description.count + skill.instructions.count + 50  // overhead
        }
        return max(0, totalChars / 4)
    }

    /// Estimate tokens for skill catalog entries (name + description only).
    /// Used in two-phase loading for the selection phase.
    public func estimateCatalogSkillTokens(for agentId: UUID?) -> Int {
        let skills = enabledSkills(for: agentId)
        // Format: "- **name**: description\n" ≈ 6 chars overhead per skill
        let totalChars = skills.reduce(0) { sum, skill in
            sum + skill.name.count + skill.description.count + 6
        }
        return max(0, totalChars / 4)
    }

    /// Check if any skills are enabled.
    public var hasEnabledSkills: Bool {
        SkillManager.shared.skills.contains { $0.enabled }
    }

    /// Get count of enabled skills.
    public var enabledSkillCount: Int {
        SkillManager.shared.enabledCount
    }

    // MARK: - Agent-Aware Skill Checking

    /// Check if a skill is enabled for a given agent.
    /// Takes into account agent-level overrides.
    public func isSkillEnabled(_ skillName: String, for agentId: UUID?) -> Bool {
        guard let skill = SkillManager.shared.skill(named: skillName) else {
            return false
        }

        let effectiveAgentId = agentId ?? Agent.defaultId

        // Check agent override first
        if let overrides = AgentManager.shared.effectiveSkillOverrides(for: effectiveAgentId),
            let override = overrides[skillName]
        {
            return override
        }

        // Fall back to global skill state
        return skill.enabled
    }

    /// Get enabled skills for a given agent.
    /// Takes into account agent-level overrides.
    public func enabledSkills(for agentId: UUID?) -> [Skill] {
        SkillManager.shared.skills.filter { skill in
            isSkillEnabled(skill.name, for: agentId)
        }
    }

    /// Check if any skills are enabled for a given agent.
    public func hasEnabledSkills(for agentId: UUID?) -> Bool {
        SkillManager.shared.skills.contains { skill in
            isSkillEnabled(skill.name, for: agentId)
        }
    }

}
