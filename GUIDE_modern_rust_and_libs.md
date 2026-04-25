# Modern Rust & Libraries Cheat Sheet

Last updated: 2026-04-21. Focuses on features stabilized / released in the last
~2 years (Rust) and the last ~12 months (libraries). Every snippet is meant to
be copy-pasteable and idiomatic for today's stable toolchain.

- **Toolchain target**: Rust 1.85+ (for Rust 2024 edition); some items require 1.88+ (let chains) or 1.95+ (if-let match guards, `cfg_select!`).
- **Cargo.toml root**: `edition = "2024"`, and set `rust-version` to the oldest
  compiler you actually want to support — `1.85` as a floor for edition 2024,
  `1.88` if you use let chains, `1.95` if you use if-let match guards.

---

## 1. Rust language (1.85 → 1.95, Edition 2024)

### 1.1 Edition 2024 essentials (stable since 1.85, Feb 2025)

```toml
# Cargo.toml
[package]
edition = "2024"
rust-version = "1.85"
```

- `cargo fix --edition` handles most mechanical migration. Keep its output
  conservative; then hand-migrate where you want the new semantics.
- The MSRV-aware resolver is the default in edition 2024 — the
  `rust-version` field actually constrains dependency selection.

### 1.2 What's new you should actually use

**Async closures** (1.85 / 2024):
```rust
let fetch = async |url: &str| -> reqwest::Result<String> {
    reqwest::get(url).await?.text().await
};
let body = fetch("https://example.com").await?;
```
Async closures are real `AsyncFn` / `AsyncFnMut` / `AsyncFnOnce` — they can
borrow from their environment across await points, which pre-2024
`|x| async move { ... }` could not.

**Let chains** (1.88, edition 2024 only):
```rust
if let Some(user) = session.user()
    && user.is_admin()
    && let Ok(audit) = load_audit(user.id)
{
    apply(audit);
}
```
Bindings introduced earlier in the chain are visible later. Works in `while`
too. As of 1.95, `if let` guards also work inside `match` arms.

**`&raw const` / `&raw mut`** (1.82, hard-required in 2024 for unaligned/uninit):
```rust
let p: *const u32 = &raw const GLOBAL;   // no intermediate reference
```
Use this instead of `&x as *const _` whenever `x` may be uninitialized,
packed, or you want to take an address to a `mut` static without triggering
the new 2024 unsafe-op-in-unsafe-fn lint.

**Stricter unsafe** (2024): every unsafe op inside an `unsafe fn` now needs
its own `unsafe { }` block. Keep the blocks tight — one line each.

**`expect` lint level with a reason** (1.81):
```rust
#[expect(dead_code, reason = "used by cfg(test) harness only")]
fn probe() {}
```
Prefer `expect` over `allow` — you get warned when the lint stops firing, so
the suppression gets cleaned up automatically.

**`LazyCell` / `LazyLock`** (1.80) — drop `once_cell` and `lazy_static`:
```rust
use std::sync::LazyLock;
static REGEX: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"\bfoo\b").unwrap());
```

**Naked functions** (1.88):
```rust
#[unsafe(naked)]
extern "C" fn trampoline() {
    core::arch::naked_asm!("ret");
}
```
Replaces the `naked_function` crate. Prologue/epilogue suppressed; body must
be a single `naked_asm!`.

**`cfg_select!`** (1.95) — replaces the `cfg-if` crate with a built-in:
```rust
cfg_select! {
    unix => { fn platform() -> &'static str { "unix" } }
    windows => { fn platform() -> &'static str { "windows" } }
    _ => { fn platform() -> &'static str { "other" } }
}
```

**`core::hint::cold_path()`** (1.95) — annotate unlikely branches for codegen
without polluting the API with `#[cold]` functions.

**Advisory file locking** (1.89):
```rust
let f = std::fs::File::options().read(true).write(true).open("lock")?;
f.lock()?;              // blocking exclusive
// f.lock_shared()?;    // blocking shared
// f.try_lock()?;       // non-blocking variant
f.unlock()?;
```
No more pulling `fs2` or `fd-lock` for this.

**Strict integer arithmetic** (1.91) — `i32::strict_add`, `strict_sub`, etc.
Panic on overflow in *all* build modes (release too), unlike `checked_*` which
returns `Option`, or plain `+` which wraps in release.

**Other QoL**:
- `Vec::pop_if` (1.86), `Vec::extract_if` / `HashMap::extract_if` (1.87/1.88),
  `BTreeMap::extract_if` (1.91).
