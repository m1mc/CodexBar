import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct TokenAccountCLISelectionTests {
    @Test
    func `Claude credential refresh preserves its local cost directory`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Personal",
            token: "fixture-old",
            addedAt: 1,
            lastUsed: nil,
            claudeConfigDirectory: "/fixtures/claude-personal")
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.claude.instanceID,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        #expect(try TokenAccountCLIContext.updateStoredTokenAccount(
            store: store,
            provider: .claude,
            accountID: account.id,
            expectedToken: "fixture-old",
            token: "fixture-new"))
        let saved = try #require(try store.load()?.providerConfig(for: .claude)?.tokenAccounts?.accounts.first)
        #expect(saved.token == "fixture-new")
        #expect(saved.claudeConfigDirectory == account.claudeConfigDirectory)
    }

    @Test
    func `parallel providers retain both refreshed account credentials`() async throws {
        let providers: [UsageProvider] = [.antigravity, .stepfun]
        let accounts = providers.map { _ in Self.account(token: "original-token") }
        let config = CodexBarConfig(providers: zip(providers, accounts).map { provider, account in
            ProviderConfig(
                id: provider.instanceID,
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))
        })
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        // Keep the first atomic write open long enough for the other provider to request its writeback.
        let beforePublish: @Sendable (URL) throws -> Void = { _ in Thread.sleep(forTimeInterval: 0.1) }
        await withTaskGroup(of: Void.self) { group in
            for (provider, account) in zip(providers, accounts) {
                group.addTask {
                    await CredentialFileWriter.$beforePublishForTesting.withValue(beforePublish) {
                        await context.tokenUpdater(for: account)?(provider, account.id, "refreshed-token")
                    }
                }
            }
        }
        let saved = try #require(try store.load())
        for provider in providers {
            #expect(saved.providerConfig(for: provider.instanceID)?.tokenAccounts?.accounts.first?.token
                == "refreshed-token")
        }
    }

    @Test
    func `usage and cards share provider selection constraints`() {
        let all = TokenAccountCLISelection(label: nil, index: nil, allAccounts: true)
        #expect(all.providerSelectionError([.codex]) == nil)
        #expect(all.providerSelectionError([.claude]) == nil)
        #expect(all.providerSelectionError([.codex, .claude]) == "account selection requires a single provider.")
        #expect(all.providerSelectionError([]) == "account selection requires a single provider.")
        #expect(all.providerSelectionError([.jetbrains]) == "jetbrains does not support token accounts.")
        let labelSelection = TokenAccountCLISelection(label: "Primary", index: nil, allAccounts: false)
        #expect(labelSelection.providerSelectionError([.codex]) == nil)
        let indexSelection = TokenAccountCLISelection(label: nil, index: 0, allAccounts: false)
        #expect(indexSelection.providerSelectionError([.codex]) == nil)
        let automatic = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        #expect(automatic.providerSelectionError([.jetbrains, .claude]) == nil)
    }

    @Test
    func `antigravity CLI leaves saved OAuth accounts passive`() throws {
        let context = try Self.context(provider: .antigravity, source: .auto)
        #expect(try context.resolvedAccounts(for: .antigravity, sourceMode: .cli).isEmpty)
        let configuredCLI = try Self.context(provider: .antigravity, source: .cli)
        #expect(try configuredCLI.resolvedAccounts(for: .antigravity).isEmpty)
    }

    @Test
    func `antigravity explicit CLI rejects every saved account override`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .antigravity, source: .auto, selection: selection)
            Self.expectCLIAccountConflict {
                try context.resolvedAccounts(for: .antigravity, sourceMode: .cli)
            }
        }
    }

    @Test
    func `antigravity configured CLI rejects every saved account override`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .antigravity, source: .cli, selection: selection)
            Self.expectCLIAccountConflict {
                try context.resolvedAccounts(for: .antigravity)
            }
        }
    }

    @Test
    func `antigravity auto and OAuth retain saved account selection`() throws {
        let selections = Self.accountOverrides + [TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)]
        for source in [ProviderSourceMode.auto, .oauth] {
            for selection in selections {
                let context = try Self.context(provider: .antigravity, source: .cli, selection: selection)
                let accounts = try context.resolvedAccounts(for: .antigravity, sourceMode: source)
                #expect(accounts.map(\.label) == ["Primary"])
                let configured = try Self.context(provider: .antigravity, source: source, selection: selection)
                #expect(try configured.resolvedAccounts(for: .antigravity).map(\.label) == ["Primary"])
            }
        }
    }

    @Test
    func `antigravity defaults to resolving active account when no filter is provided`() throws {
        let account1 = ProviderTokenAccount(id: UUID(), label: "First", token: "tok1", addedAt: 0, lastUsed: nil)
        let account2 = ProviderTokenAccount(id: UUID(), label: "Second", token: "tok2", addedAt: 0, lastUsed: nil)
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.antigravity.instanceID,
            source: .auto,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account1, account2], activeIndex: 0))])
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        let resolved = try context.resolvedAccounts(for: .antigravity)
        #expect(resolved.map(\.label) == ["First"])
        let allContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        let allResolved = try allContext.resolvedAccounts(for: .antigravity)
        #expect(allResolved.map(\.label) == ["First", "Second"])
    }

    @Test
    func `other providers retain saved account overrides with CLI source`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .claude, source: .cli, selection: selection)
            #expect(try context.resolvedAccounts(for: .claude).map(\.label) == ["Primary"])
        }
    }

    @Test
    func `all accounts falls back to ambient login when no token accounts are saved`() throws {
        let config = CodexBarConfig(providers: [ProviderConfig(id: UsageProvider.claude.instanceID)])
        let all = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        #expect(try all.resolvedAccounts(for: .claude).isEmpty)

        for selection in [
            TokenAccountCLISelection(label: "Primary", index: nil, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: 0, allAccounts: false),
        ] {
            let context = try TokenAccountCLIContext(
                selection: selection, config: config, verbose: false, baseEnvironment: [:])
            #expect(throws: TokenAccountCLIError.noAccounts(.claude)) {
                try context.resolvedAccounts(for: .claude)
            }
        }
    }

    @Test
    func `cli token updater writes refreshed credential when stored token is unchanged`() async throws {
        let account = Self.account(token: "original-token")
        let config = Self.config(with: account)
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        let updater = try #require(context.tokenUpdater(for: account))

        await updater(.antigravity, account.id, "refreshed-token")

        let stored = try Self.storedToken(store: store, accountID: account.id)
        #expect(stored == "refreshed-token")
    }

    @Test
    func `cli token updater drops writeback when stored credential changed mid run`() async throws {
        let account = Self.account(token: "original-token")
        let config = Self.config(with: account)
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        let updater = try #require(context.tokenUpdater(for: account))

        // Another process reauthorized the account while the fetch was in flight.
        let reassigned = Self.account(id: account.id, token: "reauthorized-token")
        try store.save(Self.config(with: reassigned))

        await updater(.antigravity, account.id, "stale-refresh")

        let stored = try Self.storedToken(store: store, accountID: account.id)
        #expect(stored == "reauthorized-token")
    }

    @Test
    func `cli token updater accepts successive owned writes but rejects external reauthorization`() async throws {
        let account = Self.account(token: "original-token")
        let config = Self.config(with: account)
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        let updater = try #require(context.tokenUpdater(for: account))

        // OAuth first refreshes the grant, then persists the discovered project on the same fetch.
        await updater(.antigravity, account.id, "refreshed-token")
        await updater(.antigravity, account.id, "refreshed-token-with-project")
        #expect(try Self.storedToken(store: store, accountID: account.id) == "refreshed-token-with-project")

        try store.save(Self.config(with: Self.account(id: account.id, token: "reauthorized-token")))
        await updater(.antigravity, account.id, "late-owned-update")
        #expect(try Self.storedToken(store: store, accountID: account.id) == "reauthorized-token")
    }

    @Test
    func `cli refresh cannot publish during another config writer transaction`() throws {
        let account = Self.account(token: "original-token")
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(Self.config(with: account))
        let reauthorized = Self.account(id: account.id, token: "reauthorized-token")
        // Pause the other writer at its final rename, after it has staged the new authorization.
        let beforePublish: @Sendable (URL) throws -> Void = { _ in
            try CredentialFileWriter.$beforePublishForTesting.withValue(nil) {
                try TokenAccountCLIContext.updateStoredTokenAccount(
                    store: store,
                    provider: .antigravity,
                    accountID: account.id,
                    expectedToken: account.token,
                    token: "stale-refresh")
                #expect(try Self.storedToken(store: store, accountID: account.id) == "original-token")
            }
        }
        try CredentialFileWriter.$beforePublishForTesting.withValue(beforePublish) {
            try store.save(Self.config(with: reauthorized))
        }
        #expect(try Self.storedToken(store: store, accountID: account.id) == "reauthorized-token")
    }

    @Test
    func `Command Code API mode keeps sessions passive unless a CLI account is explicitly selected`() throws {
        let passive = try Self.context(provider: .commandcode, source: .api)
        #expect(try passive.resolvedAccounts(for: .commandcode).isEmpty)
        #expect(passive.effectiveSourceMode(base: .api, provider: .commandcode, account: nil) == .api)
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .commandcode, source: .api, selection: selection)
            let account = try #require(try context.resolvedAccounts(for: .commandcode).first)
            #expect(context.effectiveSourceMode(base: .api, provider: .commandcode, account: account) == .web)
        }
    }

    private static var accountOverrides: [TokenAccountCLISelection] {
        [
            TokenAccountCLISelection(label: "Primary", index: nil, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: 0, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
        ]
    }

    private static func context(
        provider: UsageProvider,
        source: ProviderSourceMode,
        selection: TokenAccountCLISelection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false))
        throws -> TokenAccountCLIContext
    {
        let account = ProviderTokenAccount(
            id: UUID(), label: "Primary", token: "fixture-token", addedAt: 0, lastUsed: nil)
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: provider.instanceID,
            source: source,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        return try TokenAccountCLIContext(
            selection: selection, config: config, verbose: false, baseEnvironment: [:])
    }

    @Test
    func `codex selection resolves visible accounts by email, label, index and allAccounts`() throws {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let storeURL = storeDir.appendingPathComponent("managed-codex-accounts.json")
        let account1 = ManagedCodexAccount(
            id: UUID(),
            email: "alice@example.com",
            workspaceLabel: "Personal",
            managedHomePath: storeDir.appendingPathComponent("home1").path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: 0)
        let account2 = ManagedCodexAccount(
            id: UUID(),
            email: "bob@example.com",
            workspaceLabel: "Work",
            managedHomePath: storeDir.appendingPathComponent("home2").path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: 0)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: [account1, account2]))

        let config = CodexBarConfig(providers: [ProviderConfig(id: UsageProvider.codex.instanceID)])

        // 1. Default without selection: resolves active/first account
        let defaultCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        let defaultResolved = try defaultCtx.resolvedCodexAccounts()
        #expect(defaultResolved.count == 1)
        #expect(defaultResolved.first?.email == "alice@example.com")

        // 2. allAccounts: resolves both accounts
        let allCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        let allResolved = try allCtx.resolvedCodexAccounts()
        #expect(allResolved.map(\.email) == ["alice@example.com", "bob@example.com"])

        // 3. Selection by email: resolves bob
        let bobCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: "bob@example.com", index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        let bobResolved = try bobCtx.resolvedCodexAccounts()
        #expect(bobResolved.map(\.email) == ["bob@example.com"])

        // 4. Selection by workspace label: resolves Work -> bob
        let workCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: "Work", index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        let workResolved = try workCtx.resolvedCodexAccounts()
        #expect(workResolved.map(\.email) == ["bob@example.com"])

        // 5. Selection by index (0-based parsed index -> 1 is bob)
        let indexCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: 1, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        let indexResolved = try indexCtx.resolvedCodexAccounts()
        #expect(indexResolved.map(\.email) == ["bob@example.com"])

        // 6. Unknown label throws accountNotFound
        let unknownCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: "unknown@example.com", index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        #expect(throws: TokenAccountCLIError.self) {
            try unknownCtx.resolvedCodexAccounts()
        }

        // 7. Out of range index throws indexOutOfRange
        let oobCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: 5, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: storeURL)
        #expect(throws: TokenAccountCLIError.self) {
            try oobCtx.resolvedCodexAccounts()
        }

        // 8. Ambiguous workspace label: two accounts with workspaceLabel "Personal"
        let p1 = ManagedCodexAccount(
            id: UUID(),
            email: "user1@example.com",
            workspaceLabel: "Personal",
            managedHomePath: storeDir.appendingPathComponent("homeP1").path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: 0)
        let p2 = ManagedCodexAccount(
            id: UUID(),
            email: "user2@example.com",
            workspaceLabel: "Personal",
            managedHomePath: storeDir.appendingPathComponent("homeP2").path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: 0)
        let ambiguousStoreURL = storeDir.appendingPathComponent("ambiguous-store.json")
        let ambiguousStore = FileManagedCodexAccountStore(fileURL: ambiguousStoreURL)
        try ambiguousStore.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: [p1, p2]))

        let personalAmbiguousCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: "Personal", index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: ambiguousStoreURL)
        #expect(throws: TokenAccountCLIError.self) {
            try personalAmbiguousCtx.resolvedCodexAccounts()
        }
        do {
            _ = try personalAmbiguousCtx.resolvedCodexAccounts()
        } catch let TokenAccountCLIError.ambiguousAccount(provider, label, candidates) {
            #expect(provider == .codex)
            #expect(label == "Personal")
            #expect(candidates.count == 2)
            #expect(candidates[0].contains("--account-index 1"))
            #expect(candidates[1].contains("--account-index 2"))
        } catch {
            Issue.record("Expected ambiguousAccount error but got \(error)")
        }

        // 9. Ambiguous email: same email across different workspaces
        let w1 = ManagedCodexAccount(
            id: UUID(),
            email: "same@example.com",
            workspaceLabel: "Personal",
            workspaceAccountID: "ws_personal",
            managedHomePath: storeDir.appendingPathComponent("homeW1").path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: 0)
        let w2 = ManagedCodexAccount(
            id: UUID(),
            email: "same@example.com",
            workspaceLabel: "Engineering",
            workspaceAccountID: "ws_eng",
            managedHomePath: storeDir.appendingPathComponent("homeW2").path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: 0)
        let sameEmailStoreURL = storeDir.appendingPathComponent("same-email-store.json")
        let sameEmailStore = FileManagedCodexAccountStore(fileURL: sameEmailStoreURL)
        try sameEmailStore.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: [w1, w2]))

        let sameEmailCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: "same@example.com", index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: sameEmailStoreURL)
        #expect(throws: TokenAccountCLIError.self) {
            try sameEmailCtx.resolvedCodexAccounts()
        }

        // 10. Unique ID is not shadowed by an alias:
        // Account 1 has id equal to p1.id.uuidString.
        // Selecting by its unique ID succeeds without ambiguity even if another account's name/label shares characters.
        let directIDCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: p1.id.uuidString, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: ambiguousStoreURL)
        let directResolved = try directIDCtx.resolvedCodexAccounts()
        #expect(directResolved.count == 1)
        #expect(directResolved.first?.email == "user1@example.com")

        // 11. Case-insensitivity on unique ID and labels
        let upperIDCtx = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: p1.id.uuidString.uppercased(), index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            managedCodexAccountStoreURL: ambiguousStoreURL)
        let upperResolved = try upperIDCtx.resolvedCodexAccounts()
        #expect(upperResolved.first?.email == "user1@example.com")
    }

    private static func account(id: UUID = UUID(), token: String) -> ProviderTokenAccount {
        ProviderTokenAccount(id: id, label: "Primary", token: token, addedAt: 0, lastUsed: nil)
    }

    private static func config(with account: ProviderTokenAccount) -> CodexBarConfig {
        CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.antigravity.instanceID,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
    }

    private static func configStore() throws -> CodexBarConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-account-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    }

    private static func writebackContext(
        config: CodexBarConfig,
        store: CodexBarConfigStore) throws -> TokenAccountCLIContext
    {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            configStore: store)
    }

    private static func storedToken(store: CodexBarConfigStore, accountID: UUID) throws -> String? {
        try store.load()?
            .providerConfig(for: UsageProvider.antigravity.instanceID)?
            .tokenAccounts?.accounts
            .first(where: { $0.id == accountID })?.token
    }

    private static func expectCLIAccountConflict(_ resolve: () throws -> [ProviderTokenAccount]) {
        do {
            _ = try resolve()
            Issue.record("Antigravity CLI must reject saved OAuth account overrides")
        } catch {
            #expect(error.localizedDescription ==
                "Antigravity CLI uses its local login and cannot select saved Google accounts. " +
                "Use --source auto or --source oauth with account selection.")
        }
    }
}
