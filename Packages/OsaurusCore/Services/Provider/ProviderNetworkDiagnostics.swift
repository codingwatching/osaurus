//
//  ProviderNetworkDiagnostics.swift
//  osaurus
//
//  Human-readable diagnostics for inference providers, MCP providers, and the
//  shared network policy they depend on.
//

import Foundation

/// Severity used by provider diagnostics rows. The raw values are stable so
/// tests and copied reports can reason about status without parsing UI text.
public enum ProviderDiagnosticSeverity: String, Codable, Sendable, Equatable {
    case ok
    case info
    case warning
    case blocked
}

/// One safe-to-display provider diagnostic row.
public struct ProviderDiagnosticRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let value: String
    public let detail: String?
    public let action: String?
    public let severity: ProviderDiagnosticSeverity

    public init(
        id: String,
        title: String,
        value: String,
        severity: ProviderDiagnosticSeverity,
        detail: String? = nil,
        action: String? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.action = action
        self.severity = severity
    }
}

/// A copyable diagnostics snapshot for one provider row.
public struct ProviderDiagnosticReport: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let rows: [ProviderDiagnosticRow]

    public init(title: String, subtitle: String, rows: [ProviderDiagnosticRow]) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
    }

    /// Pasteboard text intentionally contains status and hints, but never raw
    /// credential values, request bodies, callback URLs, or provider headers.
    public var pasteboardText: String {
        var lines = [
            title,
            subtitle,
        ]
        lines.append(
            contentsOf: rows.map { row in
                var line = "[\(row.severity.rawValue)] \(row.title): \(row.value)"
                if let detail = row.detail, !detail.isEmpty {
                    line += " - \(detail)"
                }
                if let action = row.action, !action.isEmpty {
                    line += " Action: \(action)"
                }
                return line
            }
        )
        return lines.joined(separator: "\n")
    }
}

