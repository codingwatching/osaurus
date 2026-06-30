//
//  ChannelSecurityPolicy.swift
//  osaurus
//
//  Policy-only authorization model for remote agent channels.
//

import Foundation

enum ChannelSecurityAction: String, Codable, CaseIterable, Sendable {
    case read
    case reply
    case write

    var requiresWritePermission: Bool {
        switch self {
        case .read: return false
        case .reply, .write: return true
        }
    }
}

enum ChannelSecurityDiagnosticReason: String, Codable, Equatable, Sendable {
    case allowed
    case disabled
    case invalidIdentity = "invalid_identity"
    case senderDenied = "denied_sender"
    case groupDenied = "denied_group"
    case threadDenied = "denied_thread"
    case trustDenied = "denied_trust"
    case writeDisabled = "write_disabled"
    case writeSenderDenied = "write_denied_sender"
    case writeGroupDenied = "write_denied_group"
    case writeThreadDenied = "write_denied_thread"
    case expired
    case replayed
    case revoked
    case tokenInvalid = "token_invalid"
    case identityMismatch = "identity_mismatch"
    case purposeMismatch = "purpose_mismatch"
    case actionMismatch = "action_mismatch"
    case notYetValid = "not_yet_valid"
    case storeUnavailable = "store_unavailable"
}

struct ChannelWritePermission: Codable, Equatable, Sendable {
    var enabled: Bool
    var allowedSenderIds: [String]
    var allowedGroupIds: [String]
    var allowedThreadIds: [String]

    init(
        enabled: Bool = false,
        allowedSenderIds: [String] = [],
        allowedGroupIds: [String] = [],
        allowedThreadIds: [String] = []
    ) {
        self.enabled = enabled
        self.allowedSenderIds = ChannelIdentity.normalizedIds(allowedSenderIds)
        self.allowedGroupIds = ChannelIdentity.normalizedIds(allowedGroupIds)
        self.allowedThreadIds = ChannelIdentity.normalizedIds(allowedThreadIds)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, allowedSenderIds, allowedGroupIds, allowedThreadIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            allowedSenderIds: try container.decodeIfPresent([String].self, forKey: .allowedSenderIds) ?? [],
            allowedGroupIds: try container.decodeIfPresent([String].self, forKey: .allowedGroupIds) ?? [],
            allowedThreadIds: try container.decodeIfPresent([String].self, forKey: .allowedThreadIds) ?? []
        )
    }
}

struct ChannelSecurityPolicy: Codable, Equatable, Sendable {
    var enabled: Bool
    var minimumTrustLevel: ChannelTrustLevel
    var allowedSenderIds: [String]
    var allowedGroupIds: [String]
    var allowedThreadIds: [String]
    var writePermission: ChannelWritePermission?

    init(
        enabled: Bool = true,
        minimumTrustLevel: ChannelTrustLevel = .untrusted,
        allowedSenderIds: [String] = [],
        allowedGroupIds: [String] = [],
        allowedThreadIds: [String] = [],
        writePermission: ChannelWritePermission? = nil
    ) {
        self.enabled = enabled
        self.minimumTrustLevel = minimumTrustLevel
        self.allowedSenderIds = ChannelIdentity.normalizedIds(allowedSenderIds)
        self.allowedGroupIds = ChannelIdentity.normalizedIds(allowedGroupIds)
        self.allowedThreadIds = ChannelIdentity.normalizedIds(allowedThreadIds)
        self.writePermission = writePermission
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, minimumTrustLevel, allowedSenderIds, allowedGroupIds, allowedThreadIds, writePermission
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            minimumTrustLevel: try container.decodeIfPresent(ChannelTrustLevel.self, forKey: .minimumTrustLevel)
                ?? .untrusted,
            allowedSenderIds: try container.decodeIfPresent([String].self, forKey: .allowedSenderIds) ?? [],
            allowedGroupIds: try container.decodeIfPresent([String].self, forKey: .allowedGroupIds) ?? [],
            allowedThreadIds: try container.decodeIfPresent([String].self, forKey: .allowedThreadIds) ?? [],
            writePermission: try container.decodeIfPresent(ChannelWritePermission.self, forKey: .writePermission)
        )
    }
}

struct ChannelAuthorizationDecision: Equatable, Sendable {
    var allowed: Bool
    var reason: ChannelSecurityDiagnosticReason
    var message: String

    static func allow() -> ChannelAuthorizationDecision {
        ChannelAuthorizationDecision(
            allowed: true,
            reason: .allowed,
            message: ChannelSecurityDiagnostics.message(for: .allowed)
        )
    }

    static func deny(_ reason: ChannelSecurityDiagnosticReason) -> ChannelAuthorizationDecision {
        ChannelAuthorizationDecision(
            allowed: false,
            reason: reason,
            message: ChannelSecurityDiagnostics.message(for: reason)
        )
    }
}

struct ChannelReplyTokenPayload: Codable, Equatable, Sendable {
    var version: Int
    var purpose: String
    var action: ChannelSecurityAction
    var binding: ChannelIdentityBinding
    var nonce: String
    var issuedAt: TimeInterval
    var expiresAt: TimeInterval
    var writeGateGeneration: Int

    init(
        version: Int = 1,
        purpose: String,
        action: ChannelSecurityAction,
        binding: ChannelIdentityBinding,
        nonce: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval,
        writeGateGeneration: Int
    ) {
        self.version = version
        self.purpose = purpose
        self.action = action
        self.binding = binding
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.writeGateGeneration = writeGateGeneration
    }
}

struct ChannelReplyTokenValidation: Equatable, Sendable {
    var accepted: Bool
    var reason: ChannelSecurityDiagnosticReason
    var message: String
    var payload: ChannelReplyTokenPayload?

    static func accept(_ payload: ChannelReplyTokenPayload) -> ChannelReplyTokenValidation {
        ChannelReplyTokenValidation(
            accepted: true,
            reason: .allowed,
            message: ChannelSecurityDiagnostics.message(for: .allowed),
            payload: payload
        )
    }

    static func deny(_ reason: ChannelSecurityDiagnosticReason) -> ChannelReplyTokenValidation {
        ChannelReplyTokenValidation(
            accepted: false,
            reason: reason,
            message: ChannelSecurityDiagnostics.message(for: reason),
            payload: nil
        )
    }
}
