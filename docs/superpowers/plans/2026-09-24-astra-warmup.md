# Astra First-message Warmup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in Sol/low warmup before the first Astra prompt, then release Windows and macOS builds with dynamic API model catalogs.

**Architecture:** A synchronous user-level UserPromptSubmit hook gates Astra's original request. Native PowerShell and Swift implementations share a behavioral contract, but never rewrite user prompts or the official client. A per-account authorization fingerprint and per-session completion marker isolate accounts and concurrent windows.

**Tech Stack:** Windows PowerShell 5.1/WPF, Swift 5.9/Foundation/SwiftUI, existing Codex app-server loopback integration harness, GitHub Actions.

## Global Constraints

- No workspace/project edits, official-client patching, or hook-trust bypass in shipped behavior.
- Default off. Explicit cost consent per API endpoint/key combination. ChatGPT login and non-Astra prompts cause no warmup request.
- Exact models: target `gpt-6-astra`; warmup `gpt-5.6-sol`; reasoning effort `low`.
- Fixed warmup prompt `Reply only OK.`; never forward original user prompt, attachments, tools, or workspace context to Sol.
- Read current file auth and the built-in openai route; never persist another plaintext API key.
- HTTPS verification stays enabled. HTTP is allowed only for loopback. No redirects, no paid tests, no response/body/secret logging.
- Network deadline at most 20 seconds; lock contention at most 5 seconds; hook timeout 40 seconds. Response size cap 131072 bytes. No automatic retries.
- Only a complete successful Responses result (JSON status completed or SSE response.completed with response.status completed) marks success. Error, incomplete, malformed, timeout or HTTP non-2xx blocks the prompt with a sanitized explanation.
- One completion per `(endpoint + API key, session_id)`. Atomic writes and cross-process lock, preserve concurrent windows and unrelated hooks.
- Runtime dependencies remain PowerShell/WPF on Windows and the Swift app on macOS; Python is for tests only.
- Version v0.3.0 prerelease, macOS Universal, ad-hoc signed and not notarized. Publish only green same-commit CI artifacts and combined SHA256SUMS.

## Behavioral protocol

Hook receives a JSON object on stdin. Successful/irrelevant invocations emit nothing and exit 0. Warmup failure emits `{"decision":"block","reason":"Astra warmup failed; original message was not sent. Retry or disable warmup."}` and exits 0. Errors must not include response bodies, credentials or prompt text.

Fingerprint is SHA256 UTF-8 `endpoint + "\n" + apiKey`, rendered lowercase hexadecimal. Sidecar `astra-warmup.json` in the platform's existing switcher vault contains `version: 1` and `profiles: [fingerprint]`; no endpoint or key is needed. Session marker names hash `fingerprint + "\n" + session_id` under `astra-warmup-sessions/`. Validate session id as 1–128 ASCII letters/digits/underscore/hyphen. Markers store only a success indicator. A lock in the same private directory serializes duplicate session operations; unrelated sessions need not be serialized.

Install one command handler with `statusMessage: "Codex Account Switcher: Astra warmup"`, `timeout: 40`, `type: "command"` under `UserPromptSubmit`. On install/remove, match the owned handler using its unique statusMessage and owned executable/script shape, preserve all other groups/keys/handlers, refuse malformed files, and keep a recoverable pre-edit backup. Never edit trust records. Disable removes only current fingerprint; if none remain remove only our handler. Existing enabled profiles must not be lost on adding/disabling another.

Warmup POST goes to validated Base URL + `/responses`; bearer credentials remain in memory. Body: `model`, `input: "Reply only OK."`, `reasoning: {effort:"low"}`, `tools: []`, `stream: true`, `store: false`, `max_output_tokens: 256`. The hook never submits Astra itself: after success the official runtime continues the unchanged original message and settings.

### Task 1: Windows hook, opt-in entry and tests

**Files:** Create `tools/chatgpt-account-switch/AstraWarmup.ps1`, `Invoke-AstraWarmup.ps1`, `Configure-AstraWarmup.ps1`, `Test-AstraWarmup.ps1`; root `Astra-Warmup.cmd`. Modify `Test-All.ps1`, `scripts/Export-PublicRelease.ps1` only for own new Windows files. Avoid changing existing profile schemas.

**Interfaces:** `Invoke-AstraWarmup -HomePath <absolute> -VaultPath <absolute> -Event <object>` returns null or a blocking object. `Set-AstraWarmupEnabled -HomePath -VaultPath -HookScriptPath -Enabled <bool> -ConfirmCost <bool>` configures the current file API login and user-level hooks. `Get-AstraWarmupEnabled -HomePath -VaultPath` returns bool for current endpoint/key. Export pure request/response validation functions as needed. `Invoke-AstraWarmup.ps1` is a stdin/stdout entry without GUI; real paths always derive from current user, no arbitrary event cwd paths. The optional standalone WPF configuration entry is launched by root `Astra-Warmup.cmd`, allowing enable/disable with clear cost/trust/restart instructions. It must not make network calls on enable.

