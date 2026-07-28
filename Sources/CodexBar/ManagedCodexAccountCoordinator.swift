import CodexBarCore
import Foundation
import Observation

enum ManagedCodexAccountCoordinatorError: Error, Equatable {
    case authenticationInProgress
}

@MainActor
@Observable
final class ManagedCodexAccountCoordinator {
    let service: ManagedCodexAccountService
    private(set) var isAuthenticatingManagedAccount: Bool = false
    private(set) var authenticatingManagedAccountID: UUID?
    private(set) var isRemovingManagedAccount: Bool = false
    private(set) var removingManagedAccountID: UUID?
    private(set) var isImportingAIRouterAccounts: Bool = false
    var onManagedAccountsDidChange: (@MainActor () -> Void)?

    var hasConflictingManagedAccountOperationInFlight: Bool {
        self.isAuthenticatingManagedAccount || self.isRemovingManagedAccount || self.isImportingAIRouterAccounts
    }

    init(service: ManagedCodexAccountService = ManagedCodexAccountService()) {
        self.service = service
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        guard self.isAuthenticatingManagedAccount == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isAuthenticatingManagedAccount = true
        self.authenticatingManagedAccountID = existingAccountID
        defer {
            self.isAuthenticatingManagedAccount = false
            self.authenticatingManagedAccountID = nil
        }

        let account = try await self.service.authenticateManagedAccount(
            existingAccountID: existingAccountID,
            timeout: timeout)
        self.onManagedAccountsDidChange?()
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        self.isRemovingManagedAccount = true
        self.removingManagedAccountID = id
        defer {
            self.isRemovingManagedAccount = false
            self.removingManagedAccountID = nil
        }

        try await self.service.removeManagedAccount(id: id)
        self.onManagedAccountsDidChange?()
    }

    func importAIRouterCodexAccounts() async throws -> ManagedCodexAIRouterImportResult {
        guard self.hasConflictingManagedAccountOperationInFlight == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isImportingAIRouterAccounts = true
        defer {
            self.isImportingAIRouterAccounts = false
        }

        let result = try await self.service.importAIRouterCodexAccounts()
        if result.affectedCount > 0 {
            self.onManagedAccountsDidChange?()
        }
        return result
    }
}
