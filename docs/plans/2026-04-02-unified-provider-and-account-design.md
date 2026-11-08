# Unified Provider And Account Design

Date: 2026-04-02

## Summary

This document defines the next-generation Codex menu bar app built on top of the current `xmasdong/codexbar` codebase.

The goal is to keep the lightweight OpenAI account-switching UX from the current app while adding:

- custom OpenAI-compatible providers
- multiple API-key accounts per provider
- a single source of truth for provider and account state
- local usage-cost history and amount tracking from the shared Codex session pool

The app will not replace Codex Desktop's own history UI. Instead, it will preserve a single shared `~/.codex` session pool so users can keep resuming sessions from Codex Desktop even after switching provider or account.

## Goals

- Keep a single shared Codex session pool under `~/.codex`.
- Allow switching between:
  - OpenAI OAuth accounts
  - custom OpenAI-compatible providers
  - multiple API-key accounts under each custom provider
- Make the menu bar app the single source of truth for active provider/account selection.
- Synchronize the active selection into `~/.codex/config.toml` and `~/.codex/auth.json`.
- Preserve the current global model selection behavior:
  - provider selection changes `base_url` and credentials
  - model selection remains global
- Show local historical cost and usage derived from `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Continue showing OpenAI quota data for OAuth-backed OpenAI accounts.

## Non-Goals

- Do not support the full `steipete/CodexBar` provider matrix.
- Do not build a replacement for Codex Desktop's native session history or resume picker.
- Do not split session storage by provider or account.
- Do not switch `CODEX_HOME`.
- Do not auto-restart Codex Desktop after provider/account changes.
- Do not require custom providers to expose remote quota APIs.

## Product Scope

V1 supports exactly two provider kinds:

1. `openai_oauth`
   - OpenAI/Codex accounts authenticated via OAuth tokens
   - multiple accounts supported
   - can show remote quota data

2. `openai_compatible`
   - custom provider defined by `label + base_url`
   - multiple API-key accounts supported under each provider
   - default behavior only shows current configuration and local cost history

The provider list may include built-in presets such as `FunAI`, `S`, and `HTJ`, but those are only prefilled `openai_compatible` entries. They are not special provider implementations.

## Core Principle: One Shared Session Pool

The app must preserve a single shared session pool:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

Provider switching and account switching must only update the configuration that Codex uses for future requests. They must not relocate or partition session files.

As a result:

- existing Codex Desktop history remains visible
- old sessions remain resumable
- changing provider or account does not make a session disappear
- users can continue an existing session with the currently active provider/account

This design intentionally relies on Codex Desktop's existing history and `resume` behavior rather than reimplementing session continuation in the bar.

## Configuration Model

### Source of truth

The app owns a single configuration file:

- `~/.codexbar/config.json`

This file stores:

- global model settings
- all providers
- all accounts under each provider
- the active provider
- the active account per provider

Derived files managed by the app:

- `~/.codexbar/cost-cache.json`
- `~/.codexbar/switch-journal.jsonl`

### Config schema

```json
{
  "version": 1,
  "global": {
    "defaultModel": "gpt-5.4",
    "reviewModel": "gpt-5.4",
    "reasoningEffort": "xhigh"
  },
  "active": {
    "providerId": "funai",
    "accountId": "acct_funai_main"
  },
  "providers": [
    {
      "id": "openai-oauth",
      "kind": "openai_oauth",
      "label": "OpenAI",
      "enabled": true,
      "baseUrl": null,
      "accounts": [
        {
          "id": "acct_openai_alice",
          "kind": "oauth_tokens",
          "label": "alice@company.com",
          "email": "alice@company.com",
          "openaiAccountId": "user-xxx",
          "accessToken": "...",
          "refreshToken": "...",
          "idToken": "...",
          "lastRefresh": "2026-04-02T10:00:00Z",
          "addedAt": "2026-04-01T12:00:00Z"
        }
      ],
      "activeAccountId": "acct_openai_alice"
    },
    {
      "id": "funai",
      "kind": "openai_compatible",
      "label": "FunAI",
      "enabled": true,
      "baseUrl": "https://api.funai.vip",
      "accounts": [
        {
          "id": "acct_funai_main",
          "kind": "api_key",
          "label": "Main",
          "apiKey": "sk-...",
          "addedAt": "2026-04-01T12:00:00Z"
        }
      ],
      "activeAccountId": "acct_funai_main"
    }
  ]
}
```

### File requirements

- `config.json` must be written with `0600` permissions.
- Writes must be atomic.
- The app must tolerate unknown future fields.
- IDs must be opaque stable strings, not derived from labels.

## Synchronization Into Codex

The bar is the only writer of the normalized active configuration.

It writes to:

- `~/.codex/config.toml`
- `~/.codex/auth.json`

It does not own or rewrite unrelated Codex settings. Synchronization should preserve:

- `projects.*`
- `features.*`
- `skills.config`
- unrelated user settings

### `auth.json` normalization

#### When active provider kind is `openai_oauth`

Write:

```json
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "last_refresh": "2026-04-02T10:00:00Z",
  "tokens": {
    "access_token": "...",
    "refresh_token": "...",
    "id_token": "...",
    "account_id": "..."
  }
}
```

Rules:

- clear any previous `OPENAI_API_KEY`
- write only the active OAuth account
- do not keep inactive OAuth accounts in `auth.json`

#### When active provider kind is `openai_compatible`

Write:

```json
{
  "OPENAI_API_KEY": "sk-..."
}
```

Rules:

- remove `auth_mode`
- remove `last_refresh`
- remove `tokens`
- only the active account's API key is written

This is stricter than the current `codexapi` behavior and is intentional. Mixed OAuth token and API-key state in `auth.json` must not survive synchronization.

### `config.toml` normalization

The bar manages only the provider-related fields:

- `model_provider`
- `model`
- `review_model`
- `model_reasoning_effort`
- `service_tier`
- `oss_provider`
- `model_catalog_json`
- `preferred_auth_method`
- `[model_providers.OpenAI]`

#### Common rules

- `model`, `review_model`, and `model_reasoning_effort` always come from `config.json.global`
- any provider-specific field not used by the active provider must be removed
- `preferred_auth_method` is removed in v1

#### When active provider kind is `openai_oauth`

Write:

```toml
model_provider = "OpenAI"
model = "gpt-5.4"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
```

Also remove:

- `[model_providers.OpenAI]`
- `service_tier`
- `oss_provider`
- `model_catalog_json`

#### When active provider kind is `openai_compatible`

Write:

```toml
model_provider = "OpenAI"
model = "gpt-5.4"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://api.funai.vip"
wire_api = "responses"
requires_openai_auth = true
```

Also remove:

- `service_tier`
- `oss_provider`
- `model_catalog_json`

### Backup behavior

Before every synchronization pass:

- copy `~/.codex/config.toml` to `~/.codex/config.toml.bak-codexbar-last`
- copy `~/.codex/auth.json` to `~/.codex/auth.json.bak-codexbar-last`

Then replace files atomically.

### Activation semantics

- switching provider/account updates only configuration files
- changes apply to new sessions only
- the app shows a success message:
  - `Updated Codex configuration. Changes apply to new sessions.`

## Migration From Existing `codexapi`

Migration is one-time and imports existing state into `~/.codexbar/config.json`.

### Files read during migration

- `~/.codex/config.toml`
- `~/.codex/auth.json`
- `~/.codex/provider-secrets.env`
- optionally `~/.codex/token_pool.json`

### Imported global settings

From `~/.codex/config.toml`:

- `model`
- `review_model`
- `model_reasoning_effort`

### Imported built-in provider presets

From `~/.codex/provider-secrets.env`:

- `OPENAI_API_KEY` -> provider `funai` with `baseUrl = https://api.funai.vip`
- `S_OAI_KEY` -> provider `s` with `baseUrl = https://api.0vo.dev/v1`
- `HTJ_OAI_KEY` -> provider `htj` with `baseUrl = https://rhino.tjhtj.com`

