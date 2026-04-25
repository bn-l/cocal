# codex-switcher — implementation plan

A macOS menu-bar app that monitors **Codex** (OpenAI) usage and lets the user
switch between multiple Codex credential profiles when usage runs low. Forked
in spirit from [bn-l/clacal](https://github.com/bn-l/clacal) and built in
**Swift** (AppKit) — same stack as clacal, so most of the menu-bar / popover /
pacing scaffolding ports directly. The data source and the profile-switcher
feature are new.

---

## 0. Prerequisites surfaced before any GitHub action

### 0.1 The "fork" can't be a literal GitHub fork

`bn-l/clacal` is owned by `bn-l`. GitHub does not allow forking a repo into
the same account that owns it. Options, listed in order of recommendation:

1. **Duplicate as a new repo under the same account** (`bn-l/codex-switcher`).
   No GitHub fork link, but we add `bn-l/clacal` as an `upstream` remote so
   we can cherry-pick fixes. This matches the user's intent (fork in spirit,
   different tool name, totally different language).
2. **Fork to a personal/secondary account** if `bn-l` has one, then transfer.
   More steps, no real benefit.
3. **GitHub "Template repository"** flag on `bn-l/clacal` — GitHub then lets
   you "Use this template" into the same account. Cleanest if a template
   relationship is desired; loses commit history of the source.

**Recommended (and confirmed by user):** option 1.

```sh
gh repo clone bn-l/clacal /Users/bml/projects/misc-projects/codex-switcher
cd /Users/bml/projects/misc-projects/codex-switcher
git remote rename origin upstream
gh repo create bn-l/codex-switcher --public --source=. --remote=origin --push
```

This preserves the full Swift history. Because the rewrite is also in Swift,
the AppKit menu-bar / popover code is **kept and adapted** rather than
discarded. The Anthropic OAuth poller is replaced; the EWMA / pacing math
in `CALCULATIONS.md` is kept; the icon glyph and color palette are restyled
(see §2.2).

---

## 1. Research findings (drives the plan)

### 1.1 How we talk to Codex — direct HTTPS to the ChatGPT backend

