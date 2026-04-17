---
name: Cpp and Rust backends
overview: Add two new language backends — `cpp_backend.nim` (CMake + CLI11) and `rust_backend.nim` (Cargo) — following the same shadow-project pattern as Mojo. Wire both into shebangsy.nim and update README, smoke tests, and nimble description.
todos:
  - id: cpp-backend-module
    content: "Implement src/languages/cpp_backend.nim: .project shadow dir, strip shebang/frontmatter, emit CMakeLists.txt + justfile + src/main.cpp, curated cli11 FetchContent, cmake configure/build, copy binary, createRunner + clearProc."
    status: completed
  - id: rust-backend-module
    content: "Implement src/languages/rust_backend.nim: .project shadow dir, strip shebang/frontmatter lines, emit Cargo.toml (parsing name@ver@features=[...] requires specs with bracket-aware comma split) + src/main.rs, cargo build --release, copy binary, createRunner + clearProc."
    status: completed
  - id: shebangsy-wireup
    content: Import cpp_backend and rust_backend in src/shebangsy.nim; add `cpp` and `rust`/`rs` dispatch arms; hook cache-clear and warm-path compile/exec; update usage comments.
    status: completed
  - id: readme-update
    content: Update README.md — supported languages list, shebang format examples, CLI examples,
    status: completed
  - id: smoke-nimble
    content: Update scripts/test.sh (cmake-gated cpp runs for hello + cli; cargo-gated rust runs for hello) and shebangsy.nimble description.
    status: completed
isProject: false
---

# Cpp and Rust backends for shebangsy

**Scope:** Ship **two** backends in one pass — **cpp** via CMake/FetchContent ([`examples/cpp/hello.cpp`](examples/cpp/hello.cpp), [`examples/cpp/cli.cpp`](examples/cpp/cli.cpp)) and **Rust** via Cargo ([`examples/rust/hello.rs`](examples/rust/hello.rs), [`examples/rust/stat.rs`](examples/rust/stat.rs)). Same `shebangsyWarmPathExec` + `.project` sidecar pattern as Mojo for both.

## Existing patterns to mirror

- **Warm path**: All backends use [`shebangsyWarmPathExec`](src/shebangsy.nim) with `compileProc(scriptAbs, binaryPath)` + `execProc` → `(exe, args)`. See [`go_backend.nim`](src/languages/go_backend.nim) for the minimal backend shape.
- **Shadow project dir**: `binaryPath & ".project"` (from [`mojo_backend.nim`](src/languages/mojo_backend.nim)). Cache key (binaryPath) is derived from mtime + size, so each source change naturally yields a new (fresh) project dir — no explicit cleanup needed before `createDir`.
- **`createRunner*(): LanguageRunner`**: `key`, `aliases`, `runProc`, `execProc`, `clearProc`.

## Frontmatter (`#!requires:` and `#!flags:`)

- No changes to [`src/languages_common.nim`](src/languages_common.nim): `#!requires:` and `#!flags:` with colons only.
- Rust `#!requires:` tokens (comma-split by the common parser) contain `name@ver@features=[…]` — the Rust backend parses these further.
- **cpp `#!flags:`**: tokens are appended to the cmake configure call (`cmake -S … -DCMAKE_BUILD_TYPE=Release <flags>`).
- **Rust `#!flags:`**: tokens are appended to `cargo build --release <flags>`.

## Source normalization (both backends)

Strip **all lines** starting with `#!` from the top of the file before writing to the shadow project's `src/main.*`. These are the shebang line and frontmatter directives (`#!requires:`, `#!flags:`). Stop stripping at the first line that does **not** start with `#!` (or is blank after the shebang block). Error if the remaining body is empty.

## 1. `src/languages/cpp_backend.nim`

**Exports**: `cppCompile*`, `cppExecTupleForBinary*`, `createRunner*`
- `key: "cpp"`, `aliases: @[]`

**Shadow project layout** (`projectDir = binaryPath & ".project"`):

```
projectDir/
├── CMakeLists.txt
├── justfile        (for human inspection only — Nim calls cmake directly)
└── src/
    └── main.cpp    (shebang + frontmatter stripped)
```

**`CMakeLists.txt`** (modeled on [`ref/cpp-cli/CMakeLists.txt`](ref/cpp-cli/CMakeLists.txt)):
- Fixed target name `shebangsy_cpp_app`
- `cmake_minimum_required(VERSION 3.14)`, `project(ShebangsyCpp LANGUAGES CXX)`, `CMAKE_CXX_STANDARD 17` + `REQUIRED ON`
- Curated `#!requires:` map (error + exit 1 on unknown name):
  - `cli11[@ver]` → `FetchContent_Declare` pointing to `https://github.com/CLIUtils/CLI11.git`, `GIT_TAG v<ver>` (prepend `v` to bare semver e.g. `2.4.1` → `v2.4.1`), `FetchContent_MakeAvailable(cli11)`, `target_link_libraries(shebangsy_cpp_app PRIVATE CLI11::CLI11)`
