import AppKit
import CodexBarCore
import Foundation

protocol ManagedCodexHomeProducing: Sendable {
    func makeHomeURL() -> URL
    func validateManagedHomeForDeletion(_ url: URL) throws
}

protocol ManagedCodexLoginRunning: Sendable {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result
}

protocol ManagedCodexIdentityReading: Sendable {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount
}

protocol ManagedCodexWorkspaceResolving: Sendable {
    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity]
}

extension ManagedCodexWorkspaceResolving {
    func availableWorkspaceIdentities(homePath _: String) async -> [CodexOpenAIWorkspaceIdentity] {
        []
    }
}

protocol ManagedCodexWorkspaceSelecting: Sendable {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
}

enum ManagedCodexAccountServiceError: Error, Equatable {
    case loginFailed(CodexLoginRunner.Result)
    case missingEmail
    case workspaceSelectionCancelled
    case unsafeManagedHome(String)
}

struct ManagedCodexAIRouterImportResult {
    let scannedFileCount: Int
    let skippedFileCount: Int
    let importedAccounts: [ManagedCodexAccount]
    let updatedAccounts: [ManagedCodexAccount]
    let preferredAccount: ManagedCodexAccount?

    var affectedAccounts: [ManagedCodexAccount] {
        self.importedAccounts + self.updatedAccounts
    }

    var affectedCount: Int {
        self.importedAccounts.count + self.updatedAccounts.count
    }
}

extension ManagedCodexAccountServiceError {
    var userFacingMessage: String {
        switch self {
        case let .loginFailed(result):
            CodexLoginAlertPresentation.managedLoginFailureMessage(for: result)
        case .missingEmail:
            L("managed_login_missing_email")
        case .workspaceSelectionCancelled:
            L("workspace_selection_cancelled")
        case let .unsafeManagedHome(path):
            String(format: L("unsafe_managed_home"), path)
        }
    }
}

struct ManagedCodexHomeFactory: ManagedCodexHomeProducing {
    let root: URL

    init(root: URL = Self.defaultRootURL(), fileManager: FileManager = .default) {
        let standardizedRoot = root.standardizedFileURL
        if standardizedRoot.path != root.path {
            self.root = standardizedRoot
        } else {
            self.root = root
        }
        _ = fileManager
    }

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        let rootPath = self.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(rootPrefix), targetPath != rootPath else {
            throw ManagedCodexAccountServiceError.unsafeManagedHome(url.path)
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }
}

struct DefaultManagedCodexLoginRunner: ManagedCodexLoginRunning {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result {
        await CodexLoginRunner.run(homePath: homePath, timeout: timeout)
    }
}

struct DefaultManagedCodexIdentityReader: ManagedCodexIdentityReading {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        return UsageFetcher(environment: env).loadAuthBackedCodexAccount()
    }
}

struct DefaultManagedCodexWorkspaceResolver: ManagedCodexWorkspaceResolving {
    private let workspaceCache: CodexOpenAIWorkspaceIdentityCache

    init(
        workspaceCache: CodexOpenAIWorkspaceIdentityCache = CodexOpenAIWorkspaceIdentityCache())
    {
        self.workspaceCache = workspaceCache
    }

    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity? {
        let normalizedProviderAccountID = ManagedCodexAccount.normalizeProviderAccountID(providerAccountID)
            ?? providerAccountID
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)

        if let credentials = try? CodexOAuthCredentialsStore.load(env: env),
           let authoritativeIdentity = try? await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials)
        {
            try? self.workspaceCache.store(authoritativeIdentity)
            return authoritativeIdentity
        }

        let cachedLabel = self.workspaceCache.workspaceLabel(for: normalizedProviderAccountID)
        return CodexOpenAIWorkspaceIdentity(
            workspaceAccountID: normalizedProviderAccountID,
            workspaceLabel: cachedLabel)
    }

    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity] {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: env),
              let identities = try? await CodexOpenAIWorkspaceResolver.listWorkspaces(credentials: credentials)
        else {
            return []
        }

        for identity in identities {
            try? self.workspaceCache.store(identity)
        }
        return identities
    }
}

struct CodexWorkspaceAlertSelector: ManagedCodexWorkspaceSelecting {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
    {
        guard workspaces.count > 1 else { return workspaces.first }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        let sortedWorkspaces = workspaces.sorted { lhs, rhs in
            self.workspaceTitle(lhs) < self.workspaceTitle(rhs)
        }
        for workspace in sortedWorkspaces {
            popup.addItem(withTitle: self.workspaceTitle(workspace))
            popup.lastItem?.representedObject = workspace.workspaceAccountID
        }
        if let currentWorkspaceID,
           let selectedIndex = sortedWorkspaces.firstIndex(where: { $0.workspaceAccountID == currentWorkspaceID })
        {
            popup.selectItem(at: selectedIndex)
        }