Each discovered key becomes the first imported API-key account for that provider.

### Imported OAuth accounts

From `~/.codex/auth.json`:

- if `tokens.account_id` exists, import one OpenAI OAuth account

From `~/.codex/token_pool.json` when present:

- import all stored OpenAI OAuth accounts

### Current active selection detection

Current active mode is determined in this order:

1. `config.toml` indicates custom `OpenAI` provider block with a `base_url`
2. else `auth.json` contains OAuth `tokens.account_id`
3. else `auth.json` contains `OPENAI_API_KEY`

If the current `base_url` does not match a known imported preset, migration creates a new custom provider with:

- `label` derived from the host
- imported active API-key account labeled `Imported`

### Post-migration normalization

After import:

- write `~/.codexbar/config.json`
- immediately run one synchronization pass back into `config.toml` and `auth.json`

This eliminates ambiguous mixed-state configurations left by older tools.

### Out of scope for migration

- `ollama` is not imported in v1
- existing `provider-secrets.env` is preserved but no longer treated as a source of truth

## Menu Interaction Model

### High-frequency actions in the menu bar

The menu bar menu should support:

- current active status
  - provider label
  - account label
  - global model
- provider switcher
  - one-tap provider activation
  - built-in presets and custom providers shown together
  - add-provider button
