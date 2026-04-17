# shebangsy

Single-file script runner for **cpp, Go, Mojo, Nim, Python3, Rust, and Swift**. Write a shebang, `chmod +x`, and run. Automatic compilation and caching skip rebuilds when the source hasn't changed.

**Optimized for Speed:** Using shebangsy vs running a pre-compiled bin is ~10ms penalty -- low enough for snappy shell completions

**Optimized for Easy:** Each language uses the same frontmatter syntax for dep pinning

**Supported platforms:** macOS and Linux (POSIX). Windows is not supported.

---

## Quick start

1. Put **`shebangsy` on your `PATH`** (see [Install](#install)).
2. Start your script with `#!/usr/bin/env -S shebangsy <language>`.
3. `chmod +x` and run it.

Example for a `gonum-hello.go`

```go
#!/usr/bin/env -S shebangsy go
#!requires: gonum.org/v1/gonum

package main

import (
	"fmt"
	"gonum.org/v1/gonum/mat"
)

func main() {
	u := mat.NewVecDense(3, []float64{1, 2, 3})
	v := mat.NewVecDense(3, []float64{4, 5, 6})
	fmt.Println("u · v =", mat.Dot(u, v))
}
```

```sh
chmod +x hello-go
./hello-go   # compiles (first run), prints "hello from go"
./hello-go   # warm cache hit, just runs the binary
```

See [examples](./examples) for more.

---

## Command line

You can also compile+run an app with shebangsy without the shebang by using the command line interface:

```text
shebangsy <language> <script> [...script args]
```

---

## Install

**From a clone** (builds, installs to `~/.nimble/bin/shebangsy`, writes zsh completion):

```sh
just install
# or: ./scripts/install.sh
```

---

## Build

```sh
just build
# or: ./scripts/build.sh
```

Cross-compiled zips (macOS host + Linux glibc) land in `dist/`:

```sh
just build-cross
# or: ./scripts/build-cross.sh
```

---

## Test

```sh
just test
# or: ./scripts/test.sh
```

Runs smoke tests for each language (Mojo, cpp, Rust, Swift, and Python3 are skipped if their toolchains are unavailable).

---

## Benchmark

### Results

Below is a chart showing the mean completion times for "hello" apps over several runs of the benchmark. This chart is helpful to understand the overhead/penalty of using shebangsy (or alternatives) vs running a bin/script directly using `./{bin}` or `python3 {script}`.

TL;DR - shebangsy is as good or better than alternatives at ~10ms cost.

```mermaid
---
config:
  themeVariables:
    xyChart:
      backgroundColor: "#e8eaed"
      plotColorPalette: "#1d4ed8, #1d4ed8, #15803d, #15803d, #15803d, #15803d, #a16207, #a16207, #7c3aed, #7c3aed, #b91c1c, #b91c1c, #b91c1c, #0e7490, #0e7490, #4338ca, #4338ca, #4338ca"
      titleColor: "#111318"
      xAxisLabelColor: "#2d3139"
      yAxisLabelColor: "#2d3139"
      xAxisTitleColor: "#1a1d24"
      yAxisTitleColor: "#1a1d24"
      xAxisLineColor: "#9aa0ab"
      yAxisLineColor: "#9aa0ab"
      xAxisTickColor: "#5c6370"
      yAxisTickColor: "#5c6370"
---
xychart-beta horizontal
    title "Mean time (ms) per app — all time"
    x-axis ["cpp/bin", "cpp/shebangsy.cpp", "go/bin", "go/shebangsy.go", "go/gorun.go", "go/scriptisto.go", "mojo/bin", "mojo/shebangsy.mojo", "nim/bin", "nim/shebangsy.nim", "python/bin", "python/shebangsy.py", "python/uv.py", "rust/bin", "rust/shebangsy.rs", "swift/bin", "swift/shebangsy.swift", "swift/swift_sh.swift"]
    y-axis "ms" 0 --> 80
    bar [5.4, 15.6, 6.3, 16.0, 17.7, 18.4, 10.1, 19.6, 5.2, 15.0, 16.5, 27.6, 53.7, 5.6, 15.5, 5.9, 15.3, 80.0]
```

### Running the Benchmark

```sh
just bench
# or: ./scripts/bench.py
```


---

## Languages

Directives are read from the **first 40 lines** of the script (after the shebang). Lines starting with `#!requires:` and `#!flags:` are stripped before compile; **comma-separated** package tokens on one `#!requires:` line are split on commas (Rust additionally supports commas **inside** `@features=[…]`). **Multiple** `#!requires:` / `#!flags:` lines are merged in order. They apply on compile and stay cached until the source file’s size or mtime changes.

### cpp

Uses a **shared** CMake workspace at **`~/.cache/shebangsy/cpp-workspace/`** (not per-script `binaryPath.project`). Only **`cli11`** is supported in `#!requires:`. **`#!flags:`** tokens are appended to the **`cmake -S … -B …`** configure invocation (after `-DCMAKE_BUILD_TYPE=Release`).

#### Dependencies directives (`#!requires:`)

```cpp
#!requires: cli11
#!requires: cli11@2.4.1
```

- Omitting `@version` defaults CLI11 to **2.4.1** (git tag is normalized with a `v` prefix when needed).
- Any other package name is rejected at compile time.

#### Flags (`#!flags:`)

```cpp
#!flags: -GNinja
#!flags: -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

### Go

The module is built under **`cacheShadowDirFromBinary(binaryPath)`** (next to the cached binary); the tree is **removed and recreated** at each compile so `go mod init` always runs on a clean `go.mod`. Each `#!requires:` token must be a **single** module path token (no spaces); `go get` is run per token.

#### Dependencies directives (`#!requires:`)

```go
#!requires: github.com/charmbracelet/lipgloss@latest
#!requires: github.com/spf13/cobra@v1.8.0
```

- Full module path with `.` or `/`; include a version suffix such as `@latest` or `@v1.8.0` as you would with `go get`.

#### Flags (`#!flags:`)

```go
#!flags: -tags=integration
#!flags: -ldflags=-s
#!flags: -tags=netgo -ldflags=-w
```

- Tokens are appended to `go build` after the default arguments (before `-o` and the staged `main.go`).

### Mojo

`#!requires:` entries become **PyPI** dependencies in the Pixi manifest (Mojo itself is always included). **`#!flags:`** is not read by the Mojo backend.

#### Dependencies directives (`#!requires:`)

```text
#!requires: numpy
#!requires: numpy@2.1.0
#!requires: numpy,scipy
```

- `name` or `name@version` (`@version` becomes a `==` pin in `pixi.toml`).

#### Flags (`#!flags:`)

Not supported.

### Nim

Nimble installs missing packages and passes `--path:…` into `nim c`. If a `pixi.toml` exists **above the original script path**, compilation uses `pixi run nim c` instead of `nim` directly.

If the `.nim` basename is not a valid module name, or it would **shadow** a package you import from `#!requires:` (e.g. a file named `argsbarg.nim` while requiring `argsbarg`), the source is staged under the per-cache **shadow** directory `binaryPath & ".project"`; see [examples/nim/greet_demo.nim](examples/nim/greet_demo.nim).

#### Dependencies directives (`#!requires:`)

```nim
#!requires: neo
#!requires: neo,argsbarg@2.0.0
```

- One or more Nimble package names on a line, **comma-separated**.
- Optional version: `name@version` (Nimble spec).

#### Flags (`#!flags:`)

```nim
#!flags: --mm:refc -d:danger
#!flags: -d:release
#!flags: --threads:on
```

- **Whitespace-separated** tokens; each line’s tokens are appended in order.

### Python3

CLI token **`python3`**; alias **`python`**. The script body is written to the cache artifact path; an isolated **`.venv`** lives under **`binaryPath & ".project"`**. Each `#!requires:` token is passed to **`python -m pip install <token>`** inside that venv (any form `pip` accepts: plain name, `pkg==1.2.3`, `pkg>=2`, extras, etc.).

#### Dependencies directives (`#!requires:`)

```python
#!requires: requests
#!requires: httpx==0.27.0
#!requires: pydantic>=2
#!requires: requests[security],httpx==0.27.0
```

#### Flags (`#!flags:`)

Not supported; lines are ignored.

### Rust

Crate graph is generated under **`cacheShadowDirFromBinary(binaryPath)`** (Cargo project). `#!requires:` uses Rust’s own **bracket-aware** comma splitting so feature lists can contain commas.

#### Dependencies directives (`#!requires:`)

```rust
#!requires: serde
#!requires: serde@1
#!requires: serde@1,clap@4
#!requires: clap@4@features=[derive]
#!requires: clap@4@features=[derive,env]
```

- `crate`, `crate@version`, or `crate@version@features=[f1,f2]` (version may be `*`).

#### Flags (`#!flags:`)

```rust
#!flags: --locked
#!flags: -Ztimings=html
```

- Tokens are appended to **`cargo build --release`**.

### Swift

**No `#!requires:`** → **`swiftc -O`** (sidecar source under `binaryPath & ".project"`, removed after compile). **With `#!requires:`** → shared SwiftPM tree at **`~/.cache/shebangsy/swift-workspace/`**; dependencies **accumulate** in `Package.swift` until **`shebangsy cache-clear`**. If the workspace `Package.swift` has no `platforms:` block yet, shebangsy inserts **high minimum OS versions** so current Swift APIs compile (adjust in `swift.nim` if you need different floors). Each token must include **`@version`**; optional **`:`product** after the version for unknown URLs/repos. Bump a package version already in the manifest by clearing the cache first. Cold compiles with deps may hit the network.

#### Dependencies directives (`#!requires:`)

```swift
#!requires: swift-argument-parser@1.3.0
#!requires: apple/swift-argument-parser@1.3.0
#!requires: https://github.com/mxcl/PromiseKit.git@6.5.0
#!requires: owner/Repo@2.0.0:ProductName
```

- Shorthand / `owner/repo` / full `https://…` forms; unknown `owner/repo` needs **`:ProductName`** after the version.

#### Flags (`#!flags:`)

```swift
#!flags: -warnings-as-errors
```

- With **no** `#!requires:`: appended to **`swiftc`** (with `-parse-as-library` injected automatically when `@main` is detected, unless already present in flags).
- With **`#!requires:`**: appended to **`swift build -c release`** (and wrapped for SwiftPM where applicable).

---

## Editor tips (VS Code / Cursor)

For syntax highlighting on files without extension, install
[Shebang Language Associator](https://marketplace.visualstudio.com/items?itemName=davidhewitt.shebang-language-associator)
and add:

```json
  "shebang.associations": [
    {
      "pattern": "^#!/usr/bin/env -S shebangsy cpp$",
      "language": "cpp"
    },
    {
      "pattern": "^#!/usr/bin/env -S shebangsy go$",
      "language": "go"
    },
    {
      "pattern": "^#!/usr/bin/env -S shebangsy mojo$",
      "language": "python"
    },
    {
      "pattern": "^#!/usr/bin/env -S shebangsy nim$",
      "language": "nim"
    },
    {
      "pattern": "^#!/usr/bin/env -S shebangsy python3$",
      "language": "python"
    },
    {
      "pattern": "^#!/usr/bin/env -S shebangsy rust$",
      "language": "rust"
    },
    {
      "pattern": "^#!/usr/bin/env -S shebangsy swift$",
      "language": "swift"
    }
  ]
```

---

## License

MIT