- `Vec::push_mut` / `Vec::insert_mut` (1.95) return a `&mut T` to the inserted
  element — no post-hoc `last_mut().unwrap()`.
- Inline const blocks: `const { assert!(size_of::<T>() <= 64) }` (1.79).
- Exclusive range patterns: `match i { 0..10 => .., _ => .. }` (1.80).
- `Future` and `IntoFuture` are in the prelude in 2024.
- Trait object upcasting is implicit (1.86): `dyn SubTrait -> dyn SuperTrait`
  coerces without a method call.
- `target_feature` on safe fns (1.86, `target_feature_11`).
- `io::pipe()` for anonymous pipes without `nix`/`libc` (1.87).
- `impl Trait` return-position capture: in 2024, `impl Trait` captures *all*
  in-scope generic params by default. Use `impl Trait + use<>` to narrow.
- `cargo info <crate>` (1.82), automatic cache cleanup (1.88),
  `cargo publish --workspace` (1.90).
- `AtomicBool::update` / `AtomicUsize::update` (1.95) — CAS loop on a closure.
- `bool: TryFrom<{integer}>` (1.95) — `true`/`false` from `0`/`1` only, error
  otherwise.

### 1.3 Defaults that changed — watch out

- Dereferencing a null raw pointer is still UB, but 1.86 added a debug-mode
  runtime check that turns it into a panic when detected. Release semantics
  are unchanged — don't rely on the panic.
- `unwinding` across an `extern "C"` boundary now aborts (1.81).
- Apple ARM is tier 1; Apple Intel (`x86_64-apple-darwin`) was demoted to tier
  2 between 1.89 and 1.90.
- `lld` is the default linker on `x86_64-unknown-linux-gnu` since 1.90. If
  your build script relies on `ld.bfd` or `gold` quirks, set
  `RUSTFLAGS="-C link-arg=-fuse-ld=bfd"`.

---

## 2. tokio (1.52 current, 1.51 LTS)

LTS branches: 1.47.x (until Sep 2026, MSRV 1.70) and 1.51.x (until Mar 2027,
MSRV 1.71). Current line (1.52.x) is MSRV 1.71. Pin to an LTS for libraries;
follow `1` for apps.

```toml
tokio = { version = "1", features = ["full"] }
# or minimize:
tokio = { version = "1", features = ["rt-multi-thread", "macros", "net", "fs", "time", "signal"] }
```

### 2.1 Entry point

```rust
#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> eyre::Result<()> {
    tracing_subscriber::fmt::init();
    run().await
}
```
Use `flavor = "current_thread"` for tests, CLIs, and anything that shouldn't
spin up a thread pool.

### 2.2 Structured concurrency patterns

Prefer `JoinSet` over loose `tokio::spawn` when the set of tasks has a bounded
lifetime — it cancels children on drop:
```rust
use tokio::task::JoinSet;

let mut set = JoinSet::new();
for url in urls {
    set.spawn(async move { fetch(url).await });
}
while let Some(res) = set.join_next().await {
    handle(res??);
}
```

`tokio::select!` for races, with `biased;` when you want priority ordering
rather than a random poll:
```rust
tokio::select! {
    biased;
    _ = shutdown.changed() => break,
    msg = rx.recv() => handle(msg?),
}
```

Cancellation: `tokio_util::sync::CancellationToken` is the de-facto pattern.
Pass a child token into each task; call `.cancel()` on the parent to fan it
out. Don't hand-roll this with `AtomicBool`.

### 2.3 Channels — pick the right one

| Need | Channel |
| --- | --- |
| single producer → single consumer | `tokio::sync::oneshot` |
| many producers → single consumer (bounded, backpressure) | `mpsc::channel(N)` |
| fan-out broadcast, latest-N kept | `broadcast::channel(N)` |
| latest-value-only, lossy | `watch::channel` |

### 2.4 Newer sync + runtime bits

- `tokio::sync::SetOnce` (1.47) — async equivalent of `std::sync::OnceLock`.
  Use when the initializer itself needs to `await`.
- `tokio::runtime::LocalRuntime` (1.51) — single-threaded runtime that accepts
  `!Send` futures at the top level without a `LocalSet`. Nicer than
  `Runtime::block_on(local_set.run_until(...))` for `!Send` app roots.
- `biased` also works in `join!` and `try_join!` since 1.46 — same semantics
  as in `select!`.
- `JoinSet::join_all()` (1.40) — awaits all tasks and returns a
  `Vec<Result<_>>`.

