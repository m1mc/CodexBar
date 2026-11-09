import Foundation
import Testing
@testable import CodexBarCore

@Suite("CodexStaleGatewayMigrationTests")
struct CodexStaleGatewayMigrationTests {

    @Test
    func `clean config without gateway returns clean`() async {
        let toml = """
        model = "gpt-4"
        model_provider = "openai"

        [profiles.dev]
        model = "gpt-4o"
        """
        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml)
        #expect(outcome == .clean)
        #expect(sanitized == toml)
    }

    @Test
    func `stale dead gateway with attribution is safely cleaned and resets managed provider`() async {
        let toml = """
        model = "gpt-5.3-codex"
        model_provider = "codexbar.openai-oauth"
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        base_url = "http://127.0.0.1:1456/v1"

        [profiles.work]
        openai_base_url = "https://custom.work.internal/v1"
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })

        #expect(outcome == .staleGatewayCleaned(previousURL: "http://127.0.0.1:1456/v1"))
        #expect(!sanitized.contains("openai_base_url = \"http://127.0.0.1:1456/v1\""))
        #expect(sanitized.contains("model_provider = \"openai\""))
        // Subsequent tables and profile settings are 100% preserved
        #expect(sanitized.contains("[profiles.work]"))
        #expect(sanitized.contains("openai_base_url = \"https://custom.work.internal/v1\""))
        #expect(sanitized.contains("[model_providers.\"codexbar.openai-oauth\"]"))
    }

    @Test
    func `table header with hash inside quotes is recognized and not treated as root`() async {
        let toml = """
        model = "gpt-5.3-codex"

        [profiles."work#hash"]
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        // Since openai_base_url is inside [profiles."work#hash"], there is no root-level gateway to clean
        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })
        #expect(outcome == .clean)
        #expect(sanitized == toml)
    }

    @Test
    func `case A: exact key matching preserves keys like openai_base_url_backup`() async {
        let toml = """
        model = "gpt-5.3-codex"
        model_provider = "codexbar.openai-oauth"
        openai_base_url_backup = "keep-me"
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })

        #expect(outcome == .staleGatewayCleaned(previousURL: "http://127.0.0.1:1456/v1"))
        #expect(!sanitized.contains("openai_base_url = \"http://127.0.0.1:1456/v1\""))
        #expect(sanitized.contains("openai_base_url_backup = \"keep-me\""))
        #expect(sanitized.contains("model_provider = \"openai\""))
    }

    @Test
    func `case B: multiline string in candidate file triggers fail-closed preservation`() async {
        let toml = """
        note = \"\"\"
        openai_base_url = "http://127.0.0.1:1456/v1"
        \"\"\"
        model_provider = "codexbar.openai-oauth"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })

        #expect(outcome == .preserved(reason: "multiline_strings_detected"))
        #expect(sanitized == toml)
    }

    @Test
    func `case C: comment-only marker is rejected as missing attribution`() async {
        let toml = """
        model = "custom"
        model_provider = "custom"
        openai_base_url = "http://127.0.0.1:1456/v1"

        # [model_providers."codexbar.example"]
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })

        #expect(outcome == .preserved(reason: "missing_codexbar_attribution"))
        #expect(sanitized == toml)
    }

    @Test
    func `active gateway is preserved`() async {
        let toml = """
        model = "gpt-5.3-codex"
        model_provider = "codexbar.openai-oauth"
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .alive })
        #expect(outcome == .activeGatewayPreserved(url: "http://127.0.0.1:1456/v1"))
        #expect(sanitized == toml)
    }

    @Test
    func `indeterminate probe status preserves gateway`() async {
        let toml = """
        model = "gpt-5.3-codex"
        model_provider = "codexbar.openai-oauth"
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .unknown })
        #expect(outcome == .preserved(reason: "probe_indeterminate"))
        #expect(sanitized == toml)
    }

    @Test
    func `unrelated custom url is preserved`() async {
        let toml = """
        model = "ollama-model"
        model_provider = "ollama"
        openai_base_url = "http://127.0.0.1:11434/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        let (sanitized, outcome) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })
        #expect(outcome == .preserved(reason: "unrelated_custom_url"))
        #expect(sanitized == toml)
    }

    @Test
    func `idempotent repeated execution`() async {
        let toml = """
        model = "gpt-5.3-codex"
        model_provider = "codexbar.openai-oauth"
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """

        let (sanitizedFirst, outcomeFirst) = await CodexStaleGatewayMigration.sanitizeConfigText(toml, probe: { _ in .dead })
        #expect(outcomeFirst == .staleGatewayCleaned(previousURL: "http://127.0.0.1:1456/v1"))

        let (sanitizedSecond, outcomeSecond) = await CodexStaleGatewayMigration.sanitizeConfigText(sanitizedFirst, probe: { _ in .dead })
        #expect(outcomeSecond == .clean)
        #expect(sanitizedSecond == sanitizedFirst)
    }

    @Test
    func `file-based migration preserves prior backup sentinel without overwriting`() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codexbar-migration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let realFile = tmpDir.appendingPathComponent("real_config.toml")
        let symlinkFile = tmpDir.appendingPathComponent("config.toml")

        // Pre-create an existing backup sentinel to simulate a prior migration
        let existingBackupFile = tmpDir.appendingPathComponent(".real_config.toml.codexbar-migration-bak")
        let priorBackupContent = "# prior backup sentinel\n"
        try priorBackupContent.write(to: existingBackupFile, atomically: true, encoding: .utf8)

        let initialContent = """
        model = "gpt-5.3"
        model_provider = "codexbar.openai-oauth"
        openai_base_url = "http://127.0.0.1:1456/v1"

        [model_providers."codexbar.openai-oauth"]
        name = "OpenAI"
        """
        try initialContent.write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        let result = await CodexStaleGatewayMigration.migrate(configURL: symlinkFile, probe: { _ in .dead })

        #expect(result.outcome == .staleGatewayCleaned(previousURL: "http://127.0.0.1:1456/v1"))

        // Verify prior backup sentinel was NOT overwritten
        let preservedPrior = try String(contentsOf: existingBackupFile, encoding: .utf8)
        #expect(preservedPrior == priorBackupContent)

        // Verify a new distinct backup file was created
        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let newBackups = files.filter { $0.contains("codexbar-migration-") && $0.hasSuffix(".bak") && $0 != ".real_config.toml.codexbar-migration-bak" }
        #expect(newBackups.count == 1)

        // Verify real file was updated
        let updatedText = try String(contentsOf: realFile, encoding: .utf8)
        #expect(!updatedText.contains("openai_base_url = \"http://127.0.0.1:1456/v1\""))
        #expect(updatedText.contains("model_provider = \"openai\""))
    }
}
