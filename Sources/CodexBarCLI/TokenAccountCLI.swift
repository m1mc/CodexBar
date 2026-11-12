import CodexBarCore
import Commander
import Foundation

struct TokenAccountCLISelection {
    let label: String?
    let index: Int?
    let allAccounts: Bool

    var usesOverride: Bool {
        self.label != nil || self.index != nil || self.allAccounts
    }

    func providerSelectionError(_ providers: [UsageProvider]) -> String? {
        guard self.usesOverride else { return nil }
        guard providers.count == 1 else { return "account selection requires a single provider." }
        let provider = providers[0]
        // Provider-specific by design: Codex exposes reconciled live/managed accounts beyond token accounts.
        let includesReconciledAccounts = provider == .codex
        guard includesReconciledAccounts || TokenAccountSupportCatalog.support(for: provider) != nil else {
            return "\(provider.rawValue) does not support token accounts."
        }
        return nil
    }
}

enum TokenAccountCLIResolutionScope {
    case configuredAccounts
    case ambientAccount
}

enum TokenAccountCLIError: LocalizedError, Equatable {
    case noAccounts(UsageProvider)
    case accountNotFound(UsageProvider, String)
    case indexOutOfRange(UsageProvider, Int, Int)
    case ambiguousAccount(UsageProvider, String, [String])
    case antigravityCLIAccountSelectionUnsupported

    var errorDescription: String? {
        switch self {
        case let .noAccounts(provider):
            return "No token accounts configured for \(provider.rawValue)."
        case let .accountNotFound(provider, label):
            return "No token account labeled '\(label)' for \(provider.rawValue)."
        case let .indexOutOfRange(provider, index, count):
            return "Token account index \(index) out of range for \(provider.rawValue) (1-\(count))."
        case let .ambiguousAccount(provider, label, candidates):
            var msg = "Multiple accounts match '\(label)' for \(provider.rawValue)."
            if !candidates.isEmpty {
                msg += " Please specify by unique ID or --account-index:\n" + candidates.map { "  - \($0)" }.joined(separator: "\n")
            }
            return msg
        case .antigravityCLIAccountSelectionUnsupported:
            return "Antigravity CLI uses its local login and cannot select saved Google accounts. " +
                "Use --source auto or --source oauth with account selection."
        }
    }
}

struct TokenAccountCLIContext {
    let selection: TokenAccountCLISelection
    let config: CodexBarConfig
    let accountsByProvider: [UsageProvider: ProviderTokenAccountData]
    @ProcessEnvironment private(set) var baseEnvironment: [String: String]
    private let managedCodexAccountStoreURL: URL?
    private let tokenWriteback: TokenAccountCLIWriteback

    init(
        selection: TokenAccountCLISelection,
        config: CodexBarConfig,
        verbose _: Bool,
        resolutionScope: TokenAccountCLIResolutionScope = .configuredAccounts,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        managedCodexAccountStoreURL: URL? = nil,
        configStore: CodexBarConfigStore = CodexBarConfigStore()) throws
    {
        self.selection = selection
        self.config = config
        self.baseEnvironment = baseEnvironment
        self.managedCodexAccountStoreURL = managedCodexAccountStoreURL
        self.tokenWriteback = TokenAccountCLIWriteback(store: configStore)
        self.accountsByProvider = switch resolutionScope {
        case .configuredAccounts:
            Dictionary(uniqueKeysWithValues: config.providers.compactMap { provider in
                guard let firstPartyProvider = provider.id.firstPartyProvider,
                      let accounts = provider.tokenAccounts
                else { return nil }
                return (firstPartyProvider, accounts)
            })
        case .ambientAccount:
            [:]
        }
    }

