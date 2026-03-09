//
//  SelectCapabilitiesTool.swift
//  osaurus
//
//  Tool for model to select which capabilities (tools + skills) to use for a conversation.
//  Called once at conversation start during two-phase capability loading.
//

import Foundation

/// Result of capability selection
public struct CapabilitySelectionResult: Codable, Sendable {
    public let selectedTools: [String]
    public let selectedSkills: [String]
    public let loadedToolSchemas: [String: JSONValue]
    public let loadedSkillInstructions: [String: String]
    public let errors: [String]

    public init(
        selectedTools: [String],
        selectedSkills: [String],
        loadedToolSchemas: [String: JSONValue],
        loadedSkillInstructions: [String: String],
        errors: [String] = []
    ) {
        self.selectedTools = selectedTools
        self.selectedSkills = selectedSkills
        self.loadedToolSchemas = loadedToolSchemas
        self.loadedSkillInstructions = loadedSkillInstructions
        self.errors = errors
    }
}

/// Tool for selecting capabilities at ChatView conversation start.
final class SelectCapabilitiesTool: OsaurusTool, @unchecked Sendable {
    struct Request: Sendable {
        let tools: [String]
        let skills: [String]
    }

    let name = "select_capabilities"
    let description =
        "ChatView only. Select which tools and skills to use for this conversation before starting your response."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "tools": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Names of tools to enable for this conversation"),
            ]),
            "skills": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Names of skills to activate for guidance"),
            ]),
        ]),
        "required": .array([.string("tools"), .string("skills")]),
    ])

    /// Callback to notify when capabilities are selected
    var onCapabilitiesSelected: ((CapabilitySelectionResult) -> Void)?

    init(onCapabilitiesSelected: ((CapabilitySelectionResult) -> Void)? = nil) {
        self.onCapabilitiesSelected = onCapabilitiesSelected
    }

    func execute(argumentsJSON: String) async throws -> String {
        let result = try await CapabilityService.shared.resolveSelection(
            argumentsJSON: argumentsJSON,
            agentId: nil
        )

        // Notify callback
        onCapabilitiesSelected?(result)

        // Build response
        return Self.buildDetailedResponse(result)
    }

    static func parse(argumentsJSON: String) throws -> Request {
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SelectCapabilitiesError.invalidArguments
        }
        return Request(
            tools: (json["tools"] as? [String]) ?? [],
            skills: (json["skills"] as? [String]) ?? []
        )
    }

    static func buildDetailedResponse(_ result: CapabilitySelectionResult) -> String {
        var response: [String] = []

        response.append("# Capabilities Loaded")
        response.append("")

        if !result.selectedTools.isEmpty {
            response.append("## Selected Tools")
            response.append("The following tools are now available for this conversation:")
            for tool in result.selectedTools {
                response.append("- \(tool)")
            }
            response.append("")
        }

        if !result.loadedSkillInstructions.isEmpty {
            response.append("## Selected Skills")
            response.append("The following skill instructions are now active:")
            response.append("")

            for (skillName, instructions) in result.loadedSkillInstructions {
                response.append("### \(skillName)")
                response.append("")
                response.append(instructions)
                response.append("")
            }
        }

        if !result.errors.isEmpty {
            response.append("## Warnings")
            for error in result.errors {
                response.append("- \(error)")
            }
            response.append("")
        }

        if result.selectedTools.isEmpty && result.loadedSkillInstructions.isEmpty {
            response.append("No capabilities were loaded. You can proceed without tools or skills.")
        } else {
            response.append("You can now proceed with your response using the loaded capabilities.")
        }

        return response.joined(separator: "\n")
    }

    static func buildCompactResponse(_ result: CapabilitySelectionResult) -> String {
        var response: [String] = ["# Capabilities Loaded"]

        if !result.selectedTools.isEmpty {
            response.append("Tools: \(result.selectedTools.joined(separator: ", "))")
        }

        if !result.selectedSkills.isEmpty {
            response.append("Skills: \(result.selectedSkills.joined(separator: ", "))")
        }

        if !result.errors.isEmpty {
            response.append("")
            for error in result.errors {
                response.append("Warning: \(error)")
            }
        }

        if result.selectedTools.isEmpty && result.selectedSkills.isEmpty {
            response.append("No capabilities loaded.")
        }

        return response.joined(separator: "\n")
    }
}

// MARK: - Errors

enum SelectCapabilitiesError: Error, LocalizedError {
    case invalidArguments
    case noCapabilitiesAvailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Invalid arguments for select_capabilities"
        case .noCapabilitiesAvailable:
            return "No capabilities available to select"
        }
    }
}