### 2.5 Gotchas

- `from_std` on sockets now **panics** on a blocking socket (1.44) — always
  call `set_nonblocking(true)` first. This was a silent hang source for years.
- Don't call blocking stdlib I/O inside async. Wrap in `tokio::task::spawn_blocking`
  or use `tokio::fs`.
- A `broadcast::Receiver` that doesn't keep up gets `RecvError::Lagged` — don't
  propagate it as a fatal error, it's expected under load.
- `TcpStream::set_linger` / `TcpSocket::set_linger` are **deprecated** (1.49)
  in favor of `set_zero_linger`.

---

## 3. thiserror 2.x (for libraries)

2.0 shipped Nov 2024; current is 2.0.18. Use it for *library* error types you
want callers to pattern-match on.

```toml
thiserror = "2"
```

```rust
use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("config file not found: {path}")]
    NotFound { path: PathBuf },

    #[error("invalid toml at {path}")]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },

    #[error("missing env var `{0}`")]
    MissingEnv(String),

    #[error(transparent)]
    Io(#[from] std::io::Error),
}
```

### 3.1 2.x things to know

- **Direct dependency now required**: any crate that invokes
  `#[derive(thiserror::Error)]` must list `thiserror` in its own `Cargo.toml`
  — you can no longer rely on a re-export from another crate.
- `{r#type}` in format strings is gone; just write `{type}`.
- `no_std` support: `thiserror = { version = "2", default-features = false }`.
- You can use `r#source` as a field name to *opt out* of `Error::source()`
  behavior for a field literally named `source`.
- Infinite-recursion Display impls now emit `unconditional_recursion` warnings.

### 3.2 When not to use it

If your function is "something went wrong and the caller should log and
bail", use `eyre::Result` directly — don't define a single-variant enum.

---

## 4. eyre (for binaries)

```toml
eyre = "0.6"   # current 0.6.12; 1.0 is staged on main (not yet released)
```

**Heads-up for eyre 1.0**: the `WrapErr` trait has been renamed to
`ResultExt` on the main branch; method names (`wrap_err`, `wrap_err_with`)
stay. `eyre::Result` gains a default error-type parameter. No crates.io
release yet — bump carefully when it lands.

### 4.1 Bin setup

```rust
fn main() -> eyre::Result<()> {
    tracing_subscriber::fmt::init();
    real_main()
}
```
`eyre::Result` prints a nicely-formatted chain out of the box when returned
from `main`. Control verbosity with `RUST_BACKTRACE=1` (short) or
`RUST_BACKTRACE=full` (full, with source lines when available).

### 4.2 Idioms

```rust
use eyre::{eyre, Context, Result};

fn load(path: &Path) -> Result<Config> {
    let raw = std::fs::read_to_string(path)
        .wrap_err_with(|| format!("reading {}", path.display()))?;
    let cfg: Config = toml::from_str(&raw).wrap_err("parsing config")?;
    if cfg.version != 2 {
        return Err(eyre!("unsupported config version {}", cfg.version));
    }
    Ok(cfg)
}
```

Rules of thumb:
- `?` propagates. Add `.wrap_err(...)` at *every* boundary where the bare
  source error wouldn't tell the user where it happened.
- Don't `map_err` to a string — you'll lose the backtrace chain. Use
  `wrap_err` / `wrap_err_with`.
- `eyre!("...")` is for *new* errors. `bail!("...")` is `return Err(eyre!(..))`.
- `ensure!(cond, "...")` is the `?`-style version of `assert!`.

### 4.3 Mixing with `thiserror`

Libraries return `Result<_, MyError>`; binaries convert once at the top:
```rust
let cfg = config::load(&path)?;   // ConfigError auto-converts to eyre::Report
```

---

## 5. serde (1.0.228)

The big 2025 change was the **`serde_core`** split (1.0.220, Sep 2025):
data-format crates can depend on core traits without waiting for
`serde_derive` to compile, improving parallel build times. For most apps you
don't need to do anything — just use `serde` as before. If you're writing a
*format* crate, depend on `serde_core` directly.

```toml
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

### 5.1 Idiomatic derives

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct Config {
    pub name: String,

    #[serde(default = "default_port")]
    pub port: u16,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

fn default_port() -> u16 { 8080 }
```

### 5.2 Tagged enums (MCP/JSON-RPC territory)

```rust
#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Started { at: i64 },
    Progress { done: u64, total: u64 },
    Finished,
}
```
Variants: `tag = "t"` (internally tagged), `tag, content` (adjacently tagged),
`untagged` (last resort — slow and error-prone).

