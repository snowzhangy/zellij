# Repository Guidelines

## Project Structure & Module Organization

Zellij is a Rust workspace. The root crate in `src/` provides the main binary, CLI wiring, and integration tests under `src/tests/`. Core runtime code is split into `zellij-client/`, `zellij-server/`, `zellij-utils/`, `zellij-tile/`, and `zellij-tile-utils/`. Built-in WASM plugins live in `default-plugins/`. Shared assets are in `assets/`, documentation in `docs/`, examples in `example/`, packaging files in `wix/`, and repository automation in `xtask/`.

## Build, Test, and Development Commands

Use the pinned Rust toolchain from `rust-toolchain.toml`. Install `protoc`; tests also need `pkg-config` and OpenSSL.

- `cargo xtask` formats, builds, tests, and runs clippy.
- `cargo xtask build` builds the workspace.
- `cargo xtask test` runs the standard test suite.
- `cargo xtask clippy` runs clippy checks.
- `cargo xtask run -- [args]` runs Zellij locally; for example `cargo xtask run -l strider`.
- `cargo xtask manpage` regenerates the manpage from `docs/MANPAGE.md`.

`cargo x ...` is accepted as shorthand for `cargo xtask ...`.

## Coding Style & Naming Conventions

Follow Rust 2021 idioms and keep code formatted with `cargo fmt`. The repository uses 4-space indentation, LF endings, UTF-8, final newlines, and trimmed trailing whitespace via `.editorconfig`; YAML files use 2 spaces. Rustfmt is configured with `match_block_trailing_comma = true`. Prefer descriptive `snake_case` for functions, modules, and variables, `PascalCase` for types, and established crate-local naming patterns.

## Testing Guidelines

Place unit tests near the code they exercise and integration or CLI tests under `src/tests/`. End-to-end tests use Docker or Podman plus snapshots in `src/tests/e2e/snapshots/`: start services with `docker compose up -d`, build with `cargo xtask ci e2e --build`, then run `cargo xtask ci e2e --test`. Update snapshots only when the terminal output change is intentional and review the diff carefully.

## Commit & Pull Request Guidelines

Recent history uses short imperative subjects, often with Conventional Commit prefixes such as `fix:` or scopes like `fix(windows):`. For larger or user-visible changes, follow Conventional Commits. Pull requests should include a clear title, a focused description, linked issues when relevant, and notes about tests run. Discuss non-trivial work with maintainers first, as described in `CONTRIBUTING.md`.

## Agent-Specific Notes

Do not revert unrelated local changes. Keep edits scoped to the affected crate or plugin, prefer existing helpers over new abstractions, and run the narrowest useful `cargo xtask` or `cargo test` command before handing off.