- [ ] Write real-behavior tests in isolated temp home/vault with fake auth/config. First test must fail before code exists. Use a loopback HTTP fixture, not real user data.

```powershell
$event=[pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='session-one';model='gpt-6-astra';prompt='PRIVATE_ORIGINAL_SENTINEL'}
Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
$result=Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event
Check ($null -eq $result) 'A completed Sol response releases the original turn.'
```

- [ ] Implement the behavioral protocol above, including false/falsey consent handling, safe-path checks, timeout and response caps, no redirect leaks, account matching, exactly-once success and failure block.
- [ ] Add offline cases: disabled/non-Astra/ChatGPT; metadata malformed; success then duplicate; two sessions; account/key change; failure then retry; incomplete/error SSE; invalid JSON; redirects; secrets never in stdout/state; preserve unrelated hooks, idempotent enable, disable only current account; concurrent invocations.
- [ ] Run targeted test and the existing Windows suite. Commit only assigned files. Report evidence and any unverified integration behavior.

### Task 2: macOS hook, settings entry and tests

**Files:** Create `macos/Sources/SwitcherCore/AstraWarmup.swift`, `macos/Tests/SwitcherCoreTests/AstraWarmupTests.swift`; modify `macos/Sources/SwitcherApp/App.swift` for an early non-GUI `--astra-warmup` entry and current-API settings action. Add test-only executable target/product `WarmupFixture` at `macos/Tests/Fixtures/WarmupFixture/main.swift` in Package.swift, never bundled in the released .app. Update explicit export list for new Swift files. The fixture driver uses only environment `WARMUP_FIXTURE_HOME` and `WARMUP_FIXTURE_ROOT` for fake-data paths: `--configure` invokes the real setEnabled with its own executable and consent true; `--astra-warmup` invokes the real run with stdin, writing returned Data if any. Refuse paths outside an `astra-warmup-integration-*` temporary root. This keeps test path overrides out of the shipped entry.

**Interfaces:** `public enum AstraWarmup` exposes `run(event: Data, home: URL, root: URL) -> Data?`, `setEnabled(_ enabled: Bool, home: URL, root: URL, executable: URL, consent: Bool) throws`, `isEnabled(home: URL, root: URL) throws -> Bool`. Native URLSession transport has dependency injection at the HTTP boundary for offline tests and rejects redirects. Use existing PrivateFiles safeguards, never Keychain prompt in the hook. Settings opt-in is explicit and defaults off; do not change saved profile/auth schemas.

- [ ] Write XCTest fixtures matching the same behavioral protocol, proving no Sol request contains the original message and no completion marker is set on errors. Run on Mac CI to capture initial failure before implementation.

```swift
let event = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"session-one","model":"gpt-6-astra","prompt":"PRIVATE_ORIGINAL_SENTINEL"}"#.utf8)
let output = AstraWarmup.run(event: event, home: fixture.home, root: fixture.vault)
XCTAssertNil(output)
```

- [ ] Implement native logic and enable/disable settings preserving unrelated hook fields. Keep network and lock deadlines bounded below host timeout. Add immediate process exit in hook mode without starting SwiftUI or requesting Keychain.
- [ ] Verify matching unit cases and app compilation on macOS, commit assigned files and report results.

### Task 3: Official runtime integration, review and release

**Files:** Create `tools/chatgpt-account-switch/Test-AstraWarmupIntegration.py`; extend both CI workflows to run isolated integration against pinned official CLI supporting hooks. Update README, macos/README, CHANGELOG, macos/Info.plist, export list and build packaging.

**Interfaces:** Windows test invokes the native hook core through a test-only path wrapper; macOS invokes the native core through the Task 2 WarmupFixture executable. This keeps fake home/vault overrides out of production entrypoints. The production non-GUI entrypoint is separately checked during app build/review. A local fixture returns complete Sol SSE, records model/effort/order/body, then deliberately rejects Astra at the transport boundary. A second prompt confirms no duplicate warmup; a failure fixture confirms the official runtime sends no Astra request. Only the isolated test home may use explicit hook trust or the documented one-off vetted test override; the shipped installer never bypasses trust.

- [ ] Run an isolated characterization first to confirm UserPromptSubmit ordering/block semantics and model field before publishing an integration claim.
- [ ] Add the transport test and validate literal expected sequence `["gpt-5.6-sol", "gpt-6-astra"]`, effort `low`, warmup input `Reply only OK.`, and original Astra input contains `PRIVATE_ORIGINAL_SENTINEL` exactly once. Fail if warmup receives that sentinel.
- [ ] Resolve existing model-catalog CI failures, perform focused task reviews then a whole-branch review; fix correctness/security findings and re-run affected tests.
- [ ] Document opt-in, cost/trust, experimental provider-specific effect, model-cache refresh boundaries and rollback/uninstall; bump app version to 0.3.0 and build to 3.
- [ ] Run full Windows and macOS CI, merge PR into main, await green main SHA builds, create v0.3.0 prerelease with both ZIPs and hashes. Verify published assets and return PR/release links. Preserve all user workspaces and dirty original checkout.