    func resolvedAccounts(
        for provider: UsageProvider, sourceMode: ProviderSourceMode? = nil) throws -> [ProviderTokenAccount]
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider) else { return [] }
        let effectiveSourceMode = sourceMode ?? self.preferredSourceMode(for: provider)
        // Provider-specific by design: agy owns its login; saved Google accounts cannot select its local identity.
        if provider == .antigravity, effectiveSourceMode == .cli, self.selection.usesOverride {
            throw TokenAccountCLIError.antigravityCLIAccountSelectionUnsupported
        }
        if !self.selection.usesOverride,
           support.passiveSourceModes.contains(effectiveSourceMode)
        {
            return []
        }
        guard let data = self.accountsByProvider[provider], !data.accounts.isEmpty else {
            // --all-accounts with no saved accounts falls back to the ambient local login.
            if self.selection.usesOverride, !self.selection.allAccounts {
                throw TokenAccountCLIError.noAccounts(provider)
            }
            return []
        }

        if self.selection.allAccounts {
            return data.accounts
        }

        if let label = self.selection.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let normalized = label.lowercased()
            if let directIDMatch = data.accounts.first(where: { $0.id.uuidString.lowercased() == normalized }) {
                return [directIDMatch]
            }
            let matches = data.accounts.filter { $0.label.lowercased() == normalized }
            if matches.count == 1 {
                return [matches[0]]
            } else if matches.count > 1 {
                let candidates = matches.map { account -> String in
                    let idx = (data.accounts.firstIndex(where: { $0.id == account.id }) ?? 0) + 1
                    return "\(account.label) (ID: \(account.id.uuidString)) -> use '--account \(account.id.uuidString)' or '--account-index \(idx)'"
                }
                throw TokenAccountCLIError.ambiguousAccount(provider, label, candidates)
            }
            throw TokenAccountCLIError.accountNotFound(provider, label)
        }

        if let index = self.selection.index {
            guard index >= 0, index < data.accounts.count else {
                throw TokenAccountCLIError.indexOutOfRange(provider, index + 1, data.accounts.count)
            }
            return [data.accounts[index]]
        }

        // Align with ambient local agy login if present in registered accounts
        if provider == .antigravity,
           let ambientEmail = Self.ambientAntigravityEmail(),
           let match = data.accounts.first(where: {
               $0.label.lowercased() == ambientEmail
                   || $0.externalIdentifier?.lowercased() == ambientEmail
           })
        {
            return [match]
        }

        let clamped = data.clampedActiveIndex()
        return [data.accounts[clamped]]
    }

    static func ambientAntigravityEmail() -> String? {
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        guard let data = try? Data(contentsOf: tokenURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let idEmail = json["id_token_email"] as? String, !idEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return idEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if let email = json["email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return nil
    }

    func settingsSnapshot(
        for provider: UsageProvider,
        account: ProviderTokenAccount?,
        codexActiveSourceOverride: CodexActiveSource? = nil) -> ProviderSettingsSnapshot?
    {
        let config = self.providerConfig(for: provider)
        // Provider-specific by design: managed Codex profiles require live reconciliation state that is not config.
        if provider == .codex {
            return ProviderSettingsSnapshot.make(codex: self.makeCodexSettingsSnapshot(
                account: account,
                codexActiveSourceOverride: codexActiveSourceOverride))
        }
        guard let contribution = ProviderDescriptorRegistry.descriptor(for: provider)
            .settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: account))
        else { return nil }
        return ProviderSettingsSnapshot(contributions: [contribution])
    }

    private func makeCodexSettingsSnapshot(
        account: ProviderTokenAccount?,
        codexActiveSourceOverride: CodexActiveSource? = nil) ->
        ProviderSettingsSnapshot.CodexProviderSettings
    {
        // Provider-specific by design: Codex settings include reconciliation state and profile-home selection.
        let config = self.providerConfig(for: .codex)
        let reconciliationSnapshot = self.codexAccountReconciler(
            activeSource: codexActiveSourceOverride).loadSnapshot()
        let resolvedActiveSource = CodexActiveSourceResolver.resolve(from: reconciliationSnapshot)
        let cookieSettings = ProviderCredentialSettingsContext(config: config, account: account)
            .cookieSettings(for: .codex)
        return CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader,
            reconciliationSnapshot: reconciliationSnapshot,
            resolvedActiveSource: resolvedActiveSource))
    }

    func environment(
        base: [String: String],
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        codexActiveSourceOverride: CodexActiveSource? = nil) -> [String: String]
    {
        let providerConfig = self.providerConfig(for: provider)
        var env = ProviderEnvironmentResolver.resolve(
            base: base,
            provider: provider,
            config: providerConfig,
            selectedAccount: account)
        // Provider-specific by design: managed Codex accounts select a distinct filesystem home, not a credential.
        if provider == .codex,
           let codexHomePath = self.codexHomePath(for: codexActiveSourceOverride)
        {
            env = CodexHomeScope.scopedEnvironment(base: env, codexHome: codexHomePath)
        }
        return env
    }

    func tokenUpdater(for account: ProviderTokenAccount?) -> ProviderFetchContext.TokenAccountTokenUpdater? {
        guard let account else { return nil }
        let writeback = self.tokenWriteback
        return { provider, accountID, token in
            guard accountID == account.id else { return }
            await writeback.update(provider: provider, account: account, token: token)
        }
    }

    func manualTokenUpdater() -> ProviderFetchContext.ProviderManualTokenUpdater {
        let writeback = self.tokenWriteback
        return { provider, token in
            await writeback.updateManual(provider: provider, token: token)
        }
    }

    @discardableResult
    static func updateStoredTokenAccount(
        store: CodexBarConfigStore,
        provider: UsageProvider,
        accountID: UUID,
        expectedToken: String,
        token: String) throws -> Bool
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var didUpdate = false
        try store.updateIfAvailable { config in
            guard var providerConfig = config.providerConfig(for: provider.instanceID),
                  let data = providerConfig.tokenAccounts,
                  let index = data.accounts.firstIndex(where: { $0.id == accountID })
            else {
                return false
            }

            let existing = data.accounts[index]
            guard existing.token == expectedToken else {
                CodexBarLog.logger(LogCategories.tokenAccounts).warning(
                    "Skipped token account writeback: the stored credential changed during the fetch",
                    metadata: ["provider": provider.rawValue])
                return false
            }
            var accounts = data.accounts
            accounts[index] = ProviderTokenAccount(
                id: existing.id,
                label: existing.label,
                token: trimmed,
                addedAt: existing.addedAt,
                lastUsed: existing.lastUsed,
                externalIdentifier: existing.externalIdentifier,
                usageScope: existing.usageScope,
                organizationID: existing.organizationID,
                workspaceID: existing.workspaceID,
                claudeConfigDirectory: existing.claudeConfigDirectory,
                seatCreditEntitlement: existing.seatCreditEntitlement,
                modelRateLimits: existing.modelRateLimits)
            providerConfig.tokenAccounts = ProviderTokenAccountData(
                version: data.version,
                accounts: accounts,
                activeIndex: data.clampedActiveIndex())
            config.setProviderConfig(providerConfig)
            didUpdate = true
            return true
        }
        return didUpdate
    }

    func fetcher(base: UsageFetcher, provider: UsageProvider, env: [String: String]) -> UsageFetcher {
        // Provider-specific by design: UsageFetcher owns Codex filesystem scopes and must be rebuilt with CODEX_HOME.
        guard provider == .codex else { return base }
        return UsageFetcher(environment: env)
    }

    func visibleCodexAccounts() -> CodexVisibleAccountProjection {
        // Provider-specific by design: only Codex exposes reconciled live, managed, and profile-home accounts.
        self.codexAccountReconciler().loadVisibleAccounts()
    }

    func resolvedCodexAccounts() throws -> [CodexVisibleAccount] {
        let projection = self.visibleCodexAccounts()
        let accounts = projection.visibleAccounts
        guard !accounts.isEmpty else {
            if self.selection.usesOverride, !self.selection.allAccounts {
                throw TokenAccountCLIError.noAccounts(.codex)
            }
            return []
        }

        if self.selection.allAccounts {
            return accounts
        }

        if let label = self.selection.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let normalized = label.lowercased()

            // 1. Direct unique ID match (exact match on id or storedAccountID.uuidString).
            // Unique ID takes precedence and is not shadowed by aliases or workspace labels.
            if let directIDMatch = accounts.first(where: {
                $0.id.lowercased() == normalized
                    || $0.storedAccountID?.uuidString.lowercased() == normalized
            }) {
                return [directIDMatch]
            }

            // 2. Non-ID alias matches (email, workspaceLabel, customName)
            let matches = accounts.filter {
                $0.email.lowercased() == normalized
                    || $0.workspaceLabel?.lowercased() == normalized
                    || $0.customName?.lowercased() == normalized
            }

            if matches.count == 1 {
                return [matches[0]]
            } else if matches.count > 1 {
                let candidates = matches.map { account -> String in
                    let idx = (accounts.firstIndex(of: account) ?? 0) + 1
                    var desc = account.email
                    if let ws = account.workspaceLabel, !ws.isEmpty {
                        desc += " (workspace: \(ws))"
                    }
                    if let custom = account.customName, !custom.isEmpty {
                        desc += " [\(custom)]"
                    }
                    return "\(desc) -> use '--account \(account.id)' or '--account-index \(idx)'"
                }
                throw TokenAccountCLIError.ambiguousAccount(.codex, label, candidates)
            }

            throw TokenAccountCLIError.accountNotFound(.codex, label)
        }

        if let index = self.selection.index {
            guard index >= 0, index < accounts.count else {
                throw TokenAccountCLIError.indexOutOfRange(.codex, index + 1, accounts.count)
            }
            return [accounts[index]]
        }

        if let active = accounts.first(where: { $0.isActive }) {
            return [active]
        }
        return [accounts[0]]
    }

    func applyCodexVisibleAccountLabel(_ snapshot: UsageSnapshot, account: CodexVisibleAccount) -> UsageSnapshot {
        // Provider-specific by design: reconciled Codex accounts carry workspace labels outside token-account config.
        let existing = snapshot.identity(for: .codex)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: account.email,
            accountOrganization: account.workspaceLabel ?? existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }

    func effectiveSourceMode(
        base: ProviderSourceMode,
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> ProviderSourceMode
    {
        let config = self.providerConfig(for: provider)
        return ProviderDescriptorRegistry.descriptor(for: provider).credentials?
            .selectedAccountSourceMode(base: base, account: account, config: config) ?? base
    }

    func preferredSourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        let config = self.providerConfig(for: provider)
        return config?.source ?? .auto
    }

    private func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.config.providerConfig(for: provider.instanceID)
    }

    private func codexAccountReconciler(activeSource: CodexActiveSource? = nil) -> DefaultCodexAccountReconciler {
        // Provider-specific by design: this reconciles Codex profile homes with its managed-account store.
        let storeLoader: @Sendable () throws -> ManagedCodexAccountSet = if let managedCodexAccountStoreURL {
            {
                try FileManagedCodexAccountStore(fileURL: managedCodexAccountStoreURL).loadAccounts()
            }
        } else {
            {
                try FileManagedCodexAccountStore().loadAccounts()
            }
        }
        return DefaultCodexAccountReconciler(
            storeLoader: storeLoader,
            activeSource: activeSource ?? self.providerConfig(for: .codex)?.codexActiveSource ?? .liveSystem,
            baseEnvironment: self.baseEnvironment,
            profileHomePaths: self.providerConfig(for: .codex)?.codexProfileHomePaths ?? [],
            managedEnvironmentBuilder: { environment, account in
                CodexHomeScope.scopedEnvironment(base: environment, codexHome: account.managedHomePath)
            })
    }

    private func codexHomePath(for activeSourceOverride: CodexActiveSource?) -> String? {
        // Provider-specific by design: Codex profile selection changes the local data root for the whole fetcher.
        let activeSource: CodexActiveSource = if let activeSourceOverride {
            activeSourceOverride
        } else {
            CodexActiveSourceResolver.resolve(from: self.codexAccountReconciler().loadSnapshot())
                .resolvedSource
        }

        switch activeSource {
        case .liveSystem:
            return nil
        case let .managedAccount(id):
            let accounts: ManagedCodexAccountSet? = if let managedCodexAccountStoreURL {
                try? FileManagedCodexAccountStore(fileURL: managedCodexAccountStoreURL).loadAccounts()
            } else {
                try? FileManagedCodexAccountStore().loadAccounts()
            }
            return accounts?.account(id: id)?.managedHomePath
        case let .profileHome(path):
            guard let normalizedPath = CodexHomeScope.normalizedHomePath(path) else { return nil }
            let configuredPaths = self.providerConfig(for: .codex)?.codexProfileHomePaths ?? []
            return configuredPaths.contains {
                CodexHomeScope.normalizedHomePath($0) == normalizedPath
            } ? normalizedPath : nil
        }
    }
}

/// One command shares a writer across providers, while external config edits still win.
private actor TokenAccountCLIWriteback {
    private let store: CodexBarConfigStore
    private var expectedTokens: [UsageProvider: [UUID: String]] = [:]

    init(store: CodexBarConfigStore) {
        self.store = store
    }

    func updateManual(provider: UsageProvider, token: String) {
        try? ProviderDescriptorRegistry.descriptor(for: provider).credentials?.persistManualToken(token)
    }

    func update(provider: UsageProvider, account: ProviderTokenAccount, token: String) {
        if (try? TokenAccountCLIContext.updateStoredTokenAccount(
            store: self.store,
            provider: provider,
            accountID: account.id,
            expectedToken: self.expectedTokens[provider]?[account.id] ?? account.token,
            token: token)) == true
        {
            self.expectedTokens[provider, default: [:]][account.id] = token
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
