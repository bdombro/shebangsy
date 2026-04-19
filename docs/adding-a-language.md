# Adding a language

Use this checklist when you want shebangsy to run scripts in a new language. It ties together the Nim runner, tests, examples, and user-facing docs.

## Checklist

1. Create `src/languages/yourlang.nim` with `createRunner()`.
2. Import it and add to `registryAll()` in `src/languages_registry.nim`.
3. Add `ext_ready` + `lang_for_ext` cases in `scripts/test-smoke.sh`. `lang_for_ext` must echo the **runner key** (e.g. `python3`, not `py`). **`ext_ready` case labels must use those same keys**—it is invoked with the value returned by `lang_for_ext`.
4. Add at least one example under `examples/yourlang/`.
5. Add a language section to [`docs/language-reference.md`](language-reference.md), using the same structure as existing backends (shebang example, **`#!requires:`**, **`#!flags:`**, **`#!version:`** when relevant, then any extra notes).
6. Add a [`CHANGELOG.md`](../CHANGELOG.md) entry.

## Backend contract

Also enforced by Cursor rules (see `.cursor/rules/code.mdc`):

- **`wpExecvCached`** for compiled languages; **`wpSpawnCachedRetryCompile`** for interpreted languages only. Compiled runners replace the process with the cached binary via **`execv`**, so the parent never returns to release a lock. Interpreted runners **`spawn`** a child and must release the compile lock after the child is started (see `src/shebangsy.nim`).
- Use **`cacheShadowDirFromBinary`** for per-script build state; **no shared workspaces** (except where an existing language explicitly documents shared behavior, e.g. SwiftPM). That isolation keeps cache keys and rebuilds predictable and avoids cross-script dependency bleed.
- Prefix every error with **`[shebangsy:<key>]`** (runner key, e.g. `[shebangsy:cpp]`); echo the offending spec or path; use **`toolEnsureOnPath`** for required external binaries. Consistent prefixes make failures easy to grep and attribute to a backend.
- State in the language file’s header whether **`#!flags:`** is forwarded to the build tool or ignored — the [language reference](language-reference.md) must stay accurate for users.
- If the backend uses shared front matter from `languages_common.nim`, state whether **`#!version:`** is consumed (see `FrontmatterDirectives.version`; Mojo uses it today) or ignored.