        let alert = NSAlert()
        alert.messageText = L("Choose Codex workspace")
        alert.informativeText = String(format: L("multiple_workspaces_found"), email)
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Add Workspace"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let selectedWorkspaceID = popup.selectedItem?.representedObject as? String
        return sortedWorkspaces.first { $0.workspaceAccountID == selectedWorkspaceID }
    }

    private func workspaceTitle(_ workspace: CodexOpenAIWorkspaceIdentity) -> String {
        workspace.workspaceLabel ?? workspace.workspaceAccountID
    }
}

@MainActor
final class ManagedCodexAccountService {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let loginRunner: any ManagedCodexLoginRunning
    private let identityReader: any ManagedCodexIdentityReading
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let workspaceSelector: any ManagedCodexWorkspaceSelecting
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        loginRunner: any ManagedCodexLoginRunning,
        identityReader: any ManagedCodexIdentityReading,
        workspaceResolver: any ManagedCodexWorkspaceResolving = DefaultManagedCodexWorkspaceResolver(),
        workspaceSelector: any ManagedCodexWorkspaceSelecting = CodexWorkspaceAlertSelector(),
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.loginRunner = loginRunner
        self.identityReader = identityReader
        self.workspaceResolver = workspaceResolver
        self.workspaceSelector = workspaceSelector
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(
            store: FileManagedCodexAccountStore(fileManager: fileManager),
            homeFactory: ManagedCodexHomeFactory(fileManager: fileManager),
            loginRunner: DefaultManagedCodexLoginRunner(),
            identityReader: DefaultManagedCodexIdentityReader(),
            workspaceResolver: DefaultManagedCodexWorkspaceResolver(),
            workspaceSelector: CodexWorkspaceAlertSelector(),
            fileManager: fileManager)
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        let snapshot = try self.store.loadAccounts()
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedCodexAccount
        let existingHomePathsToDelete: [String]

        do {
            let result = await self.loginRunner.run(homePath: homeURL.path, timeout: timeout)
            guard case .success = result.outcome else { throw ManagedCodexAccountServiceError.loginFailed(result) }

            let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
            guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEmail.isEmpty
            else {
                throw ManagedCodexAccountServiceError.missingEmail
            }
            let authenticatedProviderAccountID: String? = switch identity.identity {
            case let .providerAccount(id):
                ManagedCodexAccount.normalizeProviderAccountID(id)
            case .emailOnly, .unresolved:
                nil
            }
            let selectedWorkspace = try await self.selectedWorkspaceIdentity(
                email: rawEmail,
                homePath: homeURL.path,
                authenticatedProviderAccountID: authenticatedProviderAccountID)
            let providerAccountID = selectedWorkspace?.workspaceAccountID ?? authenticatedProviderAccountID
            let workspaceIdentity: CodexOpenAIWorkspaceIdentity? = if let selectedWorkspace {
                selectedWorkspace
            } else {
                await self.resolvedWorkspaceIdentity(
                    homePath: homeURL.path,
                    providerAccountID: providerAccountID)
            }

            let now = Date().timeIntervalSince1970
            let existing = self.reconciledExistingAccount(
                authenticatedEmail: rawEmail,
                providerAccountID: providerAccountID,
                existingAccountID: existingAccountID,
                snapshot: snapshot)
            let persistedMetadata = self.persistedProviderMetadata(
                authenticatedProviderAccountID: providerAccountID,
                resolvedWorkspaceIdentity: workspaceIdentity,
                existingAccount: existing)

            account = ManagedCodexAccount(
                id: existing?.id ?? UUID(),
                email: rawEmail,
                providerAccountID: persistedMetadata.providerAccountID,
                workspaceLabel: persistedMetadata.workspaceLabel,
                workspaceAccountID: persistedMetadata.workspaceAccountID,
                authFingerprint: CodexAuthFingerprint.fingerprint(
                    homePath: homeURL.path,
                    fileManager: self.fileManager),
                managedHomePath: homeURL.path,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastAuthenticatedAt: now)
            let replacedAccountIDs = self.replacedAccountIDs(
                authenticatedEmail: rawEmail,
                providerAccountID: providerAccountID,
                existingAccountID: existingAccountID,
                matchedAccountID: existing?.id,
                snapshot: snapshot)
            existingHomePathsToDelete = snapshot.accounts
                .filter { replacedAccountIDs.contains($0.id) }
                .map(\.managedHomePath)

            let updatedSnapshot = ManagedCodexAccountSet(
                version: snapshot.version,
                accounts: snapshot.accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account])
            try self.store.storeAccounts(updatedSnapshot)
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        for existingHomePathToDelete in existingHomePathsToDelete where existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        let snapshot = try self.store.loadAccounts()
        guard let account = snapshot.account(id: id) else { return }

