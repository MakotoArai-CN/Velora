# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Velora is a multi-site API Key manager written in Zig. It manages and switches API Key configurations for Codex (`cx`), Claude Code (`cc`), OpenCode (`oc`), Nanobot (`nb`), and OpenClaw (`ow`) across their respective config files.

## Build & Test Commands

```bash
zig build                          # Build native (debug)
zig build -Doptimize=ReleaseFast   # Build native (release)
zig build run -- <args>            # Build and run with args
zig build test                     # Run unit tests
```

The build system cross-compiles for 18 targets (Linux, Alpine/musl, Windows, macOS, FreeBSD) in a single `zig build` invocation.

## Architecture

- **Entry point**: `src/main.zig` — wires CLI parsing to command handlers (`runAdd`, `runEdit`, `runDel`, `runList`, `runUse`, `runModels`, `runModelTest`, `runInstall`, `runUpdate`). Also contains interactive input helpers and the version constant. `runList` runs connectivity checks in parallel via heap-allocated `CheckTask` (refcount-2) workers and repaints rows in place. `runModelTest` does the same with `ModelTestTask` workers and a spinner animation. `runEdit` after saving will load `CurrentTools`, match the *old* `base_url`/`api_key` against live tool configs, and auto-reapply the updated site to every matching tool (no separate `use` needed). The match runs against pre-edit values so URL/key changes still find the right tools.
- **`src/cli.zig`** — Argument parsing. Produces a `Config` struct with a `Command` tagged union. No external arg-parsing library. Help is split: `printHelp` shows commands/options + a hint, `printExamples` (invoked via `velora help examples` or `--examples`) shows the full usage examples.
- **`src/app.zig`** — Compile-time constants: app name, config paths, GitHub repo URL, default models per tool type.
- **`src/sites.zig`** — `SitesStore` (fixed-capacity array of up to 64 sites), JSON load/save for `~/.velora/sites.json`. Manual JSON parsing (no std.json). Per-site multi-tool defaults (`default_tools_mask`), per-tool model overrides (`models_cx`/`cc`/`oc`/`nb`/`ow`), selection mode, and settings management.
- **`src/apply.zig`** — Writes site configs to target tool config files: Codex TOML (`~/.codex/config.toml`), Claude Code JSON (`~/.claude/settings.json`), OpenCode JSON (`~/.config/opencode/opencode.json`), Nanobot JSON (`~/.nanobot/config.json`), OpenClaw JSON (`~/.openclaw/openclaw.json`). Line-by-line text manipulation.
- **`src/check.zig`** — HTTP connectivity checks, model detection, model family classification, compatibility checks, model call testing (`testModelCall`), and benchmark POST (`benchmarkModel` returning `BenchResult` with `tokens_per_sec` parsed from `usage.completion_tokens`/`usage.output_tokens`). Uses heap-allocated refcounted contexts for thread+timeout patterns. `checkConnectivityInner` is `pub` so parallel workers can call it directly.
- **`src/current.zig`** — Reads each tool's currently-applied config (Codex TOML proxy section, Claude Code env block, OpenCode/Nanobot/OpenClaw JSON provider sections) and exposes `CurrentTools.matchSite(base_url, api_key)` returning a `u8` bitmask of tools currently pointed at a given site. Match succeeds on either base_url or api_key (handles URL drift while keys stay consistent).
- **`src/env.zig`** — Cross-platform environment variable persistence (writes to shell profile on POSIX, registry on Windows).
- **`src/install.zig`** — Self-install/uninstall to `~/.velora/bin` with PATH management.
- **`src/update.zig`** — GitHub releases API check and self-update.
- **`src/i18n.zig`** — Trilingual support (en/zh/ja) with OS locale detection. `tr()` function takes all three translations inline.
- **`src/output.zig`** — Terminal output formatting with Miku-themed colors.
- **`src/terminal.zig`** — Terminal capability detection (color, unicode, width).
- **`src/config.zig`** — Home directory resolution.

## Key Patterns

- **No heap JSON parser**: Sites JSON and config files are parsed/written with manual string scanning (`std.mem.indexOf`, `splitScalar`). Keep this pattern when modifying.
- **Stack buffers everywhere**: Most formatting uses fixed `[N]u8` buffers with `std.fmt.bufPrint`. Avoid heap allocation for temporary strings.
- **Allocator discipline**: Debug builds use `DebugAllocator`; release builds use `smp_allocator`. CLI args use `page_allocator` to avoid leak reports.
- **i18n inline**: All user-facing strings pass through `i18n.tr(lang, en, zh, ja)`. New strings must include all three languages.
- **Site types**: `SiteType` enum (`cx`, `cc`, `oc`, `nb`, `ow`) drives both CLI subcommands and config file targeting.
- **Thread safety**: Timeout-guarded background operations (model detection, model call testing) use heap-allocated contexts with atomic refcounting. Never put thread context on the stack when `thread.detach()` is possible.
- **Model family classification**: `classifyModelFamily` recognizes `gpt*` (OpenAI), `claude-*` (Anthropic), and `o1`/`o3`/`o4` (OpenAI reasoning). Unknown families are handled gracefully per target tool.
- **Cross-compilation serialization**: `build.zig` chains compile and install steps serially to avoid LLVM OOM when building all 18 cross-targets in parallel.

## Zig Version

Minimum Zig version: **0.16.0** (specified in `build.zig.zon`).

### 0.16 migration notes

The 0.16 "I/O as an Interface" rework moved file I/O, environment variables, process spawning, sleep, and timestamps into the `std.Io` namespace. Velora wraps these in `src/io_compat.zig`, which stores the `init.io` instance passed to `main` and exposes helpers (`readFileIntoList`, `writeFileAll`, `makeDirIfMissing`, `pathExists`, `getEnv`, `selfExePath`, `milliTimestamp`, `sleepNs`, `stdoutWriter`/`stderrWriter`, etc). Most modules call the helpers rather than `std.Io` directly to keep call sites short.

Notable cascading changes:
- `pub fn main` now takes `init: std.process.Init` so Zig 0.16 can hand env vars, args, and the application `Io` explicitly. `main` calls `io_compat.setIo(init.io)` and `io_compat.setEnvironMap(init.environ_map)` once at startup so helpers can resolve I/O and env lookups.
- CLI args come from `init.minimal.args.toSlice(init.arena.allocator())` — `cli.parseArgs` accepts the slice as a parameter rather than fetching it itself.
- `std.io.fixedBufferStream(buf).writer()` → `std.Io.Writer.fixed(buf)`. `getWritten()` → `buffered()`.
- `std.mem.trimRight` / `trimLeft` → `trimEnd` / `trimStart`.
- `std.time.milliTimestamp()` / `std.Thread.sleep(ns)` → `io_compat.milliTimestamp()` / `io_compat.sleepNs(ns)`.
- Windows BOOL became a wrapped enum (`Bool(c_int)`) — comparisons use `.toBool()`.
- `std.process.Child.Term` enum tags lowercased (`.Exited` → `.exited`).
- `std.process.Child.init`/`spawn`/`collectOutput` removed; use `std.process.run(allocator, io, .{ .argv = ... })`.
