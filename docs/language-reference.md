# Language reference

This page documents **`#!` directives** and how each supported language backend interprets them. For install, quick start, and cache location, see the [README](../README.md).

**On this page:** [Directives](#directives) · [By language](#by-language) — [C++](#c) · [Go](#go) · [Mojo](#mojo) · [Nim](#nim) · [Python 3](#python-3) · [Rust](#rust) · [Swift](#swift)

## Quick reference

| Language | `#!requires:` | `#!flags:` | `#!version:` |
| --- | --- | --- | --- |
| C++ | `github:`, `vcpkg:`, or `conan:` tokens (prefixed; bare names rejected) | Passed to **CMake** configure | Not used |
| Go | Module paths (`go get`-style versions) | Appended to **`go build`** | Not used |
| Mojo | PyPI-style package names | Not supported | **Mojo / pixi** constraint (optional) |
| Nim | Comma-separated Nimble packages | Appended to **`nim c`** | Not used |
| Python 3 | PEP 508 / pip-style specs | Ignored | Not used |
| Rust | Crates (comma splitting is bracket-aware for `@features`) | Appended to **`cargo build --release`** | Not used |
| Swift | SwiftPM package refs: **`@version`** plus **`:ProductName`** on each token | **`swiftc`** or **`swift build`** (see [Swift](#swift)) | Not used |

## Directives

Directives are read from the **first 40 lines** of the script (after the shebang line).

- **`#!requires:`** — dependency specs (meaning varies by language; see each language section).
- **`#!flags:`** — extra arguments passed to the language’s build tool where supported.
- **`#!version:`** — language-specific toolchain version constraint (currently consumed only by **Mojo**).

Lines matching these prefixes are **removed** before compile for languages that stage a stripped body (most backends). On a single `#!requires:` line, package tokens are **comma-separated** (Rust allows commas inside `@features=[…]`). You may repeat `#!requires:` and `#!flags:` lines; they are merged in order. Only the **first** non-empty `#!version:` line is used.

**Mojo:** The cached `main.mojo` is the **full** script source; shebangsy directive lines are **not** stripped there—they remain as `#` comments for the Mojo compiler. Shebangsy still reads `#!requires:`, `#!flags:`, and `#!version:` from the first 40 lines for pixi and the cache key.

**Cache invalidation:** The cache entry is keyed by the source file’s **size and modification time**, not a content hash. Touching a file without editing (e.g. `touch script.go`) still changes mtime and forces a rebuild. For layout, stale cleanup, and when to clear `~/.cache/shebangsy` manually, see [Cache model](contributing.md#cache-model) and [Cache in the README](../README.md#cache).

The old `~/.cache/shebangsy/cpp-workspace/` directory is no longer used and is safe to delete.

## By language

### C++

```cpp
#!/usr/bin/env -S shebangsy cpp
```

**Dependencies (`#!requires:`):** Each token must use one of these prefixes:

- **`github:`** — `owner/repo@git-tag` with optional `:CMakeTarget` (may contain `::`). Fetches the tag via CMake `FetchContent`. If you omit `:CMakeTarget`, no `target_link_libraries` line is emitted (enough for some header-only layouts); otherwise link that target (typical for compiled libs or INTERFACE targets that only expose includes through the target).

```cpp
#!requires: github:CLIUtils/CLI11@v2.4.1:CLI11::CLI11
#!requires: github:fmtlib/fmt@10.2.0:fmt::fmt
```

- **`vcpkg:`** — `port@version` with optional `:CMakeTarget`. Writes `vcpkg.json` next to the generated project and configures CMake with the vcpkg toolchain (vcpkg is taken from `PATH` or bootstrapped under `~/.cache/shebangsy/vcpkg` when `git` is available).

```cpp
#!requires: vcpkg:fmt@10.0.0:fmt::fmt
```

- **`conan:`** — `name/version` with optional `:CMakeTarget`. Writes `conanfile.txt`, runs `conan install`, then configures with Conan’s CMake toolchain. **Requires `conan` on `PATH`.**

```cpp
#!requires: conan:fmt/10.2.1:fmt::fmt
```

You cannot mix **`vcpkg:`** and **`conan:`** in one script (one CMake toolchain). **`github:`** can be combined with either. Bare names such as `cli11@2.4.1` are **not** accepted — use a prefix.

**Flags (`#!flags:`):** Passed through to **CMake** configure (after `-DCMAKE_BUILD_TYPE=Release`, and after any toolchain flags).

```cpp
#!flags: -GNinja
#!flags: -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

**Toolchain version (`#!version:`):** Not used.

C++ builds use a **per-cache-key CMake tree** under `~/.cache/shebangsy/…/<script-path>/s_<size>_t_<mtime>.project/` (next to the cached binary).

### Go

```go
#!/usr/bin/env -S shebangsy go
```

**Dependencies (`#!requires:`):** One module path per token (no spaces), with a version suffix as with `go get`:

```go
#!requires: github.com/charmbracelet/lipgloss@latest
#!requires: github.com/spf13/cobra@v1.8.0
```

**Flags (`#!flags:`):** Appended to **`go build`** (for example `-tags=…`, `-ldflags=…`).

```go
#!flags: -tags=integration
#!flags: -ldflags=-s
#!flags: -tags=netgo -ldflags=-w
```

**Toolchain version (`#!version:`):** Not used.

Each compile uses a fresh module layout so dependency resolution stays predictable.

### Mojo

```text
#!/usr/bin/env -S shebangsy mojo
```

**Dependencies (`#!requires:`):** PyPI-style names, pinned with `@version` when you need an exact release. Mojo itself is always included.

```text
#!requires: numpy
#!requires: numpy@2.1.0
#!requires: numpy,scipy
```

**Flags (`#!flags:`):** Not supported.

**Toolchain version (`#!version:`):** Overrides the pixi version constraint for Mojo itself (default: `>=0.26.0,<0.27`). Any valid pixi version expression is accepted.

```text
#!version: >=24.4
#!version: *
```

### Nim

```nim
#!/usr/bin/env -S shebangsy nim
```

**Dependencies (`#!requires:`):** Comma-separated Nimble packages; optional `name@version`.

```nim
#!requires: neo
#!requires: neo,argsbarg@2.0.0
```

**Flags (`#!flags:`):** Whitespace-separated tokens appended to **`nim c`** (for example `--mm:refc`, `-d:release`).

```nim
#!flags: --mm:refc -d:danger
#!flags: -d:release
#!flags: --threads:on
```

**Toolchain version (`#!version:`):** Not used.

If a `pixi.toml` exists **above** your script path, compilation runs via **`pixi run nim c`** instead of `nim` directly.

If your filename is not a valid Nim module name, or it would **shadow** a package you import from `#!requires:`, see [`examples/nim/cli-argsbarg.nim`](../examples/nim/cli-argsbarg.nim) for a working pattern.

### Python 3

```python
#!/usr/bin/env -S shebangsy python3
```

Use the **`python3`** token on the shebang; **`python`** is an alias (same runner).

**Dependencies (`#!requires:`):** When **`uv`** is on your `PATH`, shebangsy creates the venv with **`uv venv`** and installs all tokens in one **`uv pip install`** (PEP 508 / pip-style specs). Otherwise it uses **`python3 -m venv`** and **`pip install`**. All specs from `#!requires:` lines are installed in a single resolver pass. **`UV_CACHE_DIR`** is honored by uv (no shebangsy-specific cache flag).

```python
#!requires: requests
#!requires: httpx==0.27.0
#!requires: pydantic>=2
#!requires: requests[security],httpx==0.27.0
```

**Flags (`#!flags:`):** Not supported (ignored).

**Toolchain version (`#!version:`):** Not used.

### Rust

```rust
#!/usr/bin/env -S shebangsy rust
```

**Dependencies (`#!requires:`):** Comma splitting is bracket-aware so feature lists can contain commas.

```rust
#!requires: serde
#!requires: serde@1
#!requires: serde@1,clap@4
#!requires: clap@4@features=[derive]
#!requires: clap@4@features=[derive,env]
```

Forms: `crate`, `crate@version`, or `crate@version@features=[…]` (version may be `*`).

**Flags (`#!flags:`):** Appended to **`cargo build --release`**.

```rust
#!flags: --locked
#!flags: -Ztimings=html
```

**Toolchain version (`#!version:`):** Not used.

### Swift

```swift
#!/usr/bin/env -S shebangsy swift
```

> **Important:** With **`#!requires:`**, shebangsy uses a **shared SwiftPM workspace** under `~/.cache/shebangsy/swift-workspace/`. **Manifest entries accumulate** across runs until you clear that state (see [Cache model](contributing.md#cache-model) or [Cache in the README](../README.md#cache)). If you change dependency versions or want a clean resolve, delete `~/.cache/shebangsy` or at least remove the `swift-workspace` directory inside it.

**Without `#!requires:`:** Single-file **`swiftc -O`** builds.

**With `#!requires:`:** Each token needs **`@version`** and a **`:ProductName`** after the version (SwiftPM library product to link). `owner/repo` expands to `https://github.com/owner/repo.git`. Bare package names are not accepted. First-time builds may use the network.

If the workspace has no `platforms:` block yet, shebangsy may insert **high minimum OS versions** so current Swift APIs compile; adjust in source if you need different deployment targets.

**Dependencies (`#!requires:`):**

```swift
#!requires: apple/swift-argument-parser@1.3.0:ArgumentParser
#!requires: https://github.com/mxcl/PromiseKit.git@6.5.0:PromiseKit
#!requires: owner/Repo@2.0.0:ProductName
```

**Flags (`#!flags:`):**

```swift
#!flags: -warnings-as-errors
```

- **Without** `#!requires:`: flags go to **`swiftc`** (shebangsy may add `-parse-as-library` when it detects `@main`, unless you already set it).
- **With** `#!requires:`: flags go to **`swift build -c release`**.

**Toolchain version (`#!version:`):** Not used.
