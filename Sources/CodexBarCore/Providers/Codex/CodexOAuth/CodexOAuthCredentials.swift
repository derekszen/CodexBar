#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public struct CodexOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
    }

    public var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

public enum CodexOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case decodeFailed(String)
    case missingTokens

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth.json not found. Run `codex` to log in."
        case let .decodeFailed(message):
            "Failed to decode Codex credentials: \(message)"
        case .missingTokens:
            "Codex auth.json exists but contains no tokens."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    private static func authFilePath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        if let rawPath = env[CodexManagedAccountAuth.authFileEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        {
            return URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        }
        return CodexHomeScope
            .ambientHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("auth.json")
    }

    public static func load(env: [String: String] = ProcessInfo.processInfo
        .environment) throws -> CodexOAuthCredentials
    {
        let url = self.authFilePath(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        return try self.parse(data: data)
    }

    public static func loadOAuthTokens(env: [String: String] = ProcessInfo.processInfo
        .environment) throws -> CodexOAuthCredentials
    {
        let url = self.authFilePath(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        guard let credentials = try self.tokenCredentials(data: data) else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return credentials
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }

        if let apiKeyCredentials = Self.apiKeyCredentials(in: json) {
            return apiKeyCredentials
        }

        if let tokenCredentials = Self.tokenCredentials(in: json) {
            return tokenCredentials
        }

        throw CodexOAuthCredentialsError.missingTokens
    }

    private static func tokenCredentials(data: Data) throws -> CodexOAuthCredentials? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }
        return self.tokenCredentials(in: json)
    }

    private static func tokenCredentials(in json: [String: Any]) -> CodexOAuthCredentials? {
        let tokens: [String: Any]
        if let nestedTokens = json["tokens"] as? [String: Any] {
            tokens = nestedTokens
        } else if Self.stringValue(in: json, snakeCaseKey: "access_token", camelCaseKey: "accessToken") != nil ||
            Self.stringValue(in: json, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken") != nil
        {
            tokens = json
        } else {
            return nil
        }

        guard let accessToken = stringValue(
            in: tokens,
            snakeCaseKey: "access_token",
            camelCaseKey: "accessToken"),
            let refreshToken = stringValue(
                in: tokens,
                snakeCaseKey: "refresh_token",
                camelCaseKey: "refreshToken"),
            !accessToken.isEmpty
        else {
            return nil
        }

        let idToken = Self.stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        let accountId = Self.stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId")
        let lastRefresh = Self.parseLastRefresh(from: json["last_refresh"])

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: lastRefresh)
    }

    private static func apiKeyCredentials(in json: [String: Any]) -> CodexOAuthCredentials? {
        guard let apiKey = json["OPENAI_API_KEY"] as? String,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return CodexOAuthCredentials(
            accessToken: apiKey,
            refreshToken: "",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil)
    }

    public static func save(
        _ credentials: CodexOAuthCredentials,
        env: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        let url = self.authFilePath(env: env)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }

        var tokens: [String: Any] = [:]
        Self.setStringValue(
            credentials.accessToken,
            in: &tokens,
            snakeCaseKey: "access_token",
            camelCaseKey: "accessToken")
        Self.setStringValue(
            credentials.refreshToken,
            in: &tokens,
            snakeCaseKey: "refresh_token",
            camelCaseKey: "refreshToken")
        Self.setOptionalStringValue(
            credentials.idToken,
            in: &tokens,
            snakeCaseKey: "id_token",
            camelCaseKey: "idToken")
        Self.setOptionalStringValue(
            credentials.accountId,
            in: &tokens,
            snakeCaseKey: "account_id",
            camelCaseKey: "accountId")

        let hasTopLevelTokens = json["tokens"] == nil && (
            Self.stringValue(in: json, snakeCaseKey: "access_token", camelCaseKey: "accessToken") != nil ||
                Self.stringValue(in: json, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken") != nil)
        if hasTopLevelTokens {
            Self.setStringValue(
                credentials.accessToken,
                in: &json,
                snakeCaseKey: "access_token",
                camelCaseKey: "accessToken")
            Self.setStringValue(
                credentials.refreshToken,
                in: &json,
                snakeCaseKey: "refresh_token",
                camelCaseKey: "refreshToken")
            Self.setOptionalStringValue(
                credentials.idToken,
                in: &json,
                snakeCaseKey: "id_token",
                camelCaseKey: "idToken")
            Self.setOptionalStringValue(
                credentials.accountId,
                in: &json,
                snakeCaseKey: "account_id",
                camelCaseKey: "accountId")
        } else {
            json["tokens"] = tokens
        }
        json["last_refresh"] = ISO8601DateFormatter().string(from: credentials.lastRefresh ?? Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CredentialFileWriter.writePrivate(data, to: url)
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
        -> String?
    {
        if let value = dictionary[snakeCaseKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    private static func setStringValue(
        _ value: String,
        in dictionary: inout [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
    {
        if dictionary[camelCaseKey] != nil, dictionary[snakeCaseKey] == nil {
            dictionary[camelCaseKey] = value
        } else {
            dictionary[snakeCaseKey] = value
        }
    }

    private static func setOptionalStringValue(
        _ value: String?,
        in dictionary: inout [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
    {
        guard let value else {
            dictionary.removeValue(forKey: snakeCaseKey)
            dictionary.removeValue(forKey: camelCaseKey)
            return
        }
        self.setStringValue(
            value,
            in: &dictionary,
            snakeCaseKey: snakeCaseKey,
            camelCaseKey: camelCaseKey)
    }
}

#if DEBUG
extension CodexOAuthCredentialsStore {
    static func _authFileURLForTesting(env: [String: String]) -> URL {
        self.authFilePath(env: env)
    }

    static func _writePrivateFileForTesting(
        _ data: Data,
        to url: URL,
        beforePublish: @escaping (URL) throws -> Void) throws
    {
        try CredentialFileWriter.writePrivate(data, to: url, beforePublish: beforePublish)
    }
}
#endif