        let homeURL = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        let canDeleteHome = (try? self.homeFactory.validateManagedHomeForDeletion(homeURL)) != nil

        let remaining = snapshot.accounts.filter { $0.id != id }
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: snapshot.version,
            accounts: remaining))

        if canDeleteHome, self.fileManager.fileExists(atPath: homeURL.path) {
            try? self.fileManager.removeItem(at: homeURL)
        }
    }

    func importAIRouterCodexAccounts(
        authDirectory: URL? = nil,
        disabledAuthDirectory: URL? = nil) async throws
        -> ManagedCodexAIRouterImportResult
    {
        let resolvedAuthDirectory = authDirectory ?? Self.defaultAIRouterAuthDirectory(
            fileManager: self.fileManager)
        let resolvedDisabledDirectory = disabledAuthDirectory ?? Self.defaultAIRouterDisabledAuthDirectory(
            authDirectory: resolvedAuthDirectory)
        let candidates = self.aiRouterCodexAuthFileURLs(
            authDirectory: resolvedAuthDirectory,
            disabledAuthDirectory: resolvedDisabledDirectory)

        let initialSnapshot = try self.store.loadAccounts()
        var accounts = initialSnapshot.accounts
        var skippedFileCount = 0
        var importedAccounts: [ManagedCodexAccount] = []
        var updatedAccounts: [ManagedCodexAccount] = []
        var preferredAccount: ManagedCodexAccount?
        var newHomePaths: [String] = []
        var replacedHomePaths: [String] = []

        do {
            for candidate in candidates {
                guard let rawData = try? Data(contentsOf: candidate),
                      let credentials = try? CodexOAuthCredentialsStore.parse(data: rawData),
                      !credentials.refreshToken.isEmpty
                else {
                    skippedFileCount += 1
                    continue
                }

                let homeURL = self.homeFactory.makeHomeURL()
                try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
                newHomePaths.append(homeURL.path)
                try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": homeURL.path])

                let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
                guard let rawEmail = Self.importedEmail(identity: identity, authFileURL: candidate) else {
                    skippedFileCount += 1
                    try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
                    continue
                }

                let authenticatedProviderAccountID = Self.importedProviderAccountID(
                    identity: identity,
                    credentials: credentials)
                let currentSnapshot = ManagedCodexAccountSet(
                    version: initialSnapshot.version,
                    accounts: accounts)
                let workspaceIdentity = await self.resolvedWorkspaceIdentity(
                    homePath: homeURL.path,
                    providerAccountID: authenticatedProviderAccountID)
                let existing = self.reconciledExistingAccount(
                    authenticatedEmail: rawEmail,
                    providerAccountID: authenticatedProviderAccountID,
                    existingAccountID: nil,
                    snapshot: currentSnapshot)
                let persistedMetadata = self.persistedProviderMetadata(
                    authenticatedProviderAccountID: authenticatedProviderAccountID,
                    resolvedWorkspaceIdentity: workspaceIdentity,
                    existingAccount: existing)

                let now = Date().timeIntervalSince1970
                let account = ManagedCodexAccount(
                    id: existing?.id ?? UUID(),
                    email: rawEmail,
                    providerAccountID: persistedMetadata.providerAccountID,
                    workspaceLabel: persistedMetadata.workspaceLabel,
                    workspaceAccountID: persistedMetadata.workspaceAccountID,
                    authFingerprint: CodexAuthFingerprint.fingerprint(data: rawData),
                    externalAuthFilePath: candidate.standardizedFileURL.path,
                    managedHomePath: homeURL.path,
                    createdAt: existing?.createdAt ?? now,
                    updatedAt: now,
                    lastAuthenticatedAt: now)
                if candidate.deletingLastPathComponent().standardizedFileURL ==
                    resolvedAuthDirectory.standardizedFileURL
                {
                    preferredAccount = account
                }
                let replacedAccountIDs = self.replacedAccountIDs(
                    authenticatedEmail: rawEmail,
                    providerAccountID: authenticatedProviderAccountID,
                    existingAccountID: nil,
                    matchedAccountID: existing?.id,
                    snapshot: currentSnapshot)

                replacedHomePaths.append(contentsOf: accounts
                    .filter { replacedAccountIDs.contains($0.id) }
                    .map(\.managedHomePath))
                let replacesAccountImportedInThisRun = importedAccounts.contains { replacedAccountIDs.contains($0.id) }
                importedAccounts.removeAll { replacedAccountIDs.contains($0.id) }
                updatedAccounts.removeAll { replacedAccountIDs.contains($0.id) }
                accounts = accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account]
                if existing == nil || replacesAccountImportedInThisRun {
                    importedAccounts.append(account)
                } else {
                    updatedAccounts.append(account)
                }
            }

            if !importedAccounts.isEmpty || !updatedAccounts.isEmpty {
                try self.store.storeAccounts(ManagedCodexAccountSet(
                    version: initialSnapshot.version,
                    accounts: accounts))
            }
        } catch {
            for path in newHomePaths {
                try? self.removeManagedHomeIfSafe(atPath: path)
            }
            throw error
        }

        let importedHomePaths = Set((importedAccounts + updatedAccounts).map(\.managedHomePath))
        for path in replacedHomePaths where !importedHomePaths.contains(path) {
            try? self.removeManagedHomeIfSafe(atPath: path)
        }

        return ManagedCodexAIRouterImportResult(
            scannedFileCount: candidates.count,
            skippedFileCount: skippedFileCount,
            importedAccounts: importedAccounts,
            updatedAccounts: updatedAccounts,
            preferredAccount: preferredAccount)
    }

    private func removeManagedHomeIfSafe(atPath path: String) throws {
        let homeURL = URL(fileURLWithPath: path, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
    }

    private func selectedWorkspaceIdentity(
        email: String,
        homePath: String,
        authenticatedProviderAccountID: String?) async throws -> CodexOpenAIWorkspaceIdentity?
    {
        let workspaces = await self.workspaceResolver.availableWorkspaceIdentities(homePath: homePath)
        guard workspaces.count > 1 else {
            return workspaces.first { $0.workspaceAccountID == authenticatedProviderAccountID }
        }
        guard let selected = await self.workspaceSelector.selectWorkspace(
            email: email,
            currentWorkspaceID: authenticatedProviderAccountID,
            workspaces: workspaces)
        else {
            throw ManagedCodexAccountServiceError.workspaceSelectionCancelled
        }
        try self.persistSelectedWorkspaceID(selected.workspaceAccountID, homePath: homePath)
        return selected
    }

    private func resolvedWorkspaceIdentity(
        homePath: String,
        providerAccountID: String?) async -> CodexOpenAIWorkspaceIdentity?
    {
        guard let providerAccountID else { return nil }
        return await self.workspaceResolver.resolveWorkspaceIdentity(
            homePath: homePath,
            providerAccountID: providerAccountID)
    }

    private func persistSelectedWorkspaceID(_ workspaceID: String, homePath: String) throws {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        let credentials = try CodexOAuthCredentialsStore.load(env: env)
        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                idToken: credentials.idToken,
                accountId: workspaceID,
                lastRefresh: credentials.lastRefresh),
            env: env)
    }

    private func reconciledExistingAccount(
        authenticatedEmail: String,
        providerAccountID: String?,
        existingAccountID: UUID?,
        snapshot: ManagedCodexAccountSet)
        -> ManagedCodexAccount?
    {
        if let providerAccountID,
           let existingByProviderAccountID = snapshot.account(
               email: authenticatedEmail,
               providerAccountID: providerAccountID)
        {
            return existingByProviderAccountID
        }
        if let existingAccountID,
           let existingByID = snapshot.account(id: existingAccountID),
           existingByID.email == Self.normalizeEmail(authenticatedEmail),
           providerAccountID == nil || existingByID.providerAccountID == nil
        {
            return existingByID
        }
        guard providerAccountID == nil else {
            return nil
        }
        // Email-only reconciliation is a legacy/hardening fallback. Once an auth payload carries a
        // provider account ID, matching must stay on that ID so same-email workspaces can coexist.
        return snapshot.account(email: authenticatedEmail)
    }

    private func replacedAccountIDs(
        authenticatedEmail: String,
        providerAccountID: String?,
        existingAccountID: UUID?,
        matchedAccountID: UUID?,
        snapshot: ManagedCodexAccountSet) -> Set<UUID>
    {
        var ids: Set<UUID> = []
        let normalizedEmail = Self.normalizeEmail(authenticatedEmail)
        if let matchedAccountID {
            ids.insert(matchedAccountID)
        }

        if providerAccountID != nil {
            let legacySameEmailIDs = snapshot.accounts
                .filter {
                    $0.id != matchedAccountID &&
                        $0.providerAccountID == nil &&
                        $0.email == normalizedEmail
                }
                .map(\.id)
            ids.formUnion(legacySameEmailIDs)
        }

        guard let existingAccountID,
              existingAccountID != matchedAccountID,
              let existingByID = snapshot.account(id: existingAccountID)
        else {
            return ids
        }

        if existingByID.providerAccountID == nil,
           existingByID.email == normalizedEmail,
           providerAccountID != nil
        {
            ids.insert(existingAccountID)
        }
        return ids
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func defaultAIRouterAuthDirectory(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("ai-router", isDirectory: true)
            .appendingPathComponent("auths", isDirectory: true)
    }

    private static func defaultAIRouterDisabledAuthDirectory(authDirectory: URL) -> URL {
        URL(fileURLWithPath: authDirectory.path + ".disabled", isDirectory: true)
    }

    private func aiRouterCodexAuthFileURLs(authDirectory: URL, disabledAuthDirectory: URL) -> [URL] {
        var seen: Set<String> = []
        return [authDirectory, disabledAuthDirectory]
            .flatMap { self.codexAuthFiles(in: $0) }
            .filter { url in
                let path = url.standardizedFileURL.path
                return seen.insert(path).inserted
            }
    }

    private func codexAuthFiles(in directory: URL) -> [URL] {
        guard let children = try? self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        return children.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("codex-"), url.pathExtension == "json" else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile ?? true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func importedEmail(identity: CodexAuthBackedAccount, authFileURL: URL) -> String? {
        if let email = self.normalizeImportedEmail(identity.email) {
            return email
        }
        return self.inferredAIRouterEmail(from: authFileURL)
    }

    private static func normalizeImportedEmail(_ email: String?) -> String? {
        guard let normalized = CodexIdentityResolver.normalizeEmail(email) else { return nil }
        return normalized
    }

    private static func inferredAIRouterEmail(from authFileURL: URL) -> String? {
        var stem = authFileURL.deletingPathExtension().lastPathComponent
        if stem.hasPrefix("codex-") {
            stem.removeFirst("codex-".count)
        }
        if let lastDash = stem.lastIndex(of: "-"), stem[..<lastDash].contains(where: { $0 == "@" }) {
            stem = String(stem[..<lastDash])
        }
        guard stem.contains("@") else { return nil }
        return self.normalizeImportedEmail(stem)
    }

    private static func importedProviderAccountID(
        identity: CodexAuthBackedAccount,
        credentials: CodexOAuthCredentials) -> String?
    {
        switch identity.identity {
        case let .providerAccount(id):
            ManagedCodexAccount.normalizeProviderAccountID(id)
        case .emailOnly, .unresolved:
            ManagedCodexAccount.normalizeProviderAccountID(credentials.accountId)
        }
    }

    private func persistedProviderMetadata(
        authenticatedProviderAccountID: String?,
        resolvedWorkspaceIdentity: CodexOpenAIWorkspaceIdentity?,
        existingAccount: ManagedCodexAccount?) -> (
        providerAccountID: String?,
        workspaceLabel: String?,
        workspaceAccountID: String?)
    {
        if let authenticatedProviderAccountID {
            let isExistingProviderMatch = existingAccount?.providerAccountID == authenticatedProviderAccountID
            return (
                providerAccountID: authenticatedProviderAccountID,
                workspaceLabel: resolvedWorkspaceIdentity?.workspaceLabel
                    ?? (isExistingProviderMatch ? existingAccount?.workspaceLabel : nil),
                workspaceAccountID: resolvedWorkspaceIdentity?.workspaceAccountID ??
                    (isExistingProviderMatch ? existingAccount?.workspaceAccountID : nil) ??
                    authenticatedProviderAccountID)
        }

        guard let existingAccount, existingAccount.providerAccountID != nil else {
            return (providerAccountID: nil, workspaceLabel: nil, workspaceAccountID: nil)
        }

        return (
            providerAccountID: existingAccount.providerAccountID,
            workspaceLabel: existingAccount.workspaceLabel,
            workspaceAccountID: existingAccount.workspaceAccountID ?? existingAccount.providerAccountID)
    }
}
