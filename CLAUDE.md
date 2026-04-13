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

- **Entry point**: `src/main.zig` — wires CLI parsing to command handlers (`runAdd`, `runEdit`, `runDel`, `runList`, `runUse`, `runInstall`, `runUpdate`). Also contains interactive input helpers and the version constant.
- **`src/cli.zig`** — Argument parsing. Produces a `Config` struct with a `Command` tagged union. No external arg-parsing library.
- **`src/app.zig`** — Compile-time constants: app name, config paths, GitHub repo URL, default models per tool type.
- **`src/sites.zig`** — `SitesStore` (fixed-capacity array of up to 64 sites), JSON load/save for `~/.velora/sites.json`. Manual JSON parsing (no std.json). Per-site multi-tool defaults (`default_tools_mask`), per-tool model overrides (`models_cx`/`cc`/`oc`/`nb`/`ow`), selection mode, and settings management.
- **`src/apply.zig`** — Writes site configs to target tool config files: Codex TOML (`~/.codex/config.toml`), Claude Code JSON (`~/.claude/settings.json`), OpenCode JSON (`~/.config/opencode/opencode.json`), Nanobot JSON (`~/.nanobot/config.json`), OpenClaw JSON (`~/.openclaw/openclaw.json`). Line-by-line text manipulation.
- **`src/check.zig`** — HTTP connectivity checks, model detection, model family classification, compatibility checks, and model call testing for sites. Uses heap-allocated refcounted contexts for thread+timeout patterns to avoid use-after-free on detached threads.
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

Minimum Zig version: **0.15.1** (specified in `build.zig.zon`).
