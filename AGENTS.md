# CodexBar & codexbar Repository Guidelines

## 默认工作语言 / Collaboration Guidance
- 本仓库的默认工作语言是简体中文。
- 交互与交付说明默认使用中文，代码、注释及 Git commit 遵循英文 Conventional Commits 规范。

## Project Structure & Modules
- `Sources/CodexBar`: Swift 6 menu bar app (usage/credits probes, icon renderer, settings).
- `Sources/CodexBarCLI`: CLI tool (`codexbar usage`, `cards`, `guard`, etc.).
- `Sources/CodexBarCore`: Shared models, providers, credentials, config store.
- `codexBar`: Native SwiftUI macOS menu bar app with iCloud Drive device sync.
- `codexbar.xcodeproj`: Xcode project definition.
- `Tests/CodexBarTests`: XCTest & Swift Testing suite.
- `codexBarTests`: Unit test suite for native app features.
- `Scripts`: Build and packaging helpers.

## Safety Rules
- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` when Codexbar can perform the operation.
- Do not print `access_token`, `refresh_token`, or `id_token` in logs, output, or summaries.
- Keep user credentials and OAuth secrets strictly safe and never commit real client configuration.
