//
//  MCPBundleManifest.swift
//  osaurus
//
//  Model for MCPB (MCP Bundle) manifest.json files.
//

import Foundation

struct MCPBundleManifest: Codable {
    let mcpVersion: String
    let name: String
    let version: String
    let displayName: String?
    let description: String?
    let entry: EntryPoint
    let icon: String?

    enum CodingKeys: String, CodingKey {
        case mcpVersion = "mcpVersion"
        case name
        case version
        case displayName
        case description
        case entry
        case icon
    }

    struct EntryPoint: Codable {
        let command: String
        let args: [String]
        let env: [String: String]?

        enum CodingKeys: String, CodingKey {
            case command
            case args
            case env
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            env = try container.decodeIfPresent([String: String].self, forKey: .env)
        }
    }

    /// Resolve environment variables, substituting ${env:VAR_NAME} with actual values
    func resolveEnvironment() -> [String: String] {
        var resolved: [String: String] = [:]
        for (key, value) in (entry.env ?? [:]) {
            if value.hasPrefix("${env:"), value.hasSuffix("}") {
                let envVar = String(value.dropFirst(6).dropLast(1))
                resolved[key] = ProcessInfo.processInfo.environment[envVar] ?? ""
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }
}
