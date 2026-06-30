//
//  ChannelSecurityPolicyEvaluator.swift
//  osaurus
//
//  Strictest-wins allowlist evaluator for inbound channel requests.
//

import Foundation

struct ChannelSecurityPolicyEvaluator: Sendable {
    func evaluate(
        identity: ChannelIdentity,
        action: ChannelSecurityAction,
        policy: ChannelSecurityPolicy,
        writeGate: ChannelWriteKillSwitchSnapshot = ChannelWriteKillSwitch.shared.snapshot()
    ) -> ChannelAuthorizationDecision {
        guard policy.enabled else { return .deny(.disabled) }
        guard identity.hasValidRequiredIds else { return .deny(.invalidIdentity) }
        guard identity.trustLevel >= policy.minimumTrustLevel else { return .deny(.trustDenied) }
        guard isAllowed(identity.senderId, by: policy.allowedSenderIds) else {
            return .deny(.senderDenied)
        }
        guard isAllowed(identity.groupId, by: policy.allowedGroupIds) else {
            return .deny(.groupDenied)
        }
        guard isAllowed(identity.threadId, by: policy.allowedThreadIds) else {
            return .deny(.threadDenied)
        }
        guard action.requiresWritePermission else { return .allow() }

        if !writeGate.writeEnabled {
            return .deny(.disabled)
        }
        guard let writePermission = policy.writePermission, writePermission.enabled else {
            return .deny(.writeDisabled)
        }
        guard isAllowed(identity.senderId, by: writePermission.allowedSenderIds) else {
            return .deny(.writeSenderDenied)
        }
        guard isAllowed(identity.groupId, by: writePermission.allowedGroupIds) else {
            return .deny(.writeGroupDenied)
        }
        guard isAllowed(identity.threadId, by: writePermission.allowedThreadIds) else {
            return .deny(.writeThreadDenied)
        }
        return .allow()
    }

    private func isAllowed(_ value: String?, by allowlist: [String]) -> Bool {
        guard !allowlist.isEmpty else { return true }
        guard let value else { return false }
        return allowlist.contains(value)
    }
}
