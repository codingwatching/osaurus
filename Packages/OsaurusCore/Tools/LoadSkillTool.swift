//
//  LoadSkillTool.swift
//  osaurus
//
//  On-demand loader for skill instructions. The system prompt lists available
//  skills with one-line descriptions; this tool fetches the full instructions
//  when the agent needs them.
//

import Foundation

final class LoadSkillTool: OsaurusTool, @unchecked Sendable {
    let name = "load_skill"
    let description =
        "Load detailed instructions for a specific skill. "
        + "Use when you need the full guide for a skill listed in Available Skills."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "skill_name": .object([
                "type": .string("string"),
                "description": .string("Name of the skill to load"),
            ])
        ]),
        "required": .array([.string("skill_name")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let skillName = args["skill_name"] as? String,
            !skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: 'skill_name' parameter is required."
        }

        let instructions = await MainActor.run {
            SkillManager.shared.loadInstructions(for: [skillName])
        }

        guard let content = instructions[skillName] else {
            return "Error: Skill '\(skillName)' not found or not enabled."
        }

        return content
    }
}
