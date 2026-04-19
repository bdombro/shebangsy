# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog][keep-a-changelog],
and this project adheres to [Semantic Versioning][semver].

## [Unreleased]

### Added


## [2.0.0] - 2026-04-19

### Added

- `#!version:` directive: parsed for all language backends; currently consumed only by Mojo, where it sets the pixi version constraint for the `mojo` dependency (default: `>=0.26.0,<0.27`).
- C++ `#!requires:` supports **`github:`** (CMake FetchContent), **`vcpkg:`** (manifest + toolchain; optional vcpkg bootstrap), and **`conan:`** (Conan + CMake toolchain). Bare package names are rejected.
- Docs: `docs/language-reference.md`, `docs/contributing.md`, `docs/adding-a-language.md`; Cursor rules `.cursor/rules/languages.mdc` and expanded `.cursor/rules/code.mdc` (language backends + error messages).
- `scripts/test-smoke.sh`: warn on stderr when one or more languages are skipped (missing toolchain); Rust smoke uses the `rust` runner token (not the `rs` alias) for `ext_ready` / `lang_for_ext`.

### Changed

- Docs: `docs/language-reference.md` clarifies directive stripping for most backends versus Mojo full-source staging; `docs/adding-a-language.md` backend contract mentions `#!version:` / `FrontmatterDirectives.version`; `.cursor/rules/code.mdc` requires documenting `#!version:` consumption per backend.
- `src/languages/mojo.nim`: mermaid diagram labels front-matter parsing (`parseDirectives`).
- Docs: restructured `docs/language-reference.md` (intro, quick-reference table, shared **Directives** section, **By language** template, Swift workspace callout); `docs/contributing.md` now leads with build/test and adds an architecture preamble; `docs/adding-a-language.md` expands the checklist and backend-contract rationale.
- Docs: copy edits in `docs/language-reference.md`, `docs/contributing.md`, and `docs/adding-a-language.md` (README cache links, Swift quick-reference row, wording and punctuation).
- `src/languages/mojo.nim`: Modular channel URL extracted to `mojoCondaChannel` constant; dead POSIX bindings (`posixOpen`, `flock`, `posixClose`, `LOCK_EX`) removed.
- Python: when **`uv`** is on `PATH`, venv creation and `#!requires:` installs use **`uv`** (batched `uv pip install`); otherwise **`python3 -m venv`** + **`pip`** with a single batched install.
- Swift `#!requires:` no longer supports bare package names or URL-based implicit products; every token must include `:ProductName` after the version (e.g. `apple/swift-argument-parser@1.3.0:ArgumentParser` or `https://github.com/mxcl/PromiseKit.git@6.5.0:PromiseKit`).
- README trimmed; language reference, contributing, editor tips, and benchmark “how to run” moved under `docs/` with cross-links.
- `src/shebangsy.nim`: comment clarifying why `cacheCompileLockAcquire` is not paired with release on the compiled warm path (execv vs interpreted spawn).
- README: Nim shadowing / module-name example now links `examples/nim/cli-argsbarg.nim` instead of `greet_demo.nim`.
- `scripts/test-smoke.sh`: skip summary warning counts **examples**, not distinct languages.
- Docs: README “How it works” states that mtime-only invalidation includes `touch`; contributing cache model notes `cacheSameScriptStaleRemove` and exec vs spawn.

### Removed

- Swift example `examples/swift/file-cli.swift`.
- Nim example `examples/nim/greet_demo.nim` (use `cli-argsbarg.nim`).

### Fixed

- `src/languages/mojo.nim`: scripts with `#!requires:` PyPI deps now exec via `pixi run mojo run` at runtime so Python interop packages are available; direct `execv` is used when no PyPI deps are present.
- Python: `toolEnsureOnPath` messages for missing `uv` / `python3` use the `[shebangsy:python3]` prefix.
- Python: after a failed batched install, retry recreates the venv and reinstalls **every** `#!requires:` spec (previously only the failing spec was reinstalled).
- `scripts/test-smoke.sh`: `ext_ready` used a `py` case while `lang_for_ext` returned `python3`, so Python examples were always treated as skipped.
- `src/languages/nim.nim`: stderr messages now use `[shebangsy:nim]` instead of `[nimr]`.
- `src/languages/go.nim`: missing `go` on `PATH` uses `toolEnsureOnPath` with an install hint (`https://go.dev/dl/`).
- `src/languages/cpp.nim`: `cmake --build` passes `--config Release` so multi-config generators (e.g. Xcode) build Release, not Debug.

## [1.0.1] - 2026-04-19

### Added

- GitHub Actions workflow (`.github/workflows/ci.yml`) running `./scripts/test.sh` on push and PR to `main`, with Nim, Go, and Swift toolchains installed (Mojo skipped in CI).
- CI workflow: concurrency cancel-in-progress, named steps, Nimble package cache (`actions/cache`), and Go module cache when a `go.sum` is present (`actions/setup-go`).
- Everything!

[Unreleased]: https://github.com/bdombro/shebangsy/compare/2.0.0...HEAD
[2.0.0]: https://github.com/bdombro/shebangsy/compare/1.0.1...2.0.0
[1.0.1]: https://github.com/bdombro/shebangsy/compare/1.0.0...1.0.1
[keep-a-changelog]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html
