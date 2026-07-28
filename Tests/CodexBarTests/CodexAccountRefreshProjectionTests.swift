import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `stale stacked projection collapse runs single codex fetch`() async throws {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-stacked-collapse-single-fetch")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
            settings._test_managedCodexAccountStoreURL = nil
        }
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.codexActiveSource = .liveSystem
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "live-collapse@example.com",
            identity: .providerAccount(id: "acct-live-collapse"))

        let managedAccountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-191919191919"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed-collapse@example.com",
            managedHomePath: "/tmp/codex-managed-collapse",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let staleStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        let emptyStoreURL = try self.makeManagedAccountStoreURL(accounts: [])
        defer {
            try? FileManager.default.removeItem(at: staleStoreURL)
            try? FileManager.default.removeItem(at: emptyStoreURL)
        }
        settings._test_managedCodexAccountStoreURL = staleStoreURL
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot
        #expect(CodexVisibleAccountProjection.make(from: staleReconciliationSnapshot).visibleAccounts.count == 2)

        settings._test_managedCodexAccountStoreURL = emptyStoreURL
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)

        let store = self.makeUsageStore(settings: settings)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "live-collapse@example.com", usedPercent: 42))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 42)
        #expect(store.codexAccountSnapshots.count == 1)
        #expect(store.codexAccountSnapshots.first?.account.email == "live-collapse@example.com")
        #expect(store.codexAccountSnapshots.first?.snapshot?.primary?.usedPercent == 42)
    }

    @Test
    func `stacked visible refresh discards selected success after managed auth file is removed`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-auth-file-removed")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-202020202020"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-212121212121"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-auth-removed-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-visible-managed-auth-removed-sibling-\(UUID().uuidString)",
                isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-removed@example.com",
            plan: "Pro",
            accountId: "acct-managed-removed")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-removed@example.com",
            providerAccountID: "acct-managed-removed",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-removed",
            authFingerprint: oldFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-removed-sibling@example.com",
            providerAccountID: "acct-managed-removed-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-removed-sibling",
            authFingerprint: "sibling-managed-removed",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-removed-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try FileManager.default.removeItem(at: targetHome)
        await blocker.resume(with: .success(self.codexSnapshot(email: "managed-removed@example.com", usedPercent: 44)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-removed"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-removed"
        })
    }

    @Test
    func `startup snapshot hydration refreshes managed auth fingerprint with composite disk owner`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-startup-managed-auth-hydration")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let accountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-222222222222"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-startup-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed-startup@example.com",
            plan: "Pro",
            accountId: "acct-managed-startup")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let managedAccount = ManagedCodexAccount(
            id: accountID,
            email: "managed-startup@example.com",
            authFingerprint: oldFingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-startup-\(UUID().uuidString).json")
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: accountID)

        let staleAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts
            .first { $0.storedAccountID == accountID })
        #expect(staleAccount.authFingerprint == oldFingerprint)
        #expect(staleAccount.workspaceAccountID == "acct-managed-startup")

        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed-startup@example.com",
            plan: "Team",
            accountId: "acct-managed-startup")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        #expect(newFingerprint != oldFingerprint)

        let freshAccount = CodexVisibleAccount(
            id: staleAccount.id,
            email: staleAccount.email,
            workspaceLabel: staleAccount.workspaceLabel,
            workspaceAccountID: staleAccount.workspaceAccountID,
            authFingerprint: newFingerprint,
            storedAccountID: staleAccount.storedAccountID,
            selectionSource: staleAccount.selectionSource,
            isActive: staleAccount.isActive,
            isLive: staleAccount.isLive,
            canReauthenticate: staleAccount.canReauthenticate,
            canRemove: staleAccount.canRemove)
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL)
        snapshotStore.store([
            CodexAccountUsageSnapshot(
                account: freshAccount,
                snapshot: self.codexSnapshot(email: freshAccount.email, usedPercent: 64),
                error: nil,
                sourceLabel: "cached"),
        ])
        #expect(snapshotStore.load(for: [staleAccount]).count == 1)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)

        let hydrated = try #require(store.codexAccountSnapshots.first)
        #expect(store.codexAccountSnapshots.count == 1)
        #expect(hydrated.id == freshAccount.id)
        #expect(hydrated.account.authFingerprint == newFingerprint)
        #expect(hydrated.snapshot?.primary?.usedPercent == 64)
    }

    @Test
    func `snapshot hydration never crosses members of the same provider workspace`() {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-provider-member-isolation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let priorAccount = CodexVisibleAccount(
            id: "shared-row-id",
            email: "first-member@example.com",
            workspaceAccountID: "workspace-shared-by-members",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let otherMember = CodexVisibleAccount(
            id: "shared-row-id",
            email: "second-member@example.com",
            workspaceAccountID: "workspace-shared-by-members",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL)
        snapshotStore.store([
            CodexAccountUsageSnapshot(
                account: priorAccount,
                snapshot: self.codexSnapshot(email: priorAccount.email, usedPercent: 64),
                error: nil,
                sourceLabel: "cached"),
        ])

        #expect(snapshotStore.load(for: [otherMember]).isEmpty)
    }

    @Test
    func `stacked refresh shows weekly usage for three ai router accounts`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-three-ai-router-accounts")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.codexActiveSource = .liveSystem

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-ai-router-three-\(UUID().uuidString)", isDirectory: true)
        let authDirectory = root.appendingPathComponent("auths", isDirectory: true)
        let disabledDirectory = root.appendingPathComponent("auths.disabled", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)

        let accountFixtures = try [
            AIRouterAccountFixture(
                id: #require(UUID(uuidString: "11111111-AAAA-BBBB-CCCC-111111111111")),
                email: "first@example.com",
                accountID: "acct-first",
                authFile: authDirectory.appendingPathComponent("codex-first@example.com-pro.json"),
                usedPercent: 28),
            AIRouterAccountFixture(
                id: #require(UUID(uuidString: "22222222-AAAA-BBBB-CCCC-222222222222")),
                email: "second@example.com",
                accountID: "acct-second",
                authFile: disabledDirectory.appendingPathComponent("codex-second@example.com-pro.json"),
                usedPercent: 1),
            AIRouterAccountFixture(
                id: #require(UUID(uuidString: "33333333-AAAA-BBBB-CCCC-333333333333")),
                email: "third@example.com",
                accountID: "acct-third",
                authFile: disabledDirectory.appendingPathComponent("codex-third@example.com-pro.json"),
                usedPercent: 8),
        ]
        for fixture in accountFixtures {
            let email = fixture.email
            let accountID = fixture.accountID
            let authFile = fixture.authFile
            let json: [String: Any] = [
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "id_token": Self.fakeJWT(email: email, plan: "pro", accountId: accountID),
                "account_id": accountID,
            ]
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: authFile)
        }

        let managedAccounts = accountFixtures.map { fixture in
            ManagedCodexAccount(
                id: fixture.id,
                email: fixture.email,
                providerAccountID: fixture.accountID,
                authFingerprint: CodexAuthFingerprint.fingerprint(fileURL: fixture.authFile),
                externalAuthFilePath: fixture.authFile.path,
                managedHomePath: root.appendingPathComponent(fixture.id.uuidString, isDirectory: true).path,
                createdAt: 1,
                updatedAt: 2,
                lastAuthenticatedAt: 2)
        }
        let storeURL = try self.makeManagedAccountStoreURL(accounts: managedAccounts)
        defer {
            settings._test_liveSystemCodexAccount = nil
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: root)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "first@example.com",
            authFingerprint: "stale-ambient-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-first"))

        let expectedUsageByAuthPath = Dictionary(uniqueKeysWithValues: accountFixtures.map { fixture in
            (fixture.authFile.standardizedFileURL.path, (email: fixture.email, usedPercent: fixture.usedPercent))
        })
        let store = self.makeUsageStore(settings: settings)
        self.installContextualCodexProvider(on: store) { context in
            let authPath = try #require(context.env[CodexManagedAccountAuth.authFileEnvironmentKey])
            let expected = try #require(expectedUsageByAuthPath[authPath])
            return UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: expected.usedPercent,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: expected.email,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }

        await store.refreshCodexVisibleAccountsForMenu()

        #expect(settings.codexVisibleAccountProjection.visibleAccounts.count == 3)
        #expect(store.codexAccountSnapshots.count == 3)
        #expect(Set(store.codexAccountSnapshots.compactMap { $0.snapshot?.accountEmail(for: .codex) }) == Set(
            accountFixtures.map(\.email)))
        #expect(Set(store.codexAccountSnapshots.compactMap { $0.snapshot?.secondary?.usedPercent }) == [1, 8, 28])
        let firstAccount = try #require(store.codexAccountSnapshots.first {
            $0.account.email == "first@example.com"
        })
        #expect(firstAccount.account.selectionSource == .managedAccount(id: accountFixtures[0].id))
        #expect(firstAccount.snapshot?.secondary?.usedPercent == 28)
    }
}

private struct AIRouterAccountFixture {
    let id: UUID
    let email: String
    let accountID: String
    let authFile: URL
    let usedPercent: Double
}