### 5.3 Watch out

- `deny_unknown_fields` breaks forward compat if you ever add fields — only use
  on types you own end-to-end.
- `#[serde(flatten)]` silently changes the field order and disables
  `deny_unknown_fields` for the flattened struct.

---

## 6. clap v4 (derive API)

Current: 4.6.1 (Apr 2026). 4.6.0 bumped MSRV to Rust 1.85. The derive API is
the default; the builder is for dynamic CLIs.

```toml
clap = { version = "4", features = ["derive", "env", "wrap_help"] }
```

### 6.1 Canonical structure

```rust
use clap::{Args, Parser, Subcommand, ValueEnum};

#[derive(Debug, Parser)]
#[command(name = "myapp", version, about, propagate_version = true)]
pub struct Cli {
    #[command(flatten)]
    pub global: GlobalOpts,

    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(Debug, Args)]
pub struct GlobalOpts {
    /// Increase log verbosity (-v, -vv, -vvv)
    #[arg(long, short, global = true, action = clap::ArgAction::Count)]
    pub verbose: u8,

    /// Output color
    #[arg(long, global = true, value_enum, default_value_t = Color::Auto,
          env = "MYAPP_COLOR")]
    pub color: Color,
}

#[derive(Debug, Subcommand)]
pub enum Cmd {
    /// Build the project
    Build(BuildArgs),
    /// Run tests
    Test {
        #[arg(long)]
        filter: Option<String>,
    },
}

#[derive(Debug, Args)]
pub struct BuildArgs {
    /// Path to the manifest
    #[arg(long, default_value = "Cargo.toml")]
    pub manifest: std::path::PathBuf,

    /// Feature flags to enable
    #[arg(long, value_delimiter = ',')]
    pub features: Vec<String>,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
pub enum Color { Auto, Always, Never }

fn main() -> eyre::Result<()> {
    let cli = Cli::parse();
    // ...
    Ok(())
}
```

### 6.2 Rules that actually matter

- Root should be a `struct` with `#[command(subcommand)]`, **not** an enum —
  you'll want global options later.
- Use `Args` structs for anything more than ~3 fields on a variant. Flatten
  generously.
- `ValueEnum` only works on unit-only enums. For enums with data, parse a
  string and map it yourself.
- Doc comments become `--help` text; add `#[command(long_about = None)]` if
  the doc comment is the full help.
- `env = "..."` reads from environment with CLI override — prefer this over
  manual `std::env::var`.
- `action = clap::ArgAction::Count` for `-vvv` style. `SetTrue` for bare flags.

### 6.3 Recent cosmetic additions (2025)

- `Styles::context` / `Styles::context_value` lets you theme the
  `[default: ...]` / `[possible values: ...]` notes.
- `Command::mut_subcommands` for post-hoc mutation.
- In `--help`, possible values list now appears *before* defaults, matching
  `cargo` and most other tools.
- `StyledStr::push_str` for custom help builders.

---

## 7. indicatif (0.18.x)

```toml
indicatif = "0.18"
```

0.18.0 landed Oct 2025; current is 0.18.4 (Feb 2026). The historical big
change worth remembering: `MultiProgress::join()` was removed; drawing is
driven by child `ProgressBar` updates. You no longer need a joining thread.
0.18 also respects `NO_COLOR` and `TERM=dumb`; MSRV is 1.71.

### 7.1 Single progress bar

```rust
use indicatif::{ProgressBar, ProgressStyle};
use std::time::Duration;

let pb = ProgressBar::new(total);
pb.set_style(
    ProgressStyle::with_template(
        "{spinner:.green} [{elapsed_precise}] [{bar:40.cyan/blue}] {pos}/{len} {msg}"
    )?
    .progress_chars("█▉▊▋▌▍▎▏ ")
);
pb.enable_steady_tick(Duration::from_millis(100));

for item in items {
    pb.set_message(format!("processing {item}"));
    do_work(&item);
    pb.inc(1);
}
pb.finish_with_message("done");
```

### 7.2 MultiProgress + logging

Mixing `println!`/`log` output with live progress bars garbles the terminal.
Use `MultiProgress::println` or the `indicatif-log-bridge` crate:

```rust
use indicatif::MultiProgress;
use indicatif_log_bridge::LogWrapper;

let logger = env_logger::builder().build();
let multi = MultiProgress::new();
LogWrapper::new(multi.clone(), logger).try_init()?;

let pb1 = multi.add(ProgressBar::new(100));
let pb2 = multi.add(ProgressBar::new(200));
// bars and log lines no longer collide
```