/// Builds provider diagnostics from existing configuration/state so UI, tests,
/// and support docs all describe the same behavior.
public enum ProviderNetworkDiagnostics {
    public static func remoteProviderReport(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        proxy: GlobalProxyDiagnosticState,
        apiKeyPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            title: "Remote provider diagnostics",
            subtitle: "\(provider.name) | \(provider.displayEndpoint)",
            rows: [
                remoteStateRow(provider: provider, state: state),
                remoteAuthRow(
                    provider: provider,
                    state: state,
                    apiKeyPresent: apiKeyPresent,
                    oauthTokensPresent: oauthTokensPresent
                ),
                remoteModelDiscoveryRow(provider: provider),
                remoteRequestFormatRow(provider: provider),
                proxyRow(proxy, appliesTo: "Remote provider requests"),
            ]
        )
    }

    public static func mcpProviderReport(
        provider: MCPProvider,
        state: MCPProviderState?,
        proxy: GlobalProxyDiagnosticState,
        bearerTokenPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            title: "MCP provider diagnostics",
            subtitle: "\(provider.name) | \(mcpEndpointSubtitle(for: provider))",
            rows: [
                mcpStateRow(provider: provider, state: state),
                mcpAuthRow(
                    provider: provider,
                    state: state,
                    bearerTokenPresent: bearerTokenPresent,
                    oauthTokensPresent: oauthTokensPresent
                ),
                mcpTransportRow(provider: provider),
                mcpProxyRow(provider: provider, proxy: proxy),
                mcpFailureReproRow(provider: provider, state: state),
            ]
        )
    }

    // MARK: - Remote Providers

    private static func remoteStateRow(
        provider: RemoteProvider,
        state: RemoteProviderState?
    ) -> ProviderDiagnosticRow {
        guard provider.enabled else {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Disabled",
                severity: .warning,
                detail: "Osaurus will not auto-connect this provider while the row toggle is off.",
                action: "Enable the provider before testing or selecting its models."
            )
        }

        if state?.isConnecting == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Connecting",
                severity: .info,
                detail: "A bounded model-discovery request is in flight."
            )
        }

        if state?.isConnected == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Connected",
                severity: .ok,
                detail: "\(state?.modelCount ?? 0) model(s) currently available."
            )
        }

        if let error = state?.lastError, !error.isEmpty {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Failed",
                severity: .blocked,
                detail: safeDiagnostic(error),
                action: "Use the Test button or copy diagnostics when reporting the issue."
            )
        }

        return ProviderDiagnosticRow(
            id: "connection",
            title: "Connection",
            value: "Not connected",
            severity: .info,
            detail: "The provider is configured but has not completed model discovery yet."
        )
    }

    private static func remoteAuthRow(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        apiKeyPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticRow {
        switch provider.authType {
        case .none:
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: "None",
                severity: .info,
                detail: "No Authorization header is added by Osaurus."
            )
        case .apiKey:
            if apiKeyPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "API key in Keychain",
                    severity: .ok,
                    detail: "The saved key is injected using the provider-specific header."
                )
            }
            if hasCredentialHeader(provider) {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "Credential header configured",
                    severity: .ok,
                    detail: "A regular or secret credential header is configured for this provider."
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: "Missing API key",
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic),
                action: "Edit the provider and save an API key or secret Authorization header."
            )
        case .openAICodexOAuth:
            if oauthTokensPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "ChatGPT signed in",
                    severity: .ok,
                    detail: "Codex OAuth tokens are present and refreshed before model discovery."
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: "ChatGPT sign-in required",
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic)
                    ?? "No Codex OAuth tokens are saved for this provider.",
                action: "Sign in with the ChatGPT account that has Codex access."
            )
        case .xaiOAuth:
            if oauthTokensPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "xAI signed in",
                    severity: .ok,
                    detail: "xAI OAuth tokens are present and refreshed before model discovery."
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: "xAI sign-in required",
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic)
                    ?? "No xAI OAuth tokens are saved for this provider.",
                action: "Sign in with the xAI account that has Grok API access."
            )
        }
    }

    private static func remoteModelDiscoveryRow(provider: RemoteProvider) -> ProviderDiagnosticRow {
        guard let modelsURL = provider.url(for: provider.providerType.modelsEndpoint) else {
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: "Invalid URL",
                severity: .blocked,
                detail: "Host, port, or base path could not be converted into a /models URL.",
                action: "Edit the endpoint fields and test again."
            )
        }

        switch provider.providerType {
        case .openAICodex:
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: "ChatGPT/Codex catalog",
                severity: .info,
                detail:
                    "Uses the live ChatGPT model catalog after sign-in, with the static Codex fallback before sign-in."
            )
        case .azureOpenAI:
            let hasManual = !provider.mergedModelIds(discovered: []).isEmpty
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: hasManual ? "Manual deployments" : "/models probe",
                severity: hasManual ? .ok : .warning,
                detail: hasManual
                    ? "Azure deployment IDs are configured, so connect can proceed even when /models is unavailable."
                    : "Azure often requires manual deployment IDs because /models may be unavailable.",
                action: hasManual ? nil : "Add at least one deployment/model ID in Advanced."
            )
        case .openaiLegacy, .openResponses:
            let manual = provider.mergedModelIds(discovered: [])
            let detail =
                manual.isEmpty
                ? "Requires \(modelsURL.absoluteString) to return an OpenAI-shaped model list."
                : "Manual IDs are used if /models is missing or returns a non-OpenAI schema."
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: manual.isEmpty ? "/models required" : "Fallback available",
                severity: manual.isEmpty ? .info : .ok,
                detail: detail
            )
        case .anthropic:
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: "Anthropic /models",
                severity: .info,
                detail: "Uses Anthropic's paginated model catalog endpoint."
            )
        case .gemini:
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: "Gemini model list",
                severity: .info,
                detail: "Filters the Gemini catalog to models that support generateContent."
            )
        case .osaurus:
            return ProviderDiagnosticRow(
                id: "models",
                title: "Model discovery",
                value: "Remote Osaurus",
                severity: .info,
                detail: "Tries the remote /models endpoint, then falls back to the agent default model."
            )
        }
    }

    private static func remoteRequestFormatRow(provider: RemoteProvider) -> ProviderDiagnosticRow {
        ProviderDiagnosticRow(
            id: "format",
            title: "Request format",
            value: "\(provider.providerType.displayName) \(provider.providerType.chatEndpoint)",
            severity: .info,
            detail:
                "Local OpenAI-compatible validation returns typed 400 errors for unsupported sampler fields such as n > 1 or response_format=json_schema."
        )
    }

    // MARK: - MCP Providers

    private static func mcpStateRow(provider: MCPProvider, state: MCPProviderState?) -> ProviderDiagnosticRow {
        guard provider.enabled else {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Disabled",
                severity: .warning,
                detail: "Osaurus will not auto-connect this MCP provider while the row toggle is off."
            )
        }
        if state?.isConnecting == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Connecting",
                severity: .info,
                detail: "Tool discovery is running with a \(Int(provider.discoveryTimeout))s timeout."
            )
        }
        if state?.isConnected == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Connected",
                severity: .ok,
                detail: "\(state?.discoveredToolCount ?? 0) tool(s) discovered."
            )
        }
        if state?.requiresAuth == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Auth required",
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic),
                action: "Use the inline Sign In or token prompt."
            )
        }
        if let error = state?.lastError, !error.isEmpty {
            return ProviderDiagnosticRow(
                id: "connection",
                title: "Connection",
                value: "Failed",
                severity: .blocked,
                detail: safeDiagnostic(error),
                action: "Use the Test button in Edit to reproduce the failure."
            )
        }
        return ProviderDiagnosticRow(
            id: "connection",
            title: "Connection",
            value: "Not connected",
            severity: .info,
            detail: "The provider is configured but no tools are registered yet."
        )
    }

    private static func mcpAuthRow(
        provider: MCPProvider,
        state: MCPProviderState?,
        bearerTokenPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticRow {
        switch provider.authType {
        case .none:
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: "None",
                severity: .info,
                detail: "No Authorization header is added by Osaurus."
            )
        case .bearerToken:
            if bearerTokenPresent || hasMCPHeaderCredential(provider) {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "Bearer credential configured",
                    severity: .ok,
                    detail: "The token or secret header is stored outside plain provider config."
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: state?.requiresAuth == true ? "Token required" : "No token saved",
                severity: state?.requiresAuth == true ? .blocked : .warning,
                detail: state?.lastError.map(safeDiagnostic),
                action: "Paste an API token in the inline prompt or edit the provider."
            )
        case .oauth:
            if oauthTokensPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "OAuth tokens saved",
                    severity: .ok,
                    detail: "Tokens are refreshed before HTTP MCP discovery."
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: "Authentication",
                value: "OAuth sign-in required",
                severity: state?.requiresAuth == true ? .blocked : .warning,
                detail: state?.lastError.map(safeDiagnostic)
                    ?? "No OAuth tokens are saved for this provider.",
                action: "Sign in from the provider row."
            )
        }
    }

    private static func mcpTransportRow(provider: MCPProvider) -> ProviderDiagnosticRow {
        switch provider.transport {
        case .http:
            return ProviderDiagnosticRow(
                id: "transport",
                title: "Transport",
                value: provider.streamingEnabled ? "HTTP/SSE" : "HTTP",
                severity: .info,
                detail: "Discovery and tool calls use URLSession with the global proxy policy applied."
            )
        case .stdio:
            let command = provider.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty {
                return ProviderDiagnosticRow(
                    id: "transport",
                    title: "Transport",
                    value: "Stdio command missing",
                    severity: .blocked,
                    detail: "A stdio MCP provider needs a command before it can launch.",
                    action: "Edit the provider and enter the executable."
                )
            }
            return ProviderDiagnosticRow(
                id: "transport",
                title: "Transport",
                value: "Stdio \(provider.executionHost.rawValue)",
                severity: provider.executionHost == .host ? .warning : .ok,
                detail: provider.executionHost == .host
                    ? "Runs directly on the macOS host. Prefer full executable paths for GUI-launched apps."
                    : "Runs inside the Osaurus sandbox and is torn down on disconnect."
            )
        }
    }

    private static func mcpProxyRow(
        provider: MCPProvider,
        proxy: GlobalProxyDiagnosticState
    ) -> ProviderDiagnosticRow {
        switch provider.transport {
        case .http:
            return proxyRow(proxy, appliesTo: "MCP HTTP/SSE requests")
        case .stdio:
            return ProviderDiagnosticRow(
                id: "proxy",
                title: "Global proxy",
                value: "Not used for stdio",
                severity: .info,
                detail: "Stdio providers launch a local subprocess instead of sending HTTP traffic through URLSession."
            )
        }
    }

    private static func mcpFailureReproRow(
        provider: MCPProvider,
        state: MCPProviderState?
    ) -> ProviderDiagnosticRow {
        if let error = state?.lastError, !error.isEmpty {
            let commandMissing = MCPStdioTransportError.isCommandNotFoundMessage(error)
            return ProviderDiagnosticRow(
                id: "repro",
                title: "Repro path",
                value: commandMissing ? "PATH issue" : "Copyable error",
                severity: .warning,
                detail: safeDiagnostic(error),
                action: commandMissing
                    ? "Use a full path such as /opt/homebrew/bin/npx or switch execution host."
                    : "Open Edit and press Test to reproduce discovery without saving."
            )
        }
        if provider.transport == .stdio {
            return ProviderDiagnosticRow(
                id: "repro",
                title: "Repro path",
                value: "Short-lived stdio probe",
                severity: .info,
                detail: "The Test button launches the subprocess, runs initialize/listTools, and tears it down."
            )
        }
        return ProviderDiagnosticRow(
            id: "repro",
            title: "Repro path",
            value: "HTTP discovery probe",
            severity: .info,
            detail: "401 challenges surface as inline sign-in or token prompts with the last error preserved."
        )
    }

    // MARK: - Shared

    private static func proxyRow(_ proxy: GlobalProxyDiagnosticState, appliesTo: String) -> ProviderDiagnosticRow {
        switch proxy {
        case .disabled:
            return ProviderDiagnosticRow(
                id: "proxy",
                title: "Global proxy",
                value: "Off",
                severity: .info,
                detail: "\(appliesTo) use direct networking."
            )
        case .active(let description):
            return ProviderDiagnosticRow(
                id: "proxy",
                title: "Global proxy",
                value: description,
                severity: .ok,
                detail: "\(appliesTo) use this validated proxy endpoint."
            )
        case .invalid(let reason):
            return ProviderDiagnosticRow(
                id: "proxy",
                title: "Global proxy",
                value: "Ignored",
                severity: .warning,
                detail: reason,
                action: "Fix or clear the proxy URL in Server settings."
            )
        }
    }

    private static func hasCredentialHeader(_ provider: RemoteProvider) -> Bool {
        let names = Array(provider.customHeaders.keys) + provider.secretHeaderKeys
        return names.contains {
            RemoteProviderHeaderRedactor.isSensitiveHeader(
                $0,
                configuredSecretHeaderKeys: provider.secretHeaderKeys
            )
        }
    }

    private static func hasMCPHeaderCredential(_ provider: MCPProvider) -> Bool {
        let names = Array(provider.customHeaders.keys) + provider.secretHeaderKeys
        return names.contains {
            RemoteProviderHeaderRedactor.isSensitiveHeader(
                $0,
                configuredSecretHeaderKeys: provider.secretHeaderKeys
            )
        }
    }

    private static func mcpEndpointSubtitle(for provider: MCPProvider) -> String {
        switch provider.transport {
        case .http:
            return provider.url
        case .stdio:
            let args = ShellArgs.join(provider.args)
            return args.isEmpty ? provider.command : "\(provider.command) \(args)"
        }
    }

    private static func safeDiagnostic(_ raw: String) -> String {
        OpenAICodexOAuthService.safeDiagnosticFragment(raw, maxLength: 280)
    }
}