- No requires → `add_executable` only, no `FetchContent` block

**`justfile`** (modeled on [`ref/cpp-cli/justfile`](ref/cpp-cli/justfile)):
- `configure`, `build` (depends configure), `run *args` (depends build, runs `./build/shebangsy_cpp_app {{args}}`), `clean`

**Build steps**:
1. `cmake -S projectDir -B projectDir/build -DCMAKE_BUILD_TYPE=Release [#!flags tokens]`
2. `cmake --build projectDir/build`
3. `copyFile(projectDir/build/shebangsy_cpp_app, binaryPath)` + set executable bits (same pattern as Mojo)

**Tool guard**: `toolEnsureOnPath("cmake", "https://cmake.org/download/")`

## 2. `src/languages/rust_backend.nim`

**Exports**: `rustCompile*`, `rustExecTupleForBinary*`, `createRunner*`
- `key: "rust"`, `aliases: @["rs"]`

**Shadow project layout** (`projectDir = binaryPath & ".project"`):

```
projectDir/
├── Cargo.toml
└── src/
    └── main.rs    (shebang + frontmatter stripped)
```

**`Cargo.toml` generation** (modeled on [`ref/rust-cli/Cargo.toml`](ref/rust-cli/Cargo.toml)):
- Fixed package name `shebangsy-rust-app`, `edition = "2021"` (Cargo maps this to binary name `shebangsy-rust-app`)
- `#!requires:` token format: `name@version@features=[f1,f2]`
  - **Bracket-aware comma split**: track bracket depth (increment on `[`, decrement on `]`); split on `,` only when depth == 0. This handles specs like `clap@4@features=[derive,color]`.
  - Per token: split on `@` — `[0]` = crate name, `[1]` = version (optional), `[2]` = `features=[…]` (optional)
  - Emit:
    - Name only → `name = "*"`
    - Name + version → `name = "ver"`
    - Name + version + features → `name = { version = "ver", features = ["f1", "f2"] }`
  - Example: `clap@4@features=[derive]` → `clap = { version = "4", features = ["derive"] }`

**Build steps**:
1. `cargo build --release [#!flags tokens]` (working dir = `projectDir`)
2. `copyFile(projectDir/target/release/shebangsy-rust-app, binaryPath)` + set executable bits

**Tool guard**: `toolEnsureOnPath("cargo", "https://www.rust-lang.org/tools/install")`

## 3. Wire-up in `src/shebangsy.nim`

- `import ./languages/[go_backend, mojo_backend, cpp_backend, rust_backend]`
- `case head` in `shebangsyLanguageRunHandle` and main `isMainModule` block:
  - `"cpp"` → cpp backend
  - `"rust", "rs"` → rust backend
- `shebangsyCacheClearHandle`: call `cpp_backend.createRunner().clearProc()` and `rust_backend.createRunner().clearProc()`
- Update top-of-file usage comment and CLI `description`

## 4. README.md updates

- **Line 3**: add `cpp` and `Rust` to the supported languages sentence
- **Shebang format** (lines 43–46): add `#!/usr/bin/env -S shebangsy cpp` and `#!/usr/bin/env -S shebangsy rust`
- **CLI examples** (lines 71–75): add `shebangsy cpp ./hello.cpp` and `shebangsy rust ./hello.rs`
- **`#!requires:` table** (lines 133–135): add cpp row (`cli11@2.4.1` → FetchContent) and Rust row (`name@ver@features=[…]` → `Cargo.toml`)
- **`#!flags:` table** (lines 147–149): add cpp row (extra cmake `-D` tokens) and Rust row (extra `cargo build` flags)
- **VS Code associations** (lines 206–218): add `shebangsy cpp` → `cpp` and `shebangsy rust` → `rust`

## 5. Tests and packaging

**[`scripts/test.sh`](scripts/test.sh)**:
- `cmake --version` guard: cold + warm `run_lang_test cpp ./examples/cpp/hello.cpp`; plus `shebangsy cpp ./examples/cpp/cli.cpp hello World` checking stdout is `hello, World`
- `cargo --version` guard: cold + warm `run_lang_test rust ./examples/rust/hello.rs`

**[`shebangsy.nimble`](shebangsy.nimble)**: update `description` to mention cpp and Rust.