For `tracing` users, `tracing-indicatif` plays the same role.

### 7.3 Tips

- Iterator shortcut: `items.iter().progress_count(n)` / `.progress()`.
- For tasks with unknown size, use `ProgressBar::new_spinner()`.
- `ProgressBar::wrap_read` / `wrap_write` wraps any `Read`/`Write` to report
  byte-level progress transparently.
- Features: `improved_unicode` for better bar glyph selection, `tokio` for
  async wrappers.

---

## 8. tracing + tracing-subscriber

Current: `tracing = "0.1.44"` (Dec 2025), `tracing-subscriber = "0.3.23"`
(Mar 2026). MSRV 1.65. This is the modern default for application-level
diagnostics; `log` is the older facade.

```toml
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "fmt"] }
```

### 8.1 Minimal init

```rust
use tracing_subscriber::{EnvFilter, fmt};

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()   // RUST_LOG
        .unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).with_target(false).init();
}
```

### 8.2 Layered setup (the grown-up version)

```rust
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, fmt};

tracing_subscriber::registry()
    .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
    .with(fmt::layer().with_target(false).with_line_number(true))
    // .with(tracing_opentelemetry::layer().with_tracer(tracer))
    // .with(ErrorLayer::default())   // from tracing-error, for eyre spantrace
    .init();
```

### 8.3 Instrumentation

```rust
use tracing::{info, warn, instrument};

#[instrument(skip(db), fields(user_id = %req.user_id))]
async fn handle(req: Request, db: &Db) -> eyre::Result<Response> {
    info!(path = %req.path, "handling request");
    let row = db.lookup(req.user_id).await?;
    if row.is_stale() {
        warn!("stale row served");
    }
    Ok(row.into())
}
```
Rules:
- `%` = Display, `?` = Debug, bare = type must impl `Value`.
- Always `skip` things that would print huge (DB handles, full request bodies,
  secrets). Use `skip_all` then add explicit `fields(...)` for the bits you want.
- Log at span *creation* for structured context; inside the body for events.

### 8.4 env-filter syntax

```
RUST_LOG=info,myapp=debug,hyper=warn,sqlx::query=off
RUST_LOG="info,myapp[{user_id=42}]=trace"     # per-field filter
```

### 8.5 Observability add-ons worth pairing

- **`tracing-error::ErrorLayer`** — installs a layer so that `eyre::Report`
  captures a `SpanTrace` alongside the backtrace. Errors then print the span
  context (which handler, which request, etc.) they occurred in. Minimal
  cost, huge payoff when errors show up in logs.
  ```rust
  use tracing_error::ErrorLayer;
  tracing_subscriber::registry()
      .with(EnvFilter::from_default_env())
      .with(fmt::layer())
      .with(ErrorLayer::default())
      .init();
  ```
