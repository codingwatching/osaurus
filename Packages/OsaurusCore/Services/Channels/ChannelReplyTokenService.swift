//
//  ChannelReplyTokenService.swift
//  osaurus
//
//  Scoped, expiring reply tokens for future channel receive flows.
//

import CryptoKit
import Foundation

enum ChannelReplyTokenServiceError: Error, Equatable {
    case weakSigningKey
    case invalidTTL
    case disabled
    case invalidIdentity
}

struct ChannelReplyTokenIssue: Equatable, Sendable {
    var token: String
    var payload: ChannelReplyTokenPayload
}

struct ChannelVerifiedReplyTokenValidation: Equatable, Sendable {
    fileprivate var validation: ChannelReplyTokenValidation

    var accepted: Bool { validation.accepted }
    var reason: ChannelSecurityDiagnosticReason { validation.reason }
    var message: String { validation.message }
    var payload: ChannelReplyTokenPayload? { validation.payload }

    fileprivate init(_ validation: ChannelReplyTokenValidation) {
        self.validation = validation
    }
}

final class ChannelReplyTokenService: @unchecked Sendable {
    static let tokenPrefix = "osaurus_channel_reply_v1"
    static let minimumSigningKeyBytes = 32

    private let signingKey: SymmetricKey
    private let nonceStore: any ChannelReplyTokenNonceStore
    private let writeKillSwitch: ChannelWriteKillSwitch
    private let clockSkew: TimeInterval
    private let maxTTL: TimeInterval

    init(
        signingKey: Data,
        nonceStore: any ChannelReplyTokenNonceStore = ChannelReplayNonceStore.shared,
        writeKillSwitch: ChannelWriteKillSwitch = .shared,
        clockSkew: TimeInterval = 60,
        maxTTL: TimeInterval = 15 * 60
    ) throws {
        guard signingKey.count >= Self.minimumSigningKeyBytes else {
            throw ChannelReplyTokenServiceError.weakSigningKey
        }
        self.signingKey = SymmetricKey(data: signingKey)
        self.nonceStore = nonceStore
        self.writeKillSwitch = writeKillSwitch
        self.clockSkew = max(0, clockSkew)
        self.maxTTL = max(1, maxTTL)
    }

    func issueToken(
        purpose: String,
        action: ChannelSecurityAction,
        identity: ChannelIdentity,
        ttl: TimeInterval,
        now: Date = Date()
    ) throws -> ChannelReplyTokenIssue {
        guard ttl > 0, ttl <= maxTTL else { throw ChannelReplyTokenServiceError.invalidTTL }
        guard identity.hasValidRequiredIds else { throw ChannelReplyTokenServiceError.invalidIdentity }
        let gate = writeKillSwitch.snapshot()
        if action.requiresWritePermission, !gate.writeEnabled {
            throw ChannelReplyTokenServiceError.disabled
        }

        let payload = ChannelReplyTokenPayload(
            purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            action: action,
            binding: identity.binding,
            nonce: UUID().uuidString.lowercased(),
            issuedAt: now.timeIntervalSince1970,
            expiresAt: now.addingTimeInterval(ttl).timeIntervalSince1970,
            writeGateGeneration: gate.generation
        )
        let payloadData = try encodedPayload(payload)
        let payloadSegment = ChannelSecurityEncoding.base64URLEncode(payloadData)
        let signatureSegment = signature(for: payloadSegment)
        _ = try? nonceStore.prune(expiredBefore: now.addingTimeInterval(-maxTTL - clockSkew))
        return ChannelReplyTokenIssue(
            token: "\(Self.tokenPrefix).\(payloadSegment).\(signatureSegment)",
            payload: payload
        )
    }

    func validateToken(
        _ token: String,
        expectedPurpose: String,
        expectedAction: ChannelSecurityAction,
        identity: ChannelIdentity,
        now: Date = Date()
    ) -> ChannelReplyTokenValidation {
        guard let decoded = decodeAndVerify(token) else {
            return .deny(.tokenInvalid)
        }
        let payload = decoded
        guard payload.version == 1 else { return .deny(.tokenInvalid) }
        guard payload.purpose == expectedPurpose.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .deny(.purposeMismatch)
        }
        guard payload.action == expectedAction else { return .deny(.actionMismatch) }
        guard identity.hasValidRequiredIds else { return .deny(.invalidIdentity) }
        guard payload.binding.matches(identity) else { return .deny(.identityMismatch) }

        let gate = writeKillSwitch.snapshot()
        if payload.action.requiresWritePermission {
            guard gate.writeEnabled else { return .deny(.disabled) }
            guard payload.writeGateGeneration == gate.generation else { return .deny(.revoked) }
        }

        if now.timeIntervalSince1970 + clockSkew < payload.issuedAt {
            return .deny(.notYetValid)
        }
        if now.timeIntervalSince1970 - clockSkew > payload.expiresAt {
            return .deny(.expired)
        }

        do {
            let result = try nonceStore.consume(
                scope: payload.binding.nonceScopeKey,
                nonce: payload.nonce,
                expiresAt: Date(timeIntervalSince1970: payload.expiresAt),
                now: now
            )
            switch result {
            case .consumed:
                return .accept(payload)
            case .replayed:
                return .deny(.replayed)
            case .revoked:
                return .deny(.revoked)
            }
        } catch {
            return .deny(.storeUnavailable)
        }
    }

    func revokeToken(_ token: String, now: Date = Date()) -> ChannelReplyTokenValidation {
        guard let payload = decodeAndVerify(token) else { return .deny(.tokenInvalid) }
        do {
            try nonceStore.revoke(
                scope: payload.binding.nonceScopeKey,
                nonce: payload.nonce,
                expiresAt: Date(timeIntervalSince1970: payload.expiresAt),
                now: now
            )
            return .deny(.revoked)
        } catch {
            return .deny(.storeUnavailable)
        }
    }

    private func decodeAndVerify(_ token: String) -> ChannelReplyTokenPayload? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Substring(Self.tokenPrefix) else {
            return nil
        }
        let payloadSegment = String(parts[1])
        let signatureSegment = String(parts[2])
        guard constantTimeEqual(signatureSegment, signature(for: payloadSegment)),
            let payloadData = ChannelSecurityEncoding.base64URLDecode(payloadSegment)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ChannelReplyTokenPayload.self, from: payloadData)
    }

    private func encodedPayload(_ payload: ChannelReplyTokenPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private func signature(for payloadSegment: String) -> String {
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(payloadSegment.utf8),
            using: signingKey
        )
        return ChannelSecurityEncoding.base64URLEncode(Data(signature))
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in lhsBytes.indices {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }
}

extension ChannelReplyTokenService {
    func validateRemoteActionToken(
        _ token: String,
        policy: ChannelRemoteSafetyPolicy = ChannelRemoteSafetyPolicy(),
        remoteAction: ChannelRemoteActionClass,
        identity: ChannelIdentity,
        now: Date = Date()
    ) -> ChannelVerifiedReplyTokenValidation {
        ChannelVerifiedReplyTokenValidation(
            validateToken(
                token,
                expectedPurpose: policy.replyTokenPurpose,
                expectedAction: remoteAction.requiredReplyTokenAction,
                identity: identity,
                now: now
            )
        )
    }
}
