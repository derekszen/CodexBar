import Crypto
import Foundation

public struct ManagedCodexAccount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let email: String
    public let providerAccountID: String?
    public let workspaceLabel: String?
    public let workspaceAccountID: String?
    public let authFingerprint: String?
    public let externalAuthFilePath: String?
    public let managedHomePath: String
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let lastAuthenticatedAt: TimeInterval?

    public init(
        id: UUID,
        email: String,
        providerAccountID: String? = nil,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        authFingerprint: String? = nil,
        externalAuthFilePath: String? = nil,
        managedHomePath: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        lastAuthenticatedAt: TimeInterval?)
    {
        self.id = id
        self.email = Self.normalizeEmail(email)
        self.providerAccountID = Self.normalizeProviderAccountID(providerAccountID)
        self.workspaceLabel = Self.normalizeWorkspaceLabel(workspaceLabel)
        self.workspaceAccountID = Self.normalizeWorkspaceAccountID(workspaceAccountID)
        self.authFingerprint = CodexAuthFingerprint.normalize(authFingerprint)
        self.externalAuthFilePath = Self.normalizeExternalAuthFilePath(externalAuthFilePath)
        self.managedHomePath = managedHomePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizeProviderAccountID(_ providerAccountID: String?) -> String? {
        CodexIdentityResolver.normalizeAccountID(providerAccountID)
    }

    public static func normalizeWorkspaceLabel(_ workspaceLabel: String?) -> String? {
        guard let trimmed = workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func normalizeExternalAuthFilePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL.path
    }

    public static func normalizeWorkspaceAccountID(_ workspaceAccountID: String?) -> String? {
        guard let trimmed = workspaceAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            email: container.decode(String.self, forKey: .email),
            providerAccountID: container.decodeIfPresent(String.self, forKey: .providerAccountID),
            workspaceLabel: container.decodeIfPresent(String.self, forKey: .workspaceLabel),
            workspaceAccountID: container.decodeIfPresent(String.self, forKey: .workspaceAccountID),
            authFingerprint: container.decodeIfPresent(String.self, forKey: .authFingerprint),
            externalAuthFilePath: container.decodeIfPresent(String.self, forKey: .externalAuthFilePath),
            managedHomePath: container.decode(String.self, forKey: .managedHomePath),
            createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
            updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt),
            lastAuthenticatedAt: container.decodeIfPresent(TimeInterval.self, forKey: .lastAuthenticatedAt))
    }
}

public enum CodexAuthFingerprint {
    public static func authFileURL(homePath: String) -> URL {
        URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    public static func fingerprint(homePath: String, fileManager: FileManager = .default) -> String? {
        let url = self.authFileURL(homePath: homePath)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return self.fingerprint(data: data)
    }

    public static func fingerprint(env: [String: String], fileManager: FileManager = .default) -> String? {
        self.fingerprint(
            homePath: CodexHomeScope.ambientHomeURL(env: env, fileManager: fileManager).path,
            fileManager: fileManager)
    }

    public static func fingerprint(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func fingerprint(fileURL: URL, fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        return self.fingerprint(data: data)
    }

    public static func normalize(_ fingerprint: String?) -> String? {
        guard let trimmed = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

public enum CodexManagedAccountAuth {
    public static let authFileEnvironmentKey = "CODEX_AUTH_FILE"

    public static func environment(
        base: [String: String],
        account: ManagedCodexAccount,
        fileManager: FileManager = .default) -> [String: String]
    {
        var environment = CodexHomeScope.scopedEnvironment(
            base: base,
            codexHome: account.managedHomePath)
        environment.removeValue(forKey: self.authFileEnvironmentKey)
        if let authFileURL = self.resolvedExternalAuthFileURL(for: account, fileManager: fileManager) {
            environment[self.authFileEnvironmentKey] = authFileURL.path
        }
        return environment
    }

    public static func fingerprint(
        for account: ManagedCodexAccount,
        fileManager: FileManager = .default) -> String?
    {
        if let authFileURL = self.resolvedExternalAuthFileURL(for: account, fileManager: fileManager) {
            return CodexAuthFingerprint.fingerprint(fileURL: authFileURL, fileManager: fileManager)
        }
        return CodexAuthFingerprint.fingerprint(homePath: account.managedHomePath, fileManager: fileManager)
    }

    public static func resolvedExternalAuthFileURL(
        for account: ManagedCodexAccount,
        fileManager: FileManager = .default) -> URL?
    {
        guard let path = account.externalAuthFilePath else { return nil }
        let configuredURL = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        if fileManager.fileExists(atPath: configuredURL.path) {
            return configuredURL
        }

        let parent = configuredURL.deletingLastPathComponent()
        let alternateDirectoryName: String? = switch parent.lastPathComponent {
        case "auths":
            "auths.disabled"
        case "auths.disabled":
            "auths"
        default:
            nil
        }
        guard let alternateDirectoryName else { return nil }
        let alternateURL = parent.deletingLastPathComponent()
            .appendingPathComponent(alternateDirectoryName, isDirectory: true)
            .appendingPathComponent(configuredURL.lastPathComponent, isDirectory: false)
        return fileManager.fileExists(atPath: alternateURL.path) ? alternateURL : nil
    }
}

public struct ManagedCodexAccountSet: Codable, Sendable {
    public let version: Int
    public let accounts: [ManagedCodexAccount]

    public init(version: Int, accounts: [ManagedCodexAccount]) {
        self.version = version
        self.accounts = Self.sanitizedAccounts(accounts)
    }

    public func account(id: UUID) -> ManagedCodexAccount? {
        self.accounts.first { $0.id == id }
    }

    public func account(email: String, providerAccountID: String? = nil) -> ManagedCodexAccount? {
        let normalizedEmail = ManagedCodexAccount.normalizeEmail(email)
        if let normalizedProviderAccountID = ManagedCodexAccount.normalizeProviderAccountID(providerAccountID),
           let exactMatch = self.accounts.first(where: {
               $0.email == normalizedEmail && $0.providerAccountID == normalizedProviderAccountID
           })
        {
            return exactMatch
        }
        if providerAccountID != nil {
            return self.accounts.first { $0.email == normalizedEmail && $0.providerAccountID == nil }
        }
        return self.accounts.first { $0.email == normalizedEmail }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.accounts = try container.decode([ManagedCodexAccount].self, forKey: .accounts)
    }

    private static func sanitizedAccounts(_ accounts: [ManagedCodexAccount]) -> [ManagedCodexAccount] {
        var seenIDs: Set<UUID> = []
        var seenProviderAccountKeys: Set<String> = []
        var seenLegacyEmails: Set<String> = []
        var sanitized: [ManagedCodexAccount] = []
        sanitized.reserveCapacity(accounts.count)

        for account in accounts {
            guard seenIDs.insert(account.id).inserted else { continue }
            if let providerAccountID = account.providerAccountID {
                guard seenProviderAccountKeys.insert("\(account.email)\u{0}\(providerAccountID)").inserted else {
                    continue
                }
            } else {
                guard seenLegacyEmails.insert(account.email).inserted else { continue }
            }
            sanitized.append(account)
        }

        return sanitized
    }
}
