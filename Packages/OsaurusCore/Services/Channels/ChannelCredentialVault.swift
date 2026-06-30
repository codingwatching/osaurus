//
//  ChannelCredentialVault.swift
//  osaurus
//
//  Channel-scoped Keychain wrapper for future adapter credentials.
//

import Foundation

protocol ChannelCredentialVaultBackingStore: Sendable {
    func write(service: String, account: String, data: Data) -> Bool
    func read(service: String, account: String) -> Data?
    func delete(service: String, account: String) -> Bool
}

struct KeychainChannelCredentialVaultBackingStore: ChannelCredentialVaultBackingStore {
    func write(service: String, account: String, data: Data) -> Bool {
        Keychain.write(service: service, account: account, data: data)
    }

    func read(service: String, account: String) -> Data? {
        Keychain.read(service: service, account: account)
    }

    func delete(service: String, account: String) -> Bool {
        Keychain.delete(service: service, account: account)
    }
}

final class InMemoryChannelCredentialVaultBackingStore: ChannelCredentialVaultBackingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func write(service: String, account: String, data: Data) -> Bool {
        lock.lock()
        values[key(service: service, account: account)] = data
        lock.unlock()
        return true
    }

    func read(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(service: service, account: account)]
    }

    func delete(service: String, account: String) -> Bool {
        lock.lock()
        values.removeValue(forKey: key(service: service, account: account))
        lock.unlock()
        return true
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }
}

final class ChannelCredentialVault: @unchecked Sendable {
    static let shared = ChannelCredentialVault()

    private static let service = "ai.osaurus.channels"

    private let backingStore: any ChannelCredentialVaultBackingStore
    private let keychainDisabled: @Sendable () -> Bool

    init(
        backingStore: (any ChannelCredentialVaultBackingStore)? = nil,
        keychainDisabled: @escaping @Sendable () -> Bool = {
            KeychainQueryHelpers.disablesKeychainForProcess
        }
    ) {
        self.backingStore = backingStore ?? Self.defaultBackingStore()
        self.keychainDisabled = keychainDisabled
    }

    @discardableResult
    func saveSecret(_ value: String, credentialId: String, scope: ChannelCredentialScope) -> Bool {
        guard !keychainDisabled() else { return false }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = account(credentialId: credentialId, scope: scope),
            let data = normalizedValue.data(using: .utf8),
            !normalizedValue.isEmpty
        else {
            return false
        }
        return backingStore.write(service: Self.service, account: account, data: data)
    }

    func secret(credentialId: String, scope: ChannelCredentialScope) -> String? {
        guard !keychainDisabled() else { return nil }
        guard let account = account(credentialId: credentialId, scope: scope) else { return nil }
        return backingStore.read(service: Self.service, account: account)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func hasSecret(credentialId: String, scope: ChannelCredentialScope) -> Bool {
        secret(credentialId: credentialId, scope: scope) != nil
    }

    @discardableResult
    func deleteSecret(credentialId: String, scope: ChannelCredentialScope) -> Bool {
        guard !keychainDisabled() else { return true }
        guard let account = account(credentialId: credentialId, scope: scope) else { return true }
        return backingStore.delete(service: Self.service, account: account)
    }

    func accountForDiagnostics(credentialId: String, scope: ChannelCredentialScope) -> String? {
        account(credentialId: credentialId, scope: scope)
    }

    private static func defaultBackingStore() -> any ChannelCredentialVaultBackingStore {
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return InMemoryChannelCredentialVaultBackingStore()
        }
        return KeychainChannelCredentialVaultBackingStore()
    }

    private func account(credentialId: String, scope: ChannelCredentialScope) -> String? {
        let credentialId = ChannelIdentity.normalizedRequiredId(credentialId)
        guard !credentialId.isEmpty,
            !scope.installationId.isEmpty,
            !containsLineBreak(credentialId),
            !containsLineBreak(scope.installationId),
            !containsLineBreak(scope.groupId),
            !containsLineBreak(scope.threadId)
        else {
            return nil
        }

        let parts = [
            "v1",
            scope.kind.rawValue,
            scope.installationId,
            scope.groupId ?? "_",
            scope.threadId ?? "_",
            credentialId,
        ].map(ChannelSecurityEncoding.accountComponent)
        return parts.joined(separator: ".")
    }

    private func containsLineBreak(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.contains("\n") || value.contains("\r")
    }
}
