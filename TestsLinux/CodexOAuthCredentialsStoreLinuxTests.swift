import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthCredentialsStoreLinuxTests {
    @Test
    func `parses AI router top level credentials`() throws {
        let json = """
        {
          "access_token": "access-token",
          "refresh_token": "refresh-token",
          "id_token": "id-token",
          "account_id": "account-123",
          "last_refresh": "2025-12-20T12:34:56Z"
        }
        """
        let credentials = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))

        #expect(credentials.accessToken == "access-token")
        #expect(credentials.refreshToken == "refresh-token")
        #expect(credentials.idToken == "id-token")
        #expect(credentials.accountId == "account-123")
        #expect(credentials.lastRefresh != nil)
    }

    @Test
    func `save keeps auth JSON private`() throws {
        #if os(macOS) || os(Linux)
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-123",
            lastRefresh: Date())

        try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": codexHome.path])

        let authURL = codexHome.appendingPathComponent("auth.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `external auth file overrides codex home`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-external-auth-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("home", isDirectory: true)
        let externalAuth = root.appendingPathComponent("ai-router.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data("""
        {"tokens":{"access_token":"home-access","refresh_token":"home-refresh"}}
        """.utf8).write(to: codexHome.appendingPathComponent("auth.json"))
        try Data("""
        {"access_token":"external-access","refresh_token":"external-refresh"}
        """.utf8).write(to: externalAuth)

        let credentials = try CodexOAuthCredentialsStore.load(env: [
            "CODEX_HOME": codexHome.path,
            CodexManagedAccountAuth.authFileEnvironmentKey: externalAuth.path,
        ])

        #expect(credentials.accessToken == "external-access")
        #expect(credentials.refreshToken == "external-refresh")
    }

    @Test
    func `save preserves AI router top level shape`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-ai-router-save-\(UUID().uuidString)", isDirectory: true)
        let externalAuth = root.appendingPathComponent("codex-user@example.com-pro.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {
          "access_token": "old-access",
          "refresh_token": "old-refresh",
          "id_token": "old-id",
          "account_id": "old-account",
          "disabled": false,
          "email": "user@example.com",
          "type": "codex"
        }
        """.utf8).write(to: externalAuth)

        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                idToken: "new-id",
                accountId: "new-account",
                lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)),
            env: [CodexManagedAccountAuth.authFileEnvironmentKey: externalAuth.path])

        let data = try Data(contentsOf: externalAuth)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["access_token"] as? String == "new-access")
        #expect(json["refresh_token"] as? String == "new-refresh")
        #expect(json["id_token"] as? String == "new-id")
        #expect(json["account_id"] as? String == "new-account")
        #expect(json["tokens"] == nil)
        #expect(json["disabled"] as? Bool == false)
        #expect(json["email"] as? String == "user@example.com")
        #expect(json["type"] as? String == "codex")
    }

    @Test
    func `imported external auth overrides matching ambient account`() {
        let accountID = UUID()
        let managed = ManagedCodexAccount(
            id: accountID,
            email: "user@example.com",
            providerAccountID: "account-user",
            authFingerprint: "imported-auth",
            externalAuthFilePath: "/tmp/ai-router/auths/codex-user@example.com-pro.json",
            managedHomePath: "/tmp/managed-user",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let live = ObservedSystemCodexAccount(
            email: "user@example.com",
            authFingerprint: "ambient-auth",
            codexHomePath: "/tmp/ambient",
            observedAt: Date(),
            identity: .providerAccount(id: "account-user"))
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [managed],
            activeStoredAccount: nil,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: managed,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: [accountID: .providerAccount(id: "account-user")],
            storedAccountRuntimeEmails: [accountID: "user@example.com"])

        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        #expect(resolution.resolvedSource == .managedAccount(id: accountID))
        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.activeVisibleAccountID == "user@example.com")
        #expect(projection.source(forVisibleAccountID: "user@example.com") == .managedAccount(id: accountID))
    }

    @Test
    func `external auth follows AI router active directory move`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-ai-router-move-\(UUID().uuidString)", isDirectory: true)
        let activeDirectory = root.appendingPathComponent("auths", isDirectory: true)
        let disabledDirectory = root.appendingPathComponent("auths.disabled", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "codex-user@example.com-pro.json"
        let originalURL = activeDirectory.appendingPathComponent(fileName)
        let movedURL = disabledDirectory.appendingPathComponent(fileName)
        try Data("{}".utf8).write(to: originalURL)
        let account = ManagedCodexAccount(
            id: UUID(),
            email: "user@example.com",
            externalAuthFilePath: originalURL.path,
            managedHomePath: root.appendingPathComponent("managed").path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)

        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let resolved = CodexManagedAccountAuth.resolvedExternalAuthFileURL(for: account)
        #expect(resolved?.standardizedFileURL == movedURL.standardizedFileURL)
    }
}