**Primary path: direct HTTPS via `URLSession`.** This is what the three
most popular existing Codex switchers all do
([Loongphy/codex-auth](https://github.com/Loongphy/codex-auth) 1.2k★,
[Lampese/codex-switcher](https://github.com/Lampese/codex-switcher) 224★,
[Four-JJJJ/AI-Plan-Monitor](https://github.com/Four-JJJJ/AI-Plan-Monitor)
109★). We read the `access_token` and `account_id` out of the profile's
`auth.json` snapshot, set them as headers, fire the request.

| Need | Endpoint | Method |
|---|---|---|
| Usage / rate-limit data (the polling target) | `https://chatgpt.com/backend-api/wham/usage` | GET |
| Plan info (tier, subscription state) | `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27` | GET |
| Token refresh (when access_token near expiry) | `https://auth.openai.com/oauth/token` | POST |

Required headers on the two `chatgpt.com` calls:

```
Authorization: Bearer <access_token>
chatgpt-account-id: <account_id>
User-Agent: codex-cli/1.0.0
```

Why this is the right choice:

- No subprocess management, no JSON-RPC framing, no shadow `CODEX_HOME`
  dirs (see §2.3 warmer notes)
- Doesn't require the `codex` binary to be installed at all — works
  from a stored `auth.json` snapshot
- Three independent prior-art projects have been running on these
  endpoints reliably
- Standard `URLSession` + `Codable` instead of hand-rolled stdio I/O

#### Fallback: JSON-RPC 2.0 over stdio to `codex app-server`

**Documented as a fallback only — not implemented up front.** If
testing shows the HTTPS endpoints unreliable (rate-limited from a
desktop client, response-shape changes, auth quirks we can't work
around), we scrap the HTTPS approach entirely and pivot to the stdio
route below. The two paths are mutually exclusive — we don't ship both.

Reference for the fallback (so future-us doesn't have to re-research):

- Spawn `codex app-server` and frame as one JSON object per line over
  stdin/stdout. Wire format omits the `"jsonrpc": "2.0"` header.
- Lifecycle: send `initialize` → receive `{userAgent}` → send
  `initialized` notification → ready for RPCs.
- Methods we'd need: `account/read` (account info), `account/rateLimits/read`
  (polling target). Don't need `account/login/*` (Import flow handles
  that out-of-band) or `account/logout` (removal is local-only).
- Codex.app does *not* need to be running — `codex app-server` is a
  short-lived child we'd spawn ourselves.
- Reference impls in this workspace: [`codex-app-mcp/src/codex/client.ts`](../codex-app-mcp/src/codex/client.ts),
  [`codex-app-control-research.md`](../codex-app-mcp/codex-app-control-research.md).

### 1.1.1 Canonical constants (used by the HTTPS path)

These are de-facto standard across the three prior-art projects and
should be treated as load-bearing:

| Constant | Value | Notes |
|---|---|---|
| OAuth client_id | `app_EMoamEEZ73f0CkXaXp7hrann` | The public Codex CLI client_id; identical in Lampese and AI-Plan-Monitor |
| OAuth callback port | `1455` | With `127.0.0.1:0` fallback if busy |
| OAuth scopes | `openid profile email offline_access` | |
| Extra OAuth params | `id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=codex_cli_rs` | |
| User-Agent | `codex-cli/1.0.0` | |
| Access-token expiry skew | 60 seconds | Refresh if expiring within this window |

### 1.2 Credentials storage — shared between CLI and Codex.app

Sources: [Codex auth docs](https://developers.openai.com/codex/auth), [config-advanced](https://developers.openai.com/codex/config-advanced).

- `CODEX_HOME` (default `~/.codex/`) is the shared root for both the CLI
  and the desktop app.
- `cli_auth_credentials_store` in `config.toml` selects backend:
  - `file` → `~/.codex/auth.json` (plaintext JSON: `access_token`,
    `refresh_token`, `account_id`, plus a JWT `id_token` carrying the
    `exp` claim and plan info).
  - `keyring` → macOS Keychain (Linux Secret Service / Windows Cred Manager).
  - `auto` → keyring if available else file.
- The CLI and Codex.app **share** the same store. Logging out in one logs
  out the other.

### 1.3 Token lifetime and refresh behavior — verified against openai/codex source

Cross-checked against the actual code, not just docs. Primary references:

- [`codex-rs/login/src/auth/manager.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs) — refresh manager
- [`codex-rs/login/src/token_data.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/src/token_data.rs) — `parse_jwt_expiration` for the `exp` claim
- [`codex-rs/login/tests/suite/auth_refresh.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/tests/suite/auth_refresh.rs) — refresh test matrix
- [`codex-rs/protocol/src/auth.rs`](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/auth.rs) — `RefreshTokenFailedReason` enum
- [170-carry/codex-tools `src-tauri/src/auth.rs`](https://github.com/170-carry/codex-tools/blob/main/src-tauri/src/auth.rs) — derivative tool with `auth_tokens_expire_within(auth_json, 60)` (60-second access-token JWT check)

#### What's actually in `auth.json`

`access_token` (JWT), `refresh_token`, `id_token` (JWT, carries `email`,
`account_id`, `chatgpt_plan_type` claims), and a `last_refresh` timestamp
written by Codex.

#### When Codex refreshes (proactive)

`is_stale_for_proactive_refresh` in `manager.rs` triggers refresh when
**either**:

1. The access-token JWT's `exp` claim has passed (also: derivative
   tools refresh within 60 s of expiry as a per-request safety net), **or**
2. `last_refresh < now - 8 days`. This is the literal constant
   `const TOKEN_REFRESH_INTERVAL: i64 = 8;` (days) in upstream code.

#### When Codex refreshes (reactive)

`UnauthorizedRecovery` runs on any 401: reload `auth.json` from disk
(handles the case where another process refreshed concurrently), then if
still 401, call `refresh_token_from_authority()`.

#### What "8 days" actually means

The 8-day constant is a *proactive refresh trigger*, **not a session
expiry**. As long as the refresh request succeeds, new tokens are written
to `auth.json` and the chain continues. This matches the user's
empirical observation that sessions run well past 8 days without
re-login: refresh fires at the 8-day mark, succeeds, session continues.
The earlier "stale after ~8 days" framing in this plan was wrong;
corrected here.

#### When refresh actually fails

`RefreshTokenFailedReason` in `protocol/src/auth.rs` enumerates the
permanent-failure modes. The test suite asserts each:

- `Expired` ← server returned `refresh_token_expired` — the OAuth
  server's own refresh-token TTL has elapsed
- `Exhausted` ← `refresh_token_reused` — single-use rotation enforced
  server-side; the token was already used to mint a newer one
- `Revoked` ← user logged out elsewhere or token was invalidated
- `Other` ← may be transient

**The actual refresh-token TTL is set by the OAuth server, not the
client.** It's not a constant in the codex source. Empirically it is
clearly longer than 8 days (or the proactive refresh would never have a
chance to keep things alive). Treat as "weeks-to-months and effectively
unbounded under continuous use" — but don't assume immortality.

#### What this means for the switcher

- One initial login per profile. The credentials remain useful as long
  as Codex itself keeps refreshing them, which it does proactively every
  8 days when used.
- **Single-use refresh token is the core gotcha.** Every interaction
  with a profile (live use, or background warm) rotates its refresh
  token. We must capture the rotated `auth.json` back into the profile
  snapshot. Writing a stale snapshot over a fresher one bricks the
  profile until re-login (this is exactly the
  `RefreshTokenFailedReason::Exhausted` case).
- For long-idle profiles we still want a periodic **warmer** so the
  refresh-token TTL — whatever the OAuth server has set it to — never
  elapses. A 7-day cadence (just under the 8-day proactive threshold)
  is a sensible default.

### 1.4 Plan tiers and rate-limit windows

Sources: [Codex pricing](https://developers.openai.com/codex/pricing), [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan).

- Limits are reported as a **5-hour rolling window** plus a weekly
  secondary window. `account/rateLimits/read` returns both.
- Plus / Pro 5x / Pro 20x / Business / Enterprise differ in caps.
- `/status` in the Codex CLI shows the same numbers we'll be polling.

---

## 2. Product scope

### 2.1 What clacal does that we keep

- Menu-bar widget with a compact icon (single-bar or dual-bar mode).
- Popover dashboard: pace, current 5-hour utilization, weekly utilization,
  reset countdowns.
- Local persistence of poll history under `~/.config/codex-switcher/`.
- Configurable poll interval and active hours.

### 2.2 What changes for Codex

- **Data source**: spawn `codex app-server` and call
  `account/rateLimits/read` instead of polling
  `api.anthropic.com/api/oauth/usage`.
- **Auth read**: no Keychain reading on our side — Codex's app-server
  handles credentials. We just call `account/read` for plan info.
- **Visual differentiation from clacal:**
  - clacal has no distinctive accent palette of its own, so changing
    colors wouldn't actually differentiate. Instead: **render the word
    "Codex" vertically along one side of the menu-bar icon in a tiny
    bitmap font.** Font: [mcufont](https://maurycyz.com/projects/mcufont/) —
    a microcontroller-targeted bitmap font with very small glyphs that
    stay readable at menu-bar size. Pre-render the "Codex" label to a
    template `NSImage` once at launch and composite it into every
    icon update next to the bar gauge.
  - Popover header reads "Codex" instead of "Claude Code".

### 2.3 New: credential profile switcher

The headline new feature. Scoped exclusively to **ChatGPT-subscription
accounts** (Plus / Pro 5x / Pro 20x / Business / Enterprise) — the user's
stated use case is multiple paid subscriptions on multiple OpenAI
accounts. **API-key mode is not supported in any version** — explicitly
out of scope.

- **Profile** = a named, persisted ChatGPT credential bundle: a full
  `auth.json` snapshot (`access_token` / `refresh_token` / `id_token` /
  `account_id` / `last_refresh`). Snapshot lives in our app-support dir
  (`~/Library/Application Support/codex-switcher/profiles/<profileId>/auth.json`),
  mode `0600`. The Keychain holds the per-profile encryption key only
  (so the snapshot at rest is encrypted — same approach as
  AI-Plan-Monitor, see prior-art note in §1).
- **Profile list UI** in the popover footer (or a dedicated tab).
  Each row, left-to-right:
  1. **State indicator / radio button.** Three visual states:
     - `○` (empty circle) — healthy, not active. Click to manually
       switch to this profile (runs the same swap flow as auto-switch).
     - `●` (filled circle) — active profile.
     - `⚠` (warning triangle) — profile has an issue (refresh failed
       with `Expired`/`Exhausted`/`Revoked`, snapshot unreadable,
       `account_id` mismatch, etc.). The control is **disabled** —
       cannot be selected. Hovering shows a tooltip with the specific
       error (e.g. "Refresh token expired. Run `codex login` for this
       account and re-import.").
  2. **Email / label.** Persisted user-set label, defaults to the
     account's email from the `id_token`.
  3. **Plan tier.** From cached `account/read`.
  4. **Utilization** as `5h XX% · wk XX%` from the most recent warm.
     (Option B from the design discussion: labeled values for
     unambiguous reading.)
  5. **Trash icon (🗑)** on the far right. Always enabled (works even
     for warning-state profiles, so the user can clean up broken
     snapshots). Click → confirm dialog "Remove profile {label}? This
     deletes the stored credentials. Cancel / Remove."
- Footer button: **Import credentials** (the only "add" path — see
  below).

#### Adding a profile — single import flow, no in-app login

We do not implement an OAuth flow inside the app. The user logs into
new ChatGPT accounts the normal way (`codex login` in a terminal, or
via Codex.app), which writes `~/.codex/auth.json`. Then:

1. User clicks **Import credentials** in our popover.
2. We read `~/.codex/auth.json` (and fall back to other path candidates
   if absent — see "Auth path resolver" below).
3. We extract the **dedup key** from the `id_token` JWT's
   `https://api.openai.com/auth` claim, formatted as
   `chatgpt_user_id::chatgpt_account_id`. This is what
   [`Loongphy/codex-auth`](https://github.com/Loongphy/codex-auth) uses
   and what we adopt — robust because the bytes of `auth.json` change
   on every refresh but the user/account pair doesn't.
4. We compare that dedup key against every existing profile snapshot.
5. If a match exists: surface "**No new credentials found.** Log into a
   different ChatGPT account with `codex login` and click Import again."
   (with a copy-button for the `codex login` command).
6. If no match: prompt for an optional label (default to the account's
   email from the JWT `email` claim), persist the snapshot as a new
   profile.

**Auth path resolver** (matches AI-Plan-Monitor's logic): on read, look
in this order, take the first that exists:

1. `$CODEX_HOME/auth.json`
2. `$XDG_CONFIG_HOME/codex/auth.json`
3. `~/.config/codex/auth.json`
4. `~/.codex/auth.json`

On write (during a swap), write to **all** existing paths from that
list to keep them in sync. Optionally also mirror into the macOS
Keychain under generic-password service `"Codex Auth"`, which Codex.app
desktop reads from — without this, swaps don't propagate to a running
Codex.app. (Same approach as AI-Plan-Monitor.)

This keeps the entire login surface area outside the app — Codex's own
flow handles browser OAuth, device code, MFA, etc. We just observe the
result on disk.

**Switch flow (live profile A → profile B):**

1. **Capture A's freshness first.** Read the current `~/.codex/auth.json`
   (and the other resolved paths) and write it back into profile A's
   snapshot. Absorbs any refresh that happened during the active
   session so we don't lose A's latest refresh token.
2. Write profile B's snapshot to all existing auth paths via
   `Data.write(to:options:.atomic)` followed by `chmod 600`. Keep one
   backup at `auth.json.bak` per path. (`FileManager.replaceItem` is
   overkill for a small JSON file — Lampese uses plain `fs::write`,
   AI-Plan-Monitor uses `Data.write(.atomic)`. We follow them.)
3. If Keychain mirroring is enabled, also update the `"Codex Auth"`
   generic-password entry.
4. Re-poll usage + plan info via the HTTPS path (no subprocess to
   recycle), update active profile, refresh the menu-bar icon and set
   the **needs-restart** state so the user knows to restart any
   running Codex CLI / Codex.app session.

**Profile warmer (background):**

Since we're on the HTTPS path, **no shadow `CODEX_HOME` directories
needed**. Warming is just: take the inactive profile's `auth.json`
in-memory, hit the usage endpoint with its tokens, and the response
also confirms the access_token is still valid (or 401s, in which case
we refresh inline — see §1.1.1 constants).

- Default cadence: 7 days (matches AI-Plan-Monitor's `staleInterval`).
  Configurable. Opportunistic — runs next time the app is up after the
  interval elapses.
- Per inactive profile, the warmer:
  1. Decodes the access_token JWT and checks `exp - now`.
  2. If within the 60-second skew window (or already expired), POSTs
     to `https://auth.openai.com/oauth/token` with
     `grant_type=refresh_token` + the canonical `client_id`
     (§1.1.1) to mint fresh tokens. **Persists the rotated tokens
     back into the profile snapshot immediately** — single-use refresh
     tokens make this non-negotiable (§1.3).
  3. GETs `https://chatgpt.com/backend-api/wham/usage` with the
     (possibly just-refreshed) bearer + account-id headers. Caches the
     5-hour and weekly window data on the profile.
  4. GETs `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`
     for plan tier, caches that too.
- Wraps everything in `OfficialFetchGate` (single-flight per profile)
  + `OfficialSnapshotCache` (15s TTL) so a flurry of menu opens or
  multiple subscribers can't stampede the API. (Same pattern as
  AI-Plan-Monitor.)

**Auto-switch on low usage (the swap is automatic; popover view is
informational):**

- Threshold defaults: primary-window utilization ≥ 90% with > 30 min
  until reset.
- Picker: the next profile in the user-configured priority list whose
  most recent warm shows ≤ 50% utilization. Falls back to lexical
  order if no warm data exists.
- The swap happens automatically — there's no "preview before commit"
  step. The popover shows the warmed numbers per profile so the user
  can sanity-check their priority ordering, but the runtime decision
  is made by the engine, not the user.
- macOS user notification: "Switched profile: {old} → {new}". The
  notification *and* the menu-bar icon (see next) are the visible
  signals.

**"Needs restart" icon state:**

[`Loongphy/codex-auth`'s README](https://github.com/Loongphy/codex-auth)
confirms a running Codex CLI / Codex.app session has to be restarted
after an `auth.json` swap for the new account to take effect (the
running process caches auth in memory). After every swap (manual or
automatic) we set the menu-bar icon into a "needs restart" state until
the user dismisses it.

In this state, the **bar gauges are replaced entirely by the SF Symbol
restart glyph** (e.g.
[`arrow.triangle.2.circlepath`](https://developer.apple.com/sf-symbols/)) —
not a small overlay badge. The vertical "Codex" mcufont label stays
where it is. This makes the state change unmissable at a glance: the
usage gauge disappears (since it's stale until restart anyway) and the
restart glyph takes its place. Implementation: render the symbol via
`NSImage(systemSymbolName:accessibilityDescription:)` at the gauge's
size and composite alongside the persistent "Codex" label. Clicking
the icon to open the popover, or clicking the "↻ Restart Codex"
affordance in the popover, clears the state and restores the bar
gauges.

**Keyring vs file storage of Codex itself:**

Switching the *active* `~/.codex/auth.json` only works when Codex is
configured for `file` (or `auto` falling back to file) credentials.
On startup we read `~/.codex/config.toml`:

- If `cli_auth_credentials_store = "file"` or unset and `auto` resolves
  to file: proceed normally.
- If `cli_auth_credentials_store = "keyring"`: surface a one-click
  "Switch Codex to file mode" prompt that rewrites the setting, with a
  clear note that `auth.json` will then be plaintext on disk under
  `~/.codex/` (our own snapshots are also plaintext on disk; the
  tradeoff is comparable).

Note: warming is unaffected by the user's keyring setting because we
read tokens from our own snapshot files and hit HTTPS endpoints
directly — Codex's storage backend doesn't enter the picture.

---

## 3. Swift target structure

Same general shape as clacal (Swift Package + XcodeGen + Justfile),
extended with new modules for the Codex backend client, profile store,
and switcher. Module names mirror
[Four-JJJJ/AI-Plan-Monitor's](https://github.com/Four-JJJJ/AI-Plan-Monitor)
naming since that's the closest prior art (Swift macOS menu-bar with
multi-account Codex support).

```
codex-switcher/
├── Package.swift             # SwiftPM manifest (kept from clacal, retargeted)
├── project.yml               # XcodeGen config (kept, app name + bundle id changed)
├── Justfile                  # gen / run / dmg recipes (kept)
├── Info.plist
├── Clacal.entitlements       # renamed to CodexSwitcher.entitlements
├── Sources/
│   ├── App/                  # @main AppDelegate, lifecycle, status item owner
│   │   ├── AppDelegate.swift
│   │   └── AppEnvironment.swift     # DI container: client, store, poller
│   ├── MenuBar/              # NSStatusItem + NSPopover (adapted from clacal)
│   │   ├── StatusItemController.swift
│   │   ├── IconRenderer.swift       # bar-gauge NSImage drawing + mcufont label
│   │   ├── PopoverController.swift
│   │   └── DashboardView.swift      # SwiftUI dashboard hosted in NSPopover
│   ├── CodexBackendClient/   # PRIMARY: direct HTTPS via URLSession
│   │   ├── BackendClient.swift      # GET /wham/usage, /accounts/check
│   │   ├── TokenRefresher.swift     # POST /oauth/token with canonical client_id
│   │   ├── BackendModels.swift      # Codable response shapes
│   │   └── BackendError.swift
│   ├── Pacing/               # EWMA + pacing engine (port from clacal)
│   │   ├── PacingEngine.swift
│   │   ├── SessionDetector.swift
│   │   └── BudgetCalculator.swift
│   ├── Profiles/             # the new feature
│   │   ├── Profile.swift            # model: id, label, dedupKey, lastWarmed, plan, …
│   │   ├── ProfileStore.swift       # persisted snapshot bundle (mirrors AI-Plan-Monitor's CodexAccountProfileStore)
│   │   ├── SlotStore.swift          # active-profile pointer (mirrors CodexAccountSlotStore)
│   │   ├── DesktopAuthService.swift # write to all auth.json paths + Keychain "Codex Auth"
│   │   ├── AuthPathResolver.swift   # the four-path lookup chain
│   │   ├── Snapshotter.swift        # capture / restore auth.json + JWT decode for dedup key
│   │   ├── Switcher.swift           # A → B swap algorithm (§2.3)
│   │   ├── Warmer.swift             # background refresh loop (HTTPS only, no shadow homes)
│   │   ├── SnapshotCache.swift      # 15s TTL in-memory cache (OfficialSnapshotCache equivalent)
│   │   ├── FetchGate.swift          # single-flight per profile (OfficialFetchGate equivalent)
│   │   └── ProfileListView.swift    # SwiftUI list in the popover
│   ├── Persistence/          # poll history under Application Support
│   │   ├── UsageStore.swift
│   │   └── PaceState.swift
│   ├── Config/               # ~/Library/Application Support/codex-switcher/config.json
│   │   └── AppConfig.swift
│   └── Notifications/        # UNUserNotificationCenter wrapper for auto-switch undo
│       └── NotificationCenter+Switcher.swift
├── Tests/                    # XCTest targets
│   ├── CodexBackendClientTests/  # mocked URLProtocol; one live test gated on env
│   ├── PacingTests/
│   ├── ProfilesTests/
│   └── Fixtures/
└── assets/                   # README assets, app icon source
```

**Future-fallback module (NOT built up front, see §1.1):** if HTTPS
proves unviable in testing, replace `CodexBackendClient/` with a
`CodexAppClient/` module containing `Transport.swift` (Process + Pipe),
`Protocol.swift` (JSON-RPC Codable), `Methods.swift`
(`account/read`, `account/rateLimits/read`), `ConfigDiscovery.swift`.
The two clients are mutually exclusive.

### 3.1 Swift implementation notes

- **AppKit + SwiftUI hybrid**: `NSStatusItem` + `NSPopover` are AppKit;
  the popover content is a `NSHostingView` wrapping SwiftUI. clacal already
  uses this hybrid — we keep it.
- **HTTPS via URLSession**: `URLSession.shared.data(for:)` for GET
  requests, `URLSession.shared.upload(for:from:)` for the OAuth token
  POST. Custom `URLSessionConfiguration` with the canonical
  `User-Agent: codex-cli/1.0.0` (§1.1.1).
- **Codable types**: hand-write the response shapes for `wham/usage`,
  `accounts/check/v4-2023-04-27`, and the OAuth token response. Small
  surface; no schema generator needed.
- **JWT decode (no signature verification needed)**: parse
  `id_token`'s second base64-url segment as JSON, read the
  `https://api.openai.com/auth` claim → `chatgpt_user_id` and
  `chatgpt_account_id`. We're decoding our own user's tokens locally
  for dedup; no security boundary to enforce here.
- **Concurrency**: Swift async/await throughout. `BackendClient`
  exposes `func usage(profile: Profile) async throws -> UsageSnapshot`,
  `func planInfo(profile: Profile) async throws -> PlanInfo`. Wrapped
  by `FetchGate.run(profileId:body:)` (single-flight) and
  `SnapshotCache.value(profileId:freshFor:produce:)` (15s TTL).
- **Keychain**: clacal already uses Security.framework — reuse the
  helper class, namespace items under `com.bn-l.codex-switcher.<profileId>`.
  Plus the optional generic-password mirror under service `"Codex Auth"`
  for Codex.app desktop compat.
- **TOML**: needed only if we go down the §2.3 keyring-detection path
  (read `~/.codex/config.toml`'s `cli_auth_credentials_store`). Use
  [TOMLKit](https://github.com/LebJe/TOMLKit).
- **Atomic file ops**: `Data.write(to:options:.atomic)` then
  `FileManager.setAttributes([.posixPermissions: 0o600], …)`. Single
  call, atomic on macOS, what AI-Plan-Monitor uses. Don't reach for
  `FileManager.replaceItem` — it's a heavier abstraction than we need.

### 3.2 No webview

Same as before — popover content is native AppKit/SwiftUI, no WKWebView.
Keeps the bundle small and avoids any privacy-context surprises.

---

## 4. Implementation milestones

### M1 — Repo bootstrap (½ day)
- Execute §0.1 option 1 (clone clacal, set `upstream`, create
  `bn-l/codex-switcher`, push).
- Rename `Clacal.*` to `CodexSwitcher.*` in `project.yml`,
  `Package.swift`, `Info.plist`, entitlements file. Bundle id
  → `com.bn-l.codex-switcher`.
- Confirm `just gen && just run` still launches the (untouched) menu
  bar app under the new name. This is the baseline we evolve from.

### M2 — Codex backend client (1 day, simpler with HTTPS)
- New `CodexBackendClient` Swift module.
- `BackendClient.swift`: `func usage(profile:)` → GET
  `chatgpt.com/backend-api/wham/usage`; `func planInfo(profile:)` →
  GET `chatgpt.com/backend-api/accounts/check/v4-2023-04-27`. Both with
  the `Authorization: Bearer` + `chatgpt-account-id` + `User-Agent`
  headers from §1.1.1.
- `TokenRefresher.swift`: `func refresh(profile:) async throws ->
  TokenBundle` → POST `auth.openai.com/oauth/token` with
  `grant_type=refresh_token` and the canonical client_id. JWT decode
  for the access-token `exp` claim; refresh when within the 60-second
  skew window.
- `BackendModels.swift`: hand-written Codable shapes for the three
  responses.
- XCTest: `URLProtocol`-based mocks for the unit tests; one live
  integration test gated on `CODEX_LIVE_TEST=1` env that hits the real
  endpoints with a fixture auth.json.

**Decision gate at end of M2:** if the live HTTPS calls can't be made
to work reliably (rate-limit pushback, response-shape changes, auth
quirks), we abandon `CodexBackendClient` and pivot to the JSON-RPC
stdio fallback documented in §1.1. Don't spend more than 2 days on M2
before either continuing or pivoting.

### M3 — Polling + pacing port (1 day)
- Port clacal's pacing engine. Most of `Pacing/` should be a near
  line-for-line move from `Sources/Clacal/Pacing/` — only the input
  shape changes (Anthropic usage record → Codex rate-limit window).
- Replay clacal's `simulation/` fixtures against the new engine to
  verify parity.

### M4 — Menu-bar shell rebrand (1–2 days)
- Adapt clacal's `StatusItemController` and `PopoverController` to
  the new app structure.
- `IconRenderer` keeps clacal's bar gauges; adds the vertical
  mcufont "Codex" label (§2.2) and the needs-restart SF Symbol
  state (§2.3).
- Popover dashboard wired to the new poller, using `BackendClient`'s
  `UsageSnapshot` shape.

### M5 — Persistence + config (½ day)
- Move app config / history to
  `~/Library/Application Support/codex-switcher/`.
- `config.json`: poll interval, active hours, display mode, accent
  overrides, warmer interval.
- `usage_data.json` (or `.jsonl`): poll history.

### M6 — Profile switcher (2 days)
- `Profile`, `ProfileStore`, `SlotStore`, `AuthPathResolver`,
  `DesktopAuthService`, `Snapshotter`, `Switcher` modules.
- **Single Import flow** (no in-app login): read auth.json from the
  resolver's path chain, decode the `id_token` JWT to extract the
  `chatgpt_user_id::chatgpt_account_id` dedup key, dedupe against
  existing profiles, persist or surface "No new credentials found"
  with the `codex login` instruction copy.
- The swap algorithm (§2.3) end-to-end: capture-A's-freshness,
  `Data.write(.atomic)` to all auth paths, optional Keychain
  `"Codex Auth"` mirror, set needs-restart state.
- "Needs restart" icon state via SF Symbol replacement of the gauges.
- SwiftUI profile list inside the popover, with `●` / `○` / `⚠`
  state indicator (warning row disabled with tooltip), trash button
  per row + confirm dialog.

### M7 — Warmer + auto-switch + notifications (1 day, simpler without shadow homes)
- `Warmer.swift`: per-profile inline refresh + usage poll via
  `BackendClient` + `TokenRefresher` on a configurable cadence
  (default 7 days); updates persisted snapshot + cached
  plan/utilization.
- `SnapshotCache` (15s TTL) and `FetchGate` (single-flight per
  profile) wired between callers and `BackendClient`.
- Auto-switch threshold detection in the poller.
- `UNUserNotificationCenter` integration for the switch toast +
  Undo action.

### M8 — `keyring` mode handler (½ day)
- Detect `cli_auth_credentials_store = "keyring"` on startup.
- One-click "Switch Codex to file mode" with explanatory copy.

### M9 — Packaging + release (1 day)
- Update `Justfile` `dmg` recipe: name, icon, signing identity.
- Codesign + notarize via `notarytool` with the existing entitlements
  flow from clacal.
- Homebrew tap entry mirroring clacal's, if shipping via brew.

### M10 — Visual differentiation polish (½ day)
- New app icon (`.icns`).
- Pre-render vertical "Codex" label using
  [mcufont](https://maurycyz.com/projects/mcufont/) — the bitmap font
  is delivered as a header file and a renderer; pull a small subset
  of glyphs (just `C o d e x`) at one fixed pixel size, render to a
  template `NSImage`, composite into the bar-gauge icon at every
  redraw.
- README rewrite (Codex branding, screenshots).
- Replace `assets/demo.webp` (the Manim animation) with a
  Codex-themed walkthrough — keep `manim-anim/` Python sources as a
  starting point.

---

## 5. Open questions for the user

1. **Repo name** — `codex-switcher` matches the directory; happy to use
   that or pick a punchier name (e.g. `codcal`, `codswitch`).
2. **Distribution** — Homebrew tap like clacal, or just GitHub releases?
3. **Auto-switch default** — opt-in or opt-out?
4. **Warmer interval** — 24 h is the proposed default. Too aggressive,
   too lax, or about right?
5. **`config.toml` rewrite** — comfortable with the app offering to flip
   `cli_auth_credentials_store` from `keyring` → `file`, or leave that to
   the user to do manually?

---

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Refresh-token reuse trashes a profile during a swap | Always capture live `auth.json` *back into* the active profile *before* installing the new one; `Data.write(.atomic)` + `chmod 600`; keep one backup at `auth.json.bak` per resolved path |
| Refresh-token reuse during background warming | The warmer holds tokens in memory and writes the rotated tokens straight back to the profile's snapshot; it never touches the live `~/.codex/auth.json` (only the active swap does) |
| HTTPS endpoints change shape or get tightened | Decision gate at end of M2 (§4): pivot to JSON-RPC stdio fallback (§1.1) if HTTPS proves unviable. Hand-written Codable types with optional fields; integration test exercises the live shape |
| HTTPS endpoints rate-limit a desktop client | `OfficialFetchGate` single-flight + `OfficialSnapshotCache` 15s TTL stop spam on rapid menu opens; warmer cadence ≥ 7 days per profile |
| Codex CLI also running and competing for `auth.json` refresh | Out of scope — same race exists today between CLI and Codex.app. We document it and detect via `lsof ~/.codex/auth.json` before swapping (warn if held) |
| Long-idle profile rots before the warmer next runs | Refresh on demand: when the user clicks Switch on a profile whose last-warm is stale, run a refresh + usage poll inline before installing it |
| Keychain prompts annoy the user on every switch | Use `kSecAttrAccessibleAfterFirstUnlock` and a single keychain item per profile so prompts only appear at first unlock per session |
| User has Codex on `keyring` mode | Detect on startup and refuse to swap until the user accepts the file-mode prompt (§2.3). The HTTPS warmer is unaffected (it never touches Codex's storage) |

---

## Sources

### Official Codex docs
- [Codex Authentication](https://developers.openai.com/codex/auth)
- [Codex CI/CD auth guide](https://developers.openai.com/codex/auth/ci-cd-auth)
- [Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [Codex pricing](https://developers.openai.com/codex/pricing)
- [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan)
- [openai/codex authentication.md](https://github.com/openai/codex/blob/main/docs/authentication.md)

### openai/codex source (verified token-lifetime claims in §1.3)
- [`codex-rs/login/src/auth/manager.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs) — `TOKEN_REFRESH_INTERVAL = 8 days`, `is_stale_for_proactive_refresh`, `UnauthorizedRecovery`
- [`codex-rs/login/src/token_data.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/src/token_data.rs) — `parse_jwt_expiration`, `TokenData`
- [`codex-rs/login/src/auth/storage.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs) — disk persistence
- [`codex-rs/login/tests/suite/auth_refresh.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/tests/suite/auth_refresh.rs) — refresh test matrix (9-day staleness fixtures, expired-access-token fixtures)
- [`codex-rs/protocol/src/auth.rs`](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/auth.rs) — `RefreshTokenFailedReason` enum: `Expired` / `Exhausted` / `Revoked` / `Other`

### Bug reports informing risk model
- [issue #6498 — refresh token already used](https://github.com/openai/codex/issues/6498)
- [issue #17041 — live session can't continue on auth refresh](https://github.com/openai/codex/issues/17041)
- [issue #17265 — MCP token refresh](https://github.com/openai/codex/issues/17265)

### Existing prior-art projects (informing UX and confirming approaches)
- [Loongphy/codex-auth](https://github.com/Loongphy/codex-auth) (1246★) — CLI switcher. Confirms "switch then restart client" requirement and the `--auto` switch-on-zero-percent UX
- [Four-JJJJ/AI-Plan-Monitor](https://github.com/Four-JJJJ/AI-Plan-Monitor) (109★) — Swift macOS menu-bar app with Codex multi-account support; closest prior art to our shape
- [Lampese/codex-switcher](https://github.com/Lampese/codex-switcher) (224★) — Tauri desktop app, dual login mode (OAuth + import existing `auth.json`)
- [isxlan0/Codex_AccountSwitch](https://github.com/isxlan0/Codex_AccountSwitch) (143★)
- [170-carry/codex-tools](https://github.com/170-carry/codex-tools) — Tauri/Rust derivative; `auth_tokens_expire_within(auth_json, 60)` reference impl
- [wishworldbetter/codex-switch](https://github.com/wishworldbetter/codex-switch) (32★) — macOS toolbar Codex switcher
- [wannanbigpig/codex-accounts-manager](https://github.com/wannanbigpig/codex-accounts-manager) (34★) — VS Code extension version

### Reference impl in this workspace
- `../codex-app-mcp/src/codex/client.ts` — JSON-RPC stdio client we're porting to Swift
- `../codex-app-mcp/codex-app-control-research.md` — protocol research notes
- `../codex-app-mcp/src/tools/account/` — `account/read`, `account/rateLimits/read`, `account/login/*` wrappers

---

## Appendix A — UI mockups

### Menu-bar icons (shown ~3× actual size)

**Single-bar mode** (one vertical gauge = primary 5-hour remaining;
filled = remaining capacity, drains as you use):

```
 ┌────────────────┐
 │ ┌──┐         C │
 │ │██│         o │
 │ │██│         d │
 │ │██│         e │
 │ │░░│         x │
 │ └──┘           │
 └────────────────┘
   ▲              ▲
   gauge          mcufont vertical "Codex" label
```

**Dual-bar mode** (left = 5-hour remaining, right = weekly remaining):

```
 ┌────────────────┐
 │ ┌──┐┌──┐     C │
 │ │██││██│     o │
 │ │██││▓▓│     d │
 │ │██││▓▓│     e │
 │ │░░││▓▓│     x │
 │ └──┘└──┘       │
 └────────────────┘
```

**Needs-restart state** — the gauges are *replaced entirely* by the SF
Symbol restart glyph (`arrow.triangle.2.circlepath`); the "Codex"
label persists. Cleared by opening the popover or clicking the
"↻ Restart Codex" footer affordance.

```
 ┌────────────────┐
 │                │
 │     ╭─╮      C │
 │   ↺   ╲      o │
 │   ╲    ↻     d │
 │    ↻        e │
 │     ╰─╯      x │
 │                │
 └────────────────┘
```

### Popover

Layout mirrors clacal's existing
[`PopoverView.swift`](https://github.com/bn-l/clacal/blob/main/Sources/Clacal/Views/PopoverView.swift)
+ [`MetricsView.swift`](https://github.com/bn-l/clacal/blob/main/Sources/Clacal/Views/MetricsView.swift)
— same 6-row metrics structure, same footer button set, plus a Profiles
section before the footer.

**Metrics rows (top-to-bottom, ports directly from clacal):**

1. **Pace** — center-zero `DeviationRow` (the calibrator value: `Ease off` / `Use more`)
2. **Session Pace** — center-zero `DeviationRow` (`Ahead` / `Behind`)
3. **Weekly Pace** — center-zero `DeviationRow` (`Ahead` / `Behind`)
4. **Daily Budget** — `BudgetGaugeRow` showing remaining-of-budget %
5. **Session** — `GaugeRow` with usage %, elapsed-time underline, footer detail (`Xh Ym left · target Z%`)
6. **Weekly** — `GaugeRow` with usage %, elapsed-time underline, footer detail (`Xd Yh until reset`)

For Codex these map to:
- "Session" = the 5-hour primary rate-limit window (Codex's primary)
- "Weekly" = the weekly secondary rate-limit window
- "Daily Budget" / "Pace" / "Session Pace" / "Weekly Pace" come straight
  from the ported pacing engine (clacal's EWMA, active-hours, target
  scheduling)

**Footer button set (matches clacal exactly, plus our additions):**

- "Updated 2m ago" relative timestamp (left, tertiary text)
- `arrow.clockwise` — manual refresh
- `chart.bar.fill` ↔ `gauge.with.needle` — toggle dual-bar / single-bar
  display mode (this is the missing-from-my-mockup mode-swap button)
- `chart.bar.xaxis` — open stats view (also missing from my earlier mockup)
- *new for codex-switcher:* `arrow.left.arrow.right` — auto-switch
  toggle (filled when ON, outlined when OFF)
- *new for codex-switcher:* `arrow.triangle.2.circlepath` — visible
  only in needs-restart state; click to dismiss
- Spacer
- "Quit" text button

**Mockup:**

```
┌────────────────────────────────────────────────────┐
│  Pace            Ease off  +23%                    │
│  ░░░░░░░░░░░░░░░░█████░░░░░░░░░░░░░                │
│                                                    │
│  Session Pace    Behind  −12%                      │
│  ░░░░░░░░░██░░░░░░░░░░░░░░░░░░░░░░░                │
│                                                    │
│  Weekly Pace     On pace  0%                       │
│  ░░░░░░░░░░░░░░░░│░░░░░░░░░░░░░░░░░                │
│                                                    │
│  Daily Budget                          82%         │
│  ████████████████████████████░░░░░░░               │
│                                                    │
│  Session                               72%         │
│  ███████████████████░░░░░░░                        │
│  ██████░░░░░░░░░░░░░  (elapsed underline)         │
│  2h 14m left · target 65%                          │
│                                                    │
│  Weekly                                18%         │
│  ████░░░░░░░░░░░░░░░░░░                            │
│  ███████░░░░░░░░░░░░  (elapsed underline)          │
│  4d 16h until reset                                │
├────────────────────────────────────────────────────┤
│  Profiles                                          │
│  ●  work@openai.com   Pro 20x  5h 72% · wk 18%  🗑 │
│  ○  home@gmail.com    Pro 5x   5h 12% · wk  4%  🗑 │
│  ⚠  side@example.io   Plus     5h  — · wk  —   🗑 │
│                                                    │
│  ┌──────────────────────┐                          │
│  │ + Import credentials │                          │
│  └──────────────────────┘                          │
├────────────────────────────────────────────────────┤
│  Updated 2m ago    ↻  ⊞  📊  ⇌            Quit    │
└────────────────────────────────────────────────────┘
```

Footer icon legend (left → right): `↻` refresh · `⊞` mode toggle ·
`📊` stats · `⇌` auto-switch toggle. The needs-restart
`arrow.triangle.2.circlepath` glyph appears between the toggle and
Quit only when active.

Per-row controls:

- `●` filled circle = active profile
- `○` empty circle = healthy inactive profile, click to manually switch
- `⚠` warning = profile has an issue (e.g. refresh-token expired);
  disabled, hover for tooltip with the specific error message
- `🗑` trash = always enabled, opens the remove-confirm dialog

### Remove-confirm dialog

```
┌─────────────────────────────────────────┐
│  Remove profile "home@gmail.com"?       │
│                                         │
│  This deletes the stored credentials    │
│  for this account. You'll need to run   │
│  `codex login` and Import again to      │
│  re-add it.                             │
│                                         │
│              ┌────────┐ ┌────────┐      │
│              │ Cancel │ │ Remove │      │
│              └────────┘ └────────┘      │
└─────────────────────────────────────────┘
```