- active provider account list
  - switch account
  - add account
  - delete account
- local cost summary
  - today
  - rolling 30 days
- OpenAI quota summary
  - only for `openai_oauth`
- quit and refresh actions

### Settings window

The settings window should host lower-frequency editing:

- General
  - global model
  - review model
  - reasoning effort
- Providers
  - add custom provider
  - edit label
  - edit `baseUrl`
  - reorder providers
  - delete provider
  - manage accounts under provider
- OpenAI
  - add/re-auth/delete OAuth accounts
- History
  - local cost history settings

### V1 behavior notes

- provider switch changes only future Codex requests
- account switch changes only future Codex requests
- the current session pool and history UI remain owned by Codex Desktop

## Historical Cost And Amount Tracking

History and amount tracking are local-only in v1 for custom providers.

### Data sources

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/*.jsonl`

### Strategy

Adapt the local cost scanner approach from `steipete/CodexBar`:

- parse Codex JSONL session logs
- extract token counts and model markers
- compute rolling daily totals
- store cached derived results in `~/.codexbar/cost-cache.json`

### Output

The menu shows:

- total local cost today
- total local cost in the last 30 days
- optional per-model breakdown in the settings window

### Attribution

V1 does not require per-provider historical attribution to function.

The key requirement is preserving one shared session pool so that sessions remain resumable from Codex Desktop after provider switches.

Per-provider historical attribution can be improved later using `switch-journal.jsonl`, but it is not required for initial release.

## OpenAI Quota Tracking

Only `openai_oauth` supports remote quota tracking in v1.

The current `WhamService` path remains valid:

- use active OAuth account tokens
- call OpenAI's usage endpoint
- update menu display with current 5-hour and weekly values

Custom providers do not attempt remote quota fetching in v1.

## Security

- all secrets live in `~/.codexbar/config.json`
- file permissions must be `0600`
- app logs must never print raw API keys, OAuth tokens, or cookie headers
- UI should show only masked API keys
- backup files under `~/.codex/*.bak-codexbar-last` must also retain secure permissions

## Risks

### Codex Desktop compatibility

Codex may evolve its `config.toml` and `auth.json` expectations. The synchronization layer must therefore:

- preserve unknown settings
- minimize the set of fields it owns
- centralize all normalization logic in one service

### Session continuation assumptions

This design assumes:

- Codex Desktop uses one shared `~/.codex` session pool
- session continuation depends on session IDs and session files, not on provider-specific storage

Current local evidence supports this behavior, but it remains an implementation-dependent assumption of Codex Desktop.

### Mixed legacy state

Older tools may leave partially conflicting `auth.json` and `config.toml` contents. The migration flow must aggressively normalize the active mode after import.

## Implementation Phases

### Phase 1: Configuration foundation

- add `~/.codexbar/config.json` model and persistence layer
- add migration from existing `codexapi` files
- add synchronization service for `config.toml` and `auth.json`

### Phase 2: Provider and account management

- add custom provider CRUD
- add per-provider API-key account CRUD
- add active provider/account switching
- keep current OAuth account add/switch flow working

### Phase 3: Usage and history

- integrate local cost scanner
- add cached daily totals and menu summaries
- keep OpenAI quota display for OAuth accounts

### Phase 4: UX polish

- add better status messages
- add import diagnostics
- add backup restore affordances if synchronization fails

## Recommended Implementation Base

Use the current `xmasdong/codexbar` repository as the implementation base.

Rationale:

- its OpenAI account-switching UX is already close to the desired interaction model
- only selected `steipete/CodexBar` concepts need to be transplanted
- adopting the full `steipete` architecture would introduce substantially more scope than required

