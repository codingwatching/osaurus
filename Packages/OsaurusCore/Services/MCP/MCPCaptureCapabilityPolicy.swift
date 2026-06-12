//
//  MCPCaptureCapabilityPolicy.swift
//  osaurus
//
//  Permission policy for MCP/plugin capture capabilities. This file defines
//  the gate only; it does not implement screenshot capture or register a tool.
//

import Foundation

public enum MCPCaptureCapability: String, Codable, Sendable, CaseIterable, Equatable {
    case screenshot

    public var displayName: String {
        switch self {
        case .screenshot:
            return L("Screen capture")
        }
    }
}

public enum MCPCapturePolicyDenialReason: String, Codable, Sendable, Equatable {
    case unknownCapability
    case pluginNotInstalled
    case pluginDisabled
    case userOptInRequired
    case missingPermissionGrant
    case backgroundCaptureDenied
}

public struct MCPCapturePolicyRequest: Sendable, Equatable {
    public var capability: MCPCaptureCapability?
    public var pluginInstalled: Bool
    public var pluginEnabled: Bool
    public var userOptedIn: Bool
    public var permissionGranted: Bool
    public var interactiveRequest: Bool

    public init(
        capability: MCPCaptureCapability?,
        pluginInstalled: Bool,
        pluginEnabled: Bool,
        userOptedIn: Bool,
        permissionGranted: Bool,
        interactiveRequest: Bool
    ) {
        self.capability = capability
        self.pluginInstalled = pluginInstalled
        self.pluginEnabled = pluginEnabled
        self.userOptedIn = userOptedIn
        self.permissionGranted = permissionGranted
        self.interactiveRequest = interactiveRequest
    }
}

public struct MCPCapturePolicyDecision: Sendable, Equatable {
    public var allowed: Bool
    public var denialReason: MCPCapturePolicyDenialReason?
    public var message: String
    public var action: String?

    public init(
        allowed: Bool,
        denialReason: MCPCapturePolicyDenialReason?,
        message: String,
        action: String? = nil
    ) {
        self.allowed = allowed
        self.denialReason = denialReason
        self.message = message
        self.action = action
    }
}

public enum MCPCaptureCapabilityPolicy {
    public static func evaluate(_ request: MCPCapturePolicyRequest) -> MCPCapturePolicyDecision {
        guard request.capability != nil else {
            return denied(
                .unknownCapability,
                message: L("The requested capture capability is not recognized."),
                action: L("Only documented capture capabilities can be requested by plugins.")
            )
        }

        guard request.pluginInstalled else {
            return denied(
                .pluginNotInstalled,
                message: L("No installed plugin owns this capture capability."),
                action: L("Install a trusted plugin before enabling capture access.")
            )
        }

        guard request.pluginEnabled else {
            return denied(
                .pluginDisabled,
                message: L("The owning plugin is disabled."),
                action: L("Enable the plugin before granting capture access.")
            )
        }

        guard request.userOptedIn else {
            return denied(
                .userOptInRequired,
                message: L("Capture access is off until explicitly enabled."),
                action: L("Turn on capture access for this plugin in settings.")
            )
        }

        guard request.permissionGranted else {
            return denied(
                .missingPermissionGrant,
                message: L("The plugin does not have capture permission."),
                action: L("Grant capture permission after reviewing the plugin.")
            )
        }

        guard request.interactiveRequest else {
            return denied(
                .backgroundCaptureDenied,
                message: L("Background capture is not allowed."),
                action: L("Capture requests must be initiated from an interactive user action.")
            )
        }

        return MCPCapturePolicyDecision(
            allowed: true,
            denialReason: nil,
            message: L("Capture access is allowed for this interactive request.")
        )
    }

    public static var defaultScreenshotDecision: MCPCapturePolicyDecision {
        evaluate(
            MCPCapturePolicyRequest(
                capability: .screenshot,
                pluginInstalled: false,
                pluginEnabled: false,
                userOptedIn: false,
                permissionGranted: false,
                interactiveRequest: false
            )
        )
    }

    private static func denied(
        _ reason: MCPCapturePolicyDenialReason,
        message: String,
        action: String
    ) -> MCPCapturePolicyDecision {
        MCPCapturePolicyDecision(
            allowed: false,
            denialReason: reason,
            message: message,
            action: action
        )
    }
}