- **`tokio-console`** — live task/resource inspector. Add the `console`
  subscriber layer and run `tokio-console` against it to see per-task poll
  times, stuck tasks, resource waits. Requires `RUSTFLAGS="--cfg
  tokio_unstable"` on the app being inspected (intentionally not pulling this
  into §2 since it's diagnostic-only).

### 8.6 Things from the last year

- `with_span_events(FmtSpan::CLOSE)` on the fmt layer builder gives you
  span-exit events including busy/idle duration — usually what you actually
  want from span logging.
- 0.3.21 (Nov 2025) removed a `clone_span` call in the fmt layer's enter
  path, a measurable hot-path win.

---

## 9. log + env_logger (still fine for small tools)

```toml
log = "0.4"            # current 0.4.29 (Dec 2025)
env_logger = "0.11"    # current 0.11.10 (Mar 2026)
```

### 9.1 When to pick this over tracing

- Single-threaded, non-async CLI.
- You don't need spans, structured fields, or multiple subscribers.
- You want one line of setup and zero ceremony.

If any of those are false, use `tracing` instead — it can consume `log` events
anyway via the `tracing-log` crate.

### 9.2 Setup

```rust
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .format_target(false)
        .init();

    log::info!("starting");
    log::debug!(target: "net", "connecting to {addr}");
}
```

```
RUST_LOG=info,myapp::net=debug ./myapp
RUST_LOG_STYLE=never ./myapp      # disable color
```

### 9.3 Structured logging (the `kv` feature)

`log` 0.4.21+ and `env_logger` 0.11.8+ support key-value pairs (stabilized
under the `kv` feature — previously `unstable-kv`). The syntax uses a
semicolon to separate structured values from the message, and `name:adapter`
pairs for values — it does **not** use tracing's `%`/`?` sigils:
```rust
log::info!(target: "net", user_id = 42, path:? = req.path; "request");
log::warn!(e:err; "lookup failed");
```
Nowhere near as capable as `tracing` spans, but enough for small tools.

### 9.4 env_logger specifics

- Default features are `auto-color`, `humantime`, `regex`. Opt into `kv`
  explicitly. `color` is a transitive of `auto-color` — don't list it
  separately.
- Uses `anstream` for Windows color compatibility — no extra setup.
- As of 0.11.7 (Mar 2025), the `humantime` feature is internally backed by
  `jiff` (faster than chrono, DST-safe). No separate opt-in — enabling
  `humantime` pulls it in.
- **Never log untrusted input unsanitized** — ANSI escape sequences in log
  messages are forwarded to the terminal verbatim. Strip or escape them.

---

## 10. Async in traits

Stable since 1.75 (Dec 2023). Three options, in order of preference:

### 10.1 Plain `async fn` in a trait (static dispatch)

```rust
pub trait Fetcher {
    async fn fetch(&self, url: &str) -> eyre::Result<Vec<u8>>;
}

pub struct Http(reqwest::Client);
impl Fetcher for Http {
    async fn fetch(&self, url: &str) -> eyre::Result<Vec<u8>> {
        Ok(self.0.get(url).send().await?.bytes().await?.into())
    }
}
```
No macros, no allocation per call. This is the right default.

### 10.2 Multi-threaded runtimes: `trait_variant`

Native `async fn` in a trait produces a future whose `Send`-ness is inferred
from the impl. If you need `impl Fetcher` to be usable across `tokio::spawn`
(which requires `Send`), use `trait-variant` to generate a `Send`-bounded
sibling trait:

```rust
#[trait_variant::make(Fetcher: Send)]
pub trait LocalFetcher {
    async fn fetch(&self, url: &str) -> eyre::Result<Vec<u8>>;
}
```
This generates `Fetcher` (with `Send` bounds on async/RPITIT methods) and
keeps the original `LocalFetcher` available for `!Send` callers. The
attribute takes `NewName: Bound` — it creates a sibling, it does not mutate
the annotated trait.

### 10.3 Dynamic dispatch: still `#[async_trait]`

`dyn Trait` with `async fn` is **not** stable yet. If you need
`Box<dyn Fetcher>` or a `Vec<Arc<dyn Fetcher>>`, reach for `async-trait`:

```rust
#[async_trait::async_trait]
pub trait Fetcher {
    async fn fetch(&self, url: &str) -> eyre::Result<Vec<u8>>;
}
```
It rewrites each method to return `Pin<Box<dyn Future + Send + '_>>`. One
allocation per call; use `#[async_trait(?Send)]` for non-`Send` futures.
Watch the ecosystem — stable `dyn async fn` support is being designed.

### 10.4 Return-position `impl Trait` in traits (RPITIT)

For non-async return types you also have `-> impl Trait`:
```rust
pub trait Index {
    fn iter(&self) -> impl Iterator<Item = &str>;
}
```
Same dyn-compat caveat: RPITIT methods make the trait non-`dyn`.

---

## 11. Idioms & patterns

### 11.1 Newtype

```rust
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct UserId(pub u64);
```
Use for domain IDs, units (`Miles(f64)`), and anything where mixing two
values of the same primitive would be a bug. Don't implement `Deref` unless
the newtype's job is to *add* capabilities while preserving the full inner
surface — otherwise you defeat the point.

### 11.2 `#[non_exhaustive]`

```rust
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum ApiError {
    #[error("rate limited")]
    RateLimited,
    #[error("upstream: {0}")]
    Upstream(#[from] reqwest::Error),
}
```
Forces downstream `match` sites to have a wildcard arm, so adding a variant
later isn't a breaking change. On structs, prevents external construction and
exhaustive field destructuring. Primarily for public error types and
config/option structs in libraries.

### 11.3 Sealed traits (private-supertrait form)

When a public trait should only be implemented inside your crate:

```rust
pub trait Message: sealed::Sealed {
    fn kind(&self) -> &'static str;
}

impl Message for Request  { fn kind(&self) -> &'static str { "req" } }
impl Message for Response { fn kind(&self) -> &'static str { "res" } }

mod sealed {
    pub trait Sealed {}
    impl Sealed for super::Request {}
    impl Sealed for super::Response {}
}
```
Now you can add methods to `Message` without breaking callers (they can't
have implementations for you to break). Document the seal in the doc comment
— rustdoc still doesn't mark it visually.

### 11.4 Extension traits (`FooExt`)

Adding methods to a foreign type:
```rust
pub trait PathExt {
    fn is_hidden(&self) -> bool;
}
impl PathExt for std::path::Path {
    fn is_hidden(&self) -> bool {
        self.file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.starts_with('.'))
    }
}
```
Convention (RFC 445): name it `FooExt` where `Foo` is the extended type.
Export it from your crate's `prelude` module so consumers can glob-import.

### 11.5 `#[must_use]`

```rust
#[must_use = "builder does nothing until .build() is called"]
pub struct RequestBuilder { /* ... */ }

#[must_use]
pub fn parse(input: &str) -> Result<Ast, ParseError> { /* ... */ }
```
Put it on builders, `Result`-shaped returns that could silently be dropped,
and futures-returning functions that aren't called `.await`. Free compile-time
help for your users.

### 11.6 Signatures: borrow, don't own

Prefer `impl AsRef<Path>` / `impl AsRef<str>` / `impl Into<T>` over concrete
types in function signatures:
```rust
pub fn read(path: impl AsRef<Path>) -> io::Result<String> { /* ... */ }
pub fn new(name: impl Into<String>) -> Self { Self { name: name.into() } }
```
For iterator inputs prefer `impl IntoIterator<Item = T>` over `Vec<T>` or
`&[T]` — callers can pass whatever shape they already have. For iterator
outputs prefer `-> impl Iterator<Item = T>` — cheaper than collecting, and
the concrete type stays an implementation detail.

### 11.7 Typestate builders via `bon`

`bon` turns required-field enforcement into a compile-time error with one
attribute. No hand-rolled `HasName`/`NoName` phantom types:

```rust
use bon::Builder;

#[derive(Builder)]
pub struct Request {
    url: String,              // required — forgetting this won't compile
    method: http::Method,     // required
    #[builder(default)]
    timeout: Option<Duration>,
    #[builder(default = 3)]
    retries: u32,
}

let req = Request::builder()
    .url("https://example.com")
    .method(http::Method::GET)
    .build();   // compile error if you omit .url() or .method()
```
`#[builder]` also works on free functions and methods — turns positional args
into named ones and gives you partial application. Use it wherever you have
more than ~3 args or any optional args.

---

## 12. Adjacent crates worth knowing

One-line rationales. All actively maintained as of April 2026 unless noted.

**Building & errors**
- [`bon`](https://crates.io/crates/bon) — builder/named-arg proc macro; supersedes `derive_builder`/`typed-builder` for new code.
- [`trait-variant`](https://crates.io/crates/trait-variant) — `Send`-bounded sibling traits for native async-fn-in-traits.
- [`async-trait`](https://crates.io/crates/async-trait) — still needed for `dyn Trait` with async methods.

**Concurrency & data**
- [`bytes`](https://crates.io/crates/bytes) — reference-counted, zero-copy byte buffers. The standard in the tokio/hyper/axum world.
- [`arc-swap`](https://crates.io/crates/arc-swap) — atomic `Arc<T>` swap for read-mostly shared config/state.
- [`parking_lot`](https://crates.io/crates/parking_lot) — smaller/faster locks with eventual fairness, plus reentrant and deadlock-detection variants. `std::sync::Mutex` is fine (sometimes slightly faster) for short, low-contention critical sections, but `parking_lot` still dominates under contention or when you need fair scheduling — recent benchmarks show up to 49× better tail-latency fairness under heavy contention. MSRV 1.84.

**Dates & time**
- [`jiff`](https://crates.io/crates/jiff) — BurntSushi's modern datetime crate. Handles TZ/DST correctly, nicer API than `chrono`. Still pre-1.0 (0.2.x) but actively developed and already widely adopted (env_logger uses it internally). Prefer for new code.
- [`chrono`](https://crates.io/crates/chrono) / [`time`](https://crates.io/crates/time) — still actively maintained and fine if you're already on them.

**Testing**
- [`cargo-nextest`](https://crates.io/crates/cargo-nextest) — faster, cleaner test runner. De facto default in 2025+.
- [`insta`](https://crates.io/crates/insta) — snapshot testing. Pair with `cargo insta review` for a TUI accept/reject flow.
- [`proptest`](https://crates.io/crates/proptest) — property-based testing.
- [`criterion`](https://crates.io/crates/criterion) — statistical microbenchmarks. Needed more now that `#[bench]` is fully de-stabilized (1.88).

**Cargo hygiene** (run all three in CI)
- [`cargo-deny`](https://crates.io/crates/cargo-deny) — license/duplicate/advisory checks.
- [`cargo-audit`](https://crates.io/crates/cargo-audit) — RustSec advisory scan.
- [`cargo-machete`](https://crates.io/crates/cargo-machete) — find unused dependencies.

**Zero-copy / binary**
- `serde(borrow)` — borrowed deserialization of `&str` / `&[u8]` from
  `serde_json` and friends. Avoids allocation for transient fields.
- [`zerocopy`](https://crates.io/crates/zerocopy) — safe transmute between bytes and POD types. Common in networking/parsing.
- [`rkyv`](https://crates.io/crates/rkyv) — archive format you can mmap and read without deserializing.

---

## 13. Putting it together — a starter `main.rs`

```rust
use clap::Parser;
use eyre::{Context, Result};
use tracing::{info, instrument};

#[derive(Parser, Debug)]
#[command(name = "myapp", version)]
struct Cli {
    #[arg(long, short, action = clap::ArgAction::Count)]
    verbose: u8,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug)]
enum Cmd {
    Run { path: std::path::PathBuf },
}

fn install_tracing(verbosity: u8) {
    use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};
    let default = match verbosity {
        0 => "info",
        1 => "debug",
        _ => "trace",
    };
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(default));
    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().with_target(false))
        .init();
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    install_tracing(cli.verbose);
    info!(?cli, "starting");
    match cli.cmd {
        Cmd::Run { path } => run(&path).await,
    }
}

#[instrument]
async fn run(path: &std::path::Path) -> Result<()> {
    let body = tokio::fs::read_to_string(path).await
        .wrap_err_with(|| format!("reading {}", path.display()))?;
    info!(bytes = body.len(), "read file");
    Ok(())
}
```

Cargo.toml for the above:
```toml
[package]
edition = "2024"
rust-version = "1.85"

[dependencies]
clap = { version = "4", features = ["derive"] }
eyre = "0.6"
tokio = { version = "1", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
```

---

## Sources

- [Rust 1.85 announcement (Edition 2024)](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)
- [Rust 1.88 announcement (let chains, naked fns, cache GC)](https://blog.rust-lang.org/2025/06/26/Rust-1.88.0/)
- [Rust 1.89 announcement](https://blog.rust-lang.org/2025/08/07/Rust-1.89.0/)
- [Rust 1.95 announcement](https://blog.rust-lang.org/2026/04/16/Rust-1.95.0/)
- [Rust release notes (beta)](https://doc.rust-lang.org/beta/releases.html)
- [ncameron — recent Rust changes](https://www.ncameron.org/blog/recent-rust-changes/)
- [Tokio CHANGELOG](https://github.com/tokio-rs/tokio/blob/master/tokio/CHANGELOG.md)
- [Axum 0.8 announcement](https://tokio.rs/blog/2025-01-01-announcing-axum-0-8-0)
- [thiserror 2.0.0 release](https://github.com/dtolnay/thiserror/releases/tag/2.0.0)
- [thiserror on docs.rs](https://docs.rs/crate/thiserror/latest)
- [eyre on docs.rs](https://docs.rs/eyre/latest/eyre/)
- [eyre-rs org](https://github.com/eyre-rs)
- [serde releases](https://github.com/serde-rs/serde/releases)
- [serde on docs.rs](https://docs.rs/crate/serde/latest)
- [clap releases](https://github.com/clap-rs/clap/releases)
- [clap derive tutorial](https://docs.rs/clap/latest/clap/_derive/_tutorial/index.html)
- [clap git-derive example](https://github.com/clap-rs/clap/blob/master/examples/git-derive.rs)
- [Rain's CLI recommendations](https://rust-cli-recommendations.sunshowers.io/handling-arguments.html)
- [indicatif releases](https://github.com/console-rs/indicatif/releases)
- [indicatif-log-bridge](https://github.com/djugei/indicatif-log-bridge)
- [tracing-subscriber CHANGELOG](https://docs.rs/crate/tracing-subscriber/latest/source/CHANGELOG.md)
- [tracing on GitHub](https://github.com/tokio-rs/tracing)
- [env_logger on crates.io](https://crates.io/crates/env_logger)
- [log on crates.io](https://crates.io/crates/log)
