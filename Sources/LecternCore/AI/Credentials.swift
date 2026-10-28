import Foundation
import Security

/// Somewhere to keep secrets. The library folder never holds any.
public protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    /// Nil deletes.
    func set(_ data: Data?, for key: String) throws
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// The user's login keychain, one generic password per key.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    public func data(for key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    public func set(_ data: Data?, for key: String) throws {
        guard let data else {
            let status = SecItemDelete(query(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}

/// Kept in memory only; for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func data(for key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    public func set(_ data: Data?, for key: String) throws {
        lock.withLock { items[key] = data }
    }
}

/// The keys and sign-ins the user linked, by provider.
public struct Credentials: Sendable {
    let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    public func apiKey(for kind: ProviderKind) throws -> String? {
        try store.data(for: "\(kind.rawValue).key").map { String(decoding: $0, as: UTF8.self) }
    }

    public func setAPIKey(_ key: String?, for kind: ProviderKind) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.set(trimmed?.isEmpty == false ? Data(trimmed!.utf8) : nil, for: "\(kind.rawValue).key")
    }

    /// The key for one custom endpoint, by the endpoint's id.
    public func endpointKey(_ id: String) throws -> String? {
        try store.data(for: "endpoint.\(id).key").map { String(decoding: $0, as: UTF8.self) }
    }

    public func setEndpointKey(_ key: String?, for id: String) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.set(trimmed?.isEmpty == false ? Data(trimmed!.utf8) : nil, for: "endpoint.\(id).key")
    }

    public func chatGPTAccount() throws -> ChatGPTAccount? {
        guard let data = try store.data(for: "chatGPT.account") else { return nil }
        return try JSONStore.decoder.decode(ChatGPTAccount.self, from: data)
    }

    public func setChatGPTAccount(_ account: ChatGPTAccount?) throws {
        try store.set(account.map { try JSONStore.encoder.encode($0) }, for: "chatGPT.account")
    }

    /// The ChatGPT account linked through the Codex sign-in.
    public func codexAccount() throws -> CodexAccount? {
        guard let data = try store.data(for: "codex.account") else { return nil }
        return try JSONStore.decoder.decode(CodexAccount.self, from: data)
    }

    public func setCodexAccount(_ account: CodexAccount?) throws {
        try store.set(account.map { try JSONStore.encoder.encode($0) }, for: "codex.account")
    }

    /// The Google account linked through the Antigravity sign-in.
    public func antigravityAccount() throws -> AntigravityAccount? {
        guard let data = try store.data(for: "antigravity.account") else { return nil }
        return try JSONStore.decoder.decode(AntigravityAccount.self, from: data)
    }

    public func setAntigravityAccount(_ account: AntigravityAccount?) throws {
        try store.set(account.map { try JSONStore.encoder.encode($0) }, for: "antigravity.account")
    }

    /// The id this Mac signs in to ChatGPT with, created on first use and kept.
    public func hostID() throws -> String {
        if let data = try store.data(for: "chatGPT.host") { return String(decoding: data, as: UTF8.self) }
        let id = UUID().uuidString.lowercased()
        try store.set(Data(id.utf8), for: "chatGPT.host")
        return id
    }
}
