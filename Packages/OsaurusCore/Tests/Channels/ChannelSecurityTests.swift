//
//  ChannelSecurityTests.swift
//  osaurusTests
//
//  Security coverage for the policy-only Agent Channel foundation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChannelSecurityTests {
    @Test func spoofedSenderIsDeniedByPolicy() {
        let policy = ChannelSecurityPolicy(
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"]
        )
        let identity = Self.channelIdentity(senderId: "user-b", groupId: "ops")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .read,
            policy: policy
        )

        #expect(!decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.senderDenied)
        #expect(decision.message.contains("sender"))
    }

    @Test func allowlistedSenderCannotEscalateIntoAnotherGroup() {
        let policy = ChannelSecurityPolicy(
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"]
        )
        let identity = Self.channelIdentity(senderId: "user-a", groupId: "finance")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .read,
            policy: policy
        )

        #expect(!decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.groupDenied)
        #expect(decision.message.contains("group"))
    }

    @Test func writeRequestsRequireExplicitWritePermission() {
        let policy = ChannelSecurityPolicy(
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"]
        )
        let identity = Self.channelIdentity(senderId: "user-a", groupId: "ops")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .reply,
            policy: policy,
            writeGate: ChannelWriteKillSwitchSnapshot(writeEnabled: true)
        )

        #expect(!decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.writeDisabled)
        #expect(decision.message.contains("write"))
    }

    @Test func authorizedReadIsAllowedEvenWhenWriteGateIsDisabled() {
        let policy = ChannelSecurityPolicy(
            minimumTrustLevel: .known,
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"]
        )
        let identity = Self.channelIdentity(senderId: "user-a", groupId: "ops")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .read,
            policy: policy,
            writeGate: ChannelWriteKillSwitchSnapshot(writeEnabled: false, generation: 3)
        )

        #expect(decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.allowed)
    }

    @Test func minimumTrustLevelIsEnforced() {
        let policy = ChannelSecurityPolicy(
            minimumTrustLevel: .verified,
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"]
        )
        let knownIdentity = ChannelIdentity(
            kind: .discord,
            installationId: "discord-installation",
            groupId: "ops",
            sender: ChannelSenderMetadata(senderId: "user-a"),
            trustLevel: .known
        )
        let verifiedIdentity = Self.channelIdentity(senderId: "user-a", groupId: "ops")

        let denied = ChannelSecurityPolicyEvaluator().evaluate(
            identity: knownIdentity,
            action: .read,
            policy: policy
        )
        let allowed = ChannelSecurityPolicyEvaluator().evaluate(
            identity: verifiedIdentity,
            action: .read,
            policy: policy
        )

        #expect(!denied.allowed)
        #expect(denied.reason == ChannelSecurityDiagnosticReason.trustDenied)
        #expect(allowed.allowed)
    }

    @Test func globalWriteGateDisabledDeniesWriteRequest() {
        let policy = ChannelSecurityPolicy(
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"],
            writePermission: ChannelWritePermission(enabled: true)
        )
        let identity = Self.channelIdentity(senderId: "user-a", groupId: "ops")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .reply,
            policy: policy,
            writeGate: ChannelWriteKillSwitchSnapshot(writeEnabled: false, generation: 7)
        )

        #expect(!decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.disabled)
    }

    @Test func strictestWinsAcrossSenderGroupAndWriteAllowlists() {
        let policy = ChannelSecurityPolicy(
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"],
            writePermission: ChannelWritePermission(
                enabled: true,
                allowedSenderIds: ["user-a"],
                allowedGroupIds: ["incident-room"]
            )
        )
        let identity = Self.channelIdentity(senderId: "user-a", groupId: "ops")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .write,
            policy: policy,
            writeGate: ChannelWriteKillSwitchSnapshot(writeEnabled: true)
        )

        #expect(!decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.writeGroupDenied)
    }

    @Test func fullyAllowlistedWriteRequestIsAllowed() {
        let policy = ChannelSecurityPolicy(
            allowedSenderIds: ["user-a"],
            allowedGroupIds: ["ops"],
            allowedThreadIds: ["thread-1"],
            writePermission: ChannelWritePermission(
                enabled: true,
                allowedSenderIds: ["user-a"],
                allowedGroupIds: ["ops"],
                allowedThreadIds: ["thread-1"]
            )
        )
        let identity = Self.channelIdentity(senderId: "user-a", groupId: "ops", threadId: "thread-1")

        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: identity,
            action: .write,
            policy: policy,
            writeGate: ChannelWriteKillSwitchSnapshot(writeEnabled: true)
        )

        #expect(decision.allowed)
        #expect(decision.reason == ChannelSecurityDiagnosticReason.allowed)
    }

    @Test func expiredReplyTokenIsRejectedWithoutConsumingNonce() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 10,
            now: fixture.now
        )

        let validation = fixture.service.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(11)
        )

        #expect(!validation.accepted)
        #expect(validation.reason == ChannelSecurityDiagnosticReason.expired)
        #expect(validation.message.contains("expired"))
    }

    @Test func replyTokenReplayPersistsAcrossStoreRestart() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )

        let first = fixture.service.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )
        #expect(first.accepted)

        let restartedStore = ChannelReplayNonceStore(fileURL: fixture.nonceURL)
        let restartedService = try ChannelReplyTokenService(
            signingKey: fixture.signingKey,
            nonceStore: restartedStore,
            writeKillSwitch: fixture.killSwitch,
            clockSkew: 0,
            maxTTL: 120
        )
        let replay = restartedService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(2)
        )

        #expect(!replay.accepted)
        #expect(replay.reason == ChannelSecurityDiagnosticReason.replayed)
        #expect(replay.message.contains("nonce"))
    }

    @Test func tokenCannotBeUsedByDifferentSenderIdentity() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )
        let spoofed = Self.channelIdentity(senderId: "user-b", groupId: "ops", threadId: "thread-1")

        let validation = fixture.service.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: spoofed,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(!validation.accepted)
        #expect(validation.reason == ChannelSecurityDiagnosticReason.identityMismatch)
    }

    @Test func tamperedOrWrongKeyReplyTokenIsInvalid() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )
        let tampered = String(issue.token.dropLast()) + (issue.token.last == "a" ? "b" : "a")

        let tamperedValidation = fixture.service.validateToken(
            tampered,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )
        #expect(!tamperedValidation.accepted)
        #expect(tamperedValidation.reason == ChannelSecurityDiagnosticReason.tokenInvalid)

        let wrongKeyService = try ChannelReplyTokenService(
            signingKey: Data("wrong-channel-signing-key-32-bytes".utf8),
            nonceStore: fixture.nonceStore,
            writeKillSwitch: fixture.killSwitch,
            clockSkew: 0,
            maxTTL: 120
        )
        let wrongKeyValidation = wrongKeyService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )
        #expect(!wrongKeyValidation.accepted)
        #expect(wrongKeyValidation.reason == ChannelSecurityDiagnosticReason.tokenInvalid)
    }

    @Test func replyTokenPurposeActionAndClockSkewAreBound() throws {
        let fixture = try TokenFixture(clockSkew: 5)
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )

        let purposeMismatch = fixture.service.validateToken(
            issue.token,
            expectedPurpose: "different",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )
        #expect(purposeMismatch.reason == ChannelSecurityDiagnosticReason.purposeMismatch)

        let actionMismatch = fixture.service.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .write,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )
        #expect(actionMismatch.reason == ChannelSecurityDiagnosticReason.actionMismatch)

        let futureIssue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now.addingTimeInterval(30)
        )
        let notYetValid = fixture.service.validateToken(
            futureIssue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now
        )
        #expect(notYetValid.reason == ChannelSecurityDiagnosticReason.notYetValid)
    }

    @Test func weakSigningKeysAreRejected() throws {
        #expect(throws: ChannelReplyTokenServiceError.weakSigningKey) {
            _ = try ChannelReplyTokenService(signingKey: Data("short".utf8))
        }
    }

    @Test func nonceStoreErrorsFailClosed() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )
        let failingService = try ChannelReplyTokenService(
            signingKey: fixture.signingKey,
            nonceStore: FailingNonceStore(),
            writeKillSwitch: fixture.killSwitch,
            clockSkew: 0,
            maxTTL: 120
        )

        let validation = failingService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(!validation.accepted)
        #expect(validation.reason == ChannelSecurityDiagnosticReason.storeUnavailable)
        #expect(validation.message.contains("failed closed"))
    }

    @Test func replayNonceStorePrunesExpiredRecordsAndRetainsLiveRecords() throws {
        let root = try Self.temporaryDirectory()
        let store = ChannelReplayNonceStore(fileURL: root.appendingPathComponent("nonces.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scope = "discord.ops.thread.user"

        let expired = try store.consume(
            scope: scope,
            nonce: "expired",
            expiresAt: now.addingTimeInterval(-1),
            now: now.addingTimeInterval(-2)
        )
        let live = try store.consume(
            scope: scope,
            nonce: "live",
            expiresAt: now.addingTimeInterval(60),
            now: now
        )
        let pruned = try store.prune(expiredBefore: now)
        let expiredAfterPrune = try store.consume(
            scope: scope,
            nonce: "expired",
            expiresAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(1)
        )
        let liveAfterPrune = try store.consume(
            scope: scope,
            nonce: "live",
            expiresAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(1)
        )

        #expect(expired == ChannelNonceConsumeResult.consumed)
        #expect(live == ChannelNonceConsumeResult.consumed)
        #expect(pruned == 1)
        #expect(expiredAfterPrune == ChannelNonceConsumeResult.consumed)
        #expect(liveAfterPrune == ChannelNonceConsumeResult.replayed)
    }

    @Test func killSwitchSurvivesRestartAndInvalidatesOutstandingTokens() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )

        try fixture.killSwitch.disableWrites(now: fixture.now.addingTimeInterval(1))
        let restartedGate = ChannelWriteKillSwitch(fileURL: fixture.killSwitchURL)
        #expect(!restartedGate.snapshot().writeEnabled)

        let disabledService = try ChannelReplyTokenService(
            signingKey: fixture.signingKey,
            nonceStore: fixture.nonceStore,
            writeKillSwitch: restartedGate,
            clockSkew: 0,
            maxTTL: 120
        )
        let disabledValidation = disabledService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(2)
        )
        #expect(!disabledValidation.accepted)
        #expect(disabledValidation.reason == ChannelSecurityDiagnosticReason.disabled)

        try restartedGate.enableWrites(now: fixture.now.addingTimeInterval(3))
        let reenabledValidation = disabledService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(4)
        )
        #expect(!reenabledValidation.accepted)
        #expect(reenabledValidation.reason == ChannelSecurityDiagnosticReason.revoked)
    }

    @Test func corruptKillSwitchFailsClosedAndDoesNotResetGeneration() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )
        try Data("not-json".utf8).write(to: fixture.killSwitchURL)

        let corruptGate = ChannelWriteKillSwitch(fileURL: fixture.killSwitchURL)
        let corruptSnapshot = corruptGate.snapshot()
        #expect(!corruptSnapshot.writeEnabled)
        #expect(corruptSnapshot.generation > issue.payload.writeGateGeneration)

        let corruptService = try ChannelReplyTokenService(
            signingKey: fixture.signingKey,
            nonceStore: fixture.nonceStore,
            writeKillSwitch: corruptGate,
            clockSkew: 0,
            maxTTL: 120
        )
        let disabledValidation = corruptService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(1)
        )
        #expect(!disabledValidation.accepted)
        #expect(disabledValidation.reason == ChannelSecurityDiagnosticReason.disabled)

        try corruptGate.enableWrites(now: fixture.now.addingTimeInterval(2))
        let recoveredSnapshot = corruptGate.snapshot()
        #expect(recoveredSnapshot.writeEnabled)
        #expect(recoveredSnapshot.generation > issue.payload.writeGateGeneration)

        let recoveredValidation = corruptService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(3)
        )
        #expect(!recoveredValidation.accepted)
        #expect(recoveredValidation.reason == ChannelSecurityDiagnosticReason.revoked)
    }

    @Test func repeatedKillSwitchCorruptionRecoveryInvalidatesLaterTokens() throws {
        let fixture = try TokenFixture()
        try Data("not-json".utf8).write(to: fixture.killSwitchURL)

        let recoveredGate = ChannelWriteKillSwitch(fileURL: fixture.killSwitchURL)
        try recoveredGate.enableWrites(now: fixture.now.addingTimeInterval(1))
        let recoveredService = try ChannelReplyTokenService(
            signingKey: fixture.signingKey,
            nonceStore: fixture.nonceStore,
            writeKillSwitch: recoveredGate,
            clockSkew: 0,
            maxTTL: 120
        )
        let issue = try recoveredService.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now.addingTimeInterval(2)
        )

        try Data("not-json".utf8).write(to: fixture.killSwitchURL)
        try recoveredGate.enableWrites(now: fixture.now.addingTimeInterval(3))

        let validation = recoveredService.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(4)
        )

        #expect(recoveredGate.snapshot().generation > issue.payload.writeGateGeneration)
        #expect(!validation.accepted)
        #expect(validation.reason == ChannelSecurityDiagnosticReason.revoked)
    }

    @Test func manualRevocationRejectsOutstandingToken() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )

        let revoked = fixture.service.revokeToken(issue.token, now: fixture.now.addingTimeInterval(1))
        #expect(!revoked.accepted)
        #expect(revoked.reason == ChannelSecurityDiagnosticReason.revoked)

        let validation = fixture.service.validateToken(
            issue.token,
            expectedPurpose: "reply",
            expectedAction: .reply,
            identity: fixture.identity,
            now: fixture.now.addingTimeInterval(2)
        )
        #expect(!validation.accepted)
        #expect(validation.reason == ChannelSecurityDiagnosticReason.revoked)
    }

    @Test func diagnosticsRedactCredentialsAndReplyTokens() throws {
        let fixture = try TokenFixture()
        let issue = try fixture.service.issueToken(
            purpose: "reply",
            action: .reply,
            identity: fixture.identity,
            ttl: 60,
            now: fixture.now
        )
        let secret = "channel-super-secret"

        let redacted = ChannelSecurityDiagnostics.redact(
            "denied token=\(issue.token) secret=\(secret) api_key=abcdef123456",
            credentials: [secret],
            tokens: [issue.token]
        )

        #expect(!redacted.contains(issue.token))
        #expect(!redacted.contains(secret))
        #expect(redacted.contains(ChannelSecurityDiagnostics.replyTokenMarker))
        #expect(redacted.contains(ChannelSecurityDiagnostics.credentialMarker))
        #expect(ChannelSecurityDiagnostics.message(for: .senderDenied).contains("sender"))
        #expect(ChannelSecurityDiagnostics.message(for: .groupDenied).contains("group"))
        #expect(ChannelSecurityDiagnostics.message(for: .writeDisabled).contains("write"))
        #expect(ChannelSecurityDiagnostics.message(for: .expired).contains("expired"))
        #expect(ChannelSecurityDiagnostics.message(for: .replayed).contains("nonce"))
        #expect(ChannelSecurityDiagnostics.message(for: .disabled).contains("disabled"))
    }

    @Test func credentialVaultScopesSecretsByChannelAndNoopsWhenKeychainDisabled() {
        let backingStore = RecordingCredentialBackingStore()
        let vault = ChannelCredentialVault(backingStore: backingStore, keychainDisabled: { false })
        let discordScope = ChannelCredentialScope(kind: .discord, installationId: "guild-1")
        let slackScope = ChannelCredentialScope(kind: .slack, installationId: "workspace-1")

        #expect(vault.saveSecret(" discord-token-secret ", credentialId: "bot_token", scope: discordScope))
        #expect(vault.saveSecret("slack-token-secret", credentialId: "bot_token", scope: slackScope))
        #expect(vault.secret(credentialId: "bot_token", scope: discordScope) == "discord-token-secret")
        #expect(vault.secret(credentialId: "bot_token", scope: slackScope) == "slack-token-secret")
        #expect(backingStore.writtenAccounts.count == 2)
        #expect(backingStore.writtenAccounts[0] != backingStore.writtenAccounts[1])
        #expect(vault.deleteSecret(credentialId: "bot_token", scope: discordScope))
        #expect(vault.secret(credentialId: "bot_token", scope: discordScope) == nil)
        #expect(
            !vault.saveSecret(
                "bad-secret",
                credentialId: "bot\ntoken",
                scope: ChannelCredentialScope(kind: .discord, installationId: "guild-1")
            )
        )

        let disabledBackingStore = RecordingCredentialBackingStore()
        let disabledVault = ChannelCredentialVault(
            backingStore: disabledBackingStore,
            keychainDisabled: { true }
        )
        #expect(!disabledVault.saveSecret("should-not-write", credentialId: "bot_token", scope: discordScope))
        #expect(disabledVault.secret(credentialId: "bot_token", scope: discordScope) == nil)
        #expect(disabledVault.deleteSecret(credentialId: "bot_token", scope: discordScope))
        #expect(disabledBackingStore.calls.isEmpty)
    }

    @Test func decodedPolicyAndIdentityAreNormalized() throws {
        let policyData = Data(
            #"""
            {
              "enabled": true,
              "minimumTrustLevel": "known",
              "allowedSenderIds": [" user-a ", "user-a", " "],
              "allowedGroupIds": [" ops ", "ops"],
              "allowedThreadIds": [" thread-1 ", ""],
              "writePermission": {
                "enabled": true,
                "allowedSenderIds": [" user-a ", "user-a"],
                "allowedGroupIds": [" ops "],
                "allowedThreadIds": [" thread-1 "]
              }
            }
            """#.utf8
        )
        let policy = try JSONDecoder().decode(ChannelSecurityPolicy.self, from: policyData)

        #expect(policy.allowedSenderIds == ["user-a"])
        #expect(policy.allowedGroupIds == ["ops"])
        #expect(policy.allowedThreadIds == ["thread-1"])
        #expect(policy.writePermission?.allowedSenderIds == ["user-a"])

        let identityData = Data(
            #"""
            {
              "kind": "discord",
              "installationId": " discord-installation ",
              "groupId": " ops ",
              "threadId": " ",
              "sender": {
                "senderId": " user-a ",
                "displayName": " A. User ",
                "username": " user-a ",
                "metadata": {"team": " ops "}
              },
              "trustLevel": "verified"
            }
            """#.utf8
        )
        let identity = try JSONDecoder().decode(ChannelIdentity.self, from: identityData)

        #expect(identity.installationId == "discord-installation")
        #expect(identity.groupId == "ops")
        #expect(identity.threadId == nil)
        #expect(identity.senderId == "user-a")
        #expect(identity.sender.displayName == "A. User")
        #expect(identity.sender.metadata["team"] == "ops")
        #expect(identity.trustLevel == .untrusted)
    }

    @Test func emptyRequiredChannelIdsFailClosed() throws {
        let invalidIdentity = ChannelIdentity(
            kind: .discord,
            installationId: " ",
            groupId: "ops",
            sender: ChannelSenderMetadata(senderId: " "),
            trustLevel: .verified
        )
        let decision = ChannelSecurityPolicyEvaluator().evaluate(
            identity: invalidIdentity,
            action: .read,
            policy: ChannelSecurityPolicy()
        )

        #expect(!decision.allowed)
        #expect(decision.reason == .invalidIdentity)

        let invalidData = Data(
            #"""
            {
              "kind": "discord",
              "installationId": " ",
              "sender": {"senderId": "user-a"},
              "trustLevel": "verified"
            }
            """#.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ChannelIdentity.self, from: invalidData)
        }

        let fixture = try TokenFixture()
        #expect(throws: ChannelReplyTokenServiceError.invalidIdentity) {
            _ = try fixture.service.issueToken(
                purpose: "reply",
                action: .reply,
                identity: invalidIdentity,
                ttl: 30,
                now: fixture.now
            )
        }
    }

    fileprivate static func channelIdentity(
        senderId: String = "user-a",
        groupId: String? = "ops",
        threadId: String? = "thread-1"
    ) -> ChannelIdentity {
        ChannelIdentity(
            kind: .discord,
            installationId: "discord-installation",
            groupId: groupId,
            threadId: threadId,
            sender: ChannelSenderMetadata(
                senderId: senderId,
                displayName: "A. User",
                username: senderId
            ),
            trustLevel: .verified
        )
    }

    fileprivate static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-channel-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct TokenFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let signingKey = Data("channel-signing-key-32-bytes-long".utf8)
    let root: URL
    let nonceURL: URL
    let killSwitchURL: URL
    let nonceStore: ChannelReplayNonceStore
    let killSwitch: ChannelWriteKillSwitch
    let service: ChannelReplyTokenService
    let identity: ChannelIdentity

    init(clockSkew: TimeInterval = 0) throws {
        root = try ChannelSecurityTests.temporaryDirectory()
        nonceURL = root.appendingPathComponent("nonces.json")
        killSwitchURL = root.appendingPathComponent("kill-switch.json")
        nonceStore = ChannelReplayNonceStore(fileURL: nonceURL)
        killSwitch = ChannelWriteKillSwitch(fileURL: killSwitchURL)
        service = try ChannelReplyTokenService(
            signingKey: signingKey,
            nonceStore: nonceStore,
            writeKillSwitch: killSwitch,
            clockSkew: clockSkew,
            maxTTL: 120
        )
        identity = ChannelSecurityTests.channelIdentity()
    }
}

private enum FailingNonceStoreError: Error {
    case unavailable
}

private struct FailingNonceStore: ChannelReplyTokenNonceStore {
    func consume(
        scope: String,
        nonce: String,
        expiresAt: Date,
        now: Date
    ) throws -> ChannelNonceConsumeResult {
        throw FailingNonceStoreError.unavailable
    }

    func revoke(
        scope: String,
        nonce: String,
        expiresAt: Date,
        now: Date
    ) throws {
        throw FailingNonceStoreError.unavailable
    }

    func prune(expiredBefore: Date) throws -> Int {
        throw FailingNonceStoreError.unavailable
    }
}

private final class RecordingCredentialBackingStore: ChannelCredentialVaultBackingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var calls: [String] = []
    private(set) var writtenAccounts: [String] = []

    func write(service: String, account: String, data: Data) -> Bool {
        lock.lock()
        calls.append("write")
        writtenAccounts.append(account)
        values[key(service: service, account: account)] = data
        lock.unlock()
        return true
    }

    func read(service: String, account: String) -> Data? {
        lock.lock()
        calls.append("read")
        let value = values[key(service: service, account: account)]
        lock.unlock()
        return value
    }

    func delete(service: String, account: String) -> Bool {
        lock.lock()
        calls.append("delete")
        values.removeValue(forKey: key(service: service, account: account))
        lock.unlock()
        return true
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }
}
