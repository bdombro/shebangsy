#[
languages/rust – compile Rust scripts via Cargo with optional crate dependencies

Goal: let shebangsy execute single-file .rs scripts with #!requires: crate specs such
  as serde@1 or clap@4@features=[derive], without requiring the user to manage a
  Cargo project.

Why: Cargo requires a Cargo.toml and a specific directory layout; this module creates
  a shadow Cargo project under ``cacheShadowDirFromBinary(binaryPath)`` (``binaryPath &
  ".project"``), generates the manifest from frontmatter specs, and builds to the cache.

How:
  1. Parse #!requires: lines into (name, version, features) tuples using a
     bracket-aware comma splitter to handle features=[a,b] syntax.
  2. Generate Cargo.toml with a [dependencies] section.
  3. Write the stripped source to ``shadow/src/main.rs`` under ``cacheShadowDirFromBinary``.
  4. cargo build --release → copy the release binary to binaryPath.

```mermaid
flowchart TD
    A[script.rs] --> B[parse #!requires:]
    B --> C[generate Cargo.toml]
    C --> D[write src/main.rs]
    D --> E[cargo build --release]
    E --> F[copy to binaryPath]
```
]#

import std/[os, strutils]
import ../languages_common

## Clears the global shebangsy cache.
proc rustCacheClear(): int =
  cacheClear()


## Splits on commas outside of ``[...]`` (for ``@features=[a,b]`` in requires lines).
proc bracketAwareCommaSplit(s: string): seq[string] =
  var depth = 0
  var start = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of '[':
      inc depth
    of ']':
      if depth > 0:
        dec depth
    of ',':
      if depth == 0:
        let piece = s[start ..< i].strip
        if piece.len > 0:
          result.add piece
        start = i + 1
    else:
      discard
    inc i
  let last = s[start .. ^1].strip
  if last.len > 0:
    result.add last


## ``#!requires:`` crate specs from the first 40 lines (comma-split, bracket-aware).
proc rustRequiresSpecsFromSource(content: string): seq[string] =
  var lineNum = 0
  for line in content.splitLines:
    inc lineNum
    if lineNum > 40:
      break
    if lineNum == 1 and line.startsWith("#!/"):
      continue
    let s = line.strip
    const requiresPrefix = "#!requires:"
    if s.startsWith(requiresPrefix):
      let rest = s[requiresPrefix.len .. ^1].strip
      if rest.len == 0:
        continue
      for spec in bracketAwareCommaSplit(rest):
        if spec.len > 0:
          result.add spec


## Parses ``name@ver`` with optional ``@features=[…]`` into name, version, and feature list.
proc rustParseDepSpec(spec: string): (string, string, seq[string]) =
  var s = spec.strip
  var feats: seq[string] = @[]
  const featMarker = "@features=["
  let fm = s.find(featMarker)
  if fm >= 0:
    let head = s[0 ..< fm]
    let innerStart = fm + featMarker.len
    var innerEnd = innerStart
    while innerEnd < s.len and s[innerEnd] != ']':
      inc innerEnd
    let inner = s[innerStart ..< innerEnd].strip
    for p in inner.split(','):
      let t = p.strip
      if t.len > 0:
        feats.add t
    s = head
  let lastAt = s.rfind('@')
  if lastAt < 0:
    return (s, "*", feats)
  let name = s[0 ..< lastAt].strip
  let ver = s[lastAt + 1 .. ^1].strip
  if name.len == 0:
    return ("", "*", feats)
  if ver.len == 0:
    return (name, "*", feats)
  (name, ver, feats)


## One ``Cargo.toml`` dependency line for a parsed crate spec.
proc rustTomlDepLine(name, ver: string; feats: seq[string]): string =
  let n = name.strip
  if n.len == 0:
    return ""
  if feats.len == 0:
    if ver == "*":
      result = n & " = \"*\""
    else:
      result = n & " = \"" & ver & "\""
  else:
    var quoted: seq[string] = @[]
    for f in feats:
      quoted.add "\"" & f & "\""
    let featList = quoted.join(", ")
    if ver == "*":
      result = n & " = { version = \"*\", features = [" & featList & "] }"
    else:
      result = n & " = { version = \"" & ver & "\", features = [" & featList & "] }"


## Builds a minimal ``Cargo.toml`` string for the shadow project, or empty on invalid spec.
proc rustCargoTomlGenerate(specs: seq[string]): string =
  var lines = @[
    "[package]",
    "name = \"shebangsy-rust-app\"",
    "version = \"0.1.0\"",
    "edition = \"2021\"",
    "",
    "[dependencies]",
  ]
  for spec in specs:
    let (n, v, f) = rustParseDepSpec(spec)
    if n.len == 0:
      stderr.writeLine "[shebangsy:rust] empty crate name in #!requires: spec: ", spec
      return ""
    let line = rustTomlDepLine(n, v, f)
    if line.len == 0:
      stderr.writeLine "[shebangsy:rust] invalid #!requires: spec: ", spec
      return ""
    lines.add line
  lines.join("\n") & "\n"


## Writes the shadow crate, runs ``cargo build --release``, copies the binary to ``binaryPath``.
proc rustCompile*(scriptAbs, binaryPath: string): int =
  if not toolEnsureOnPath("cargo", "https://www.rust-lang.org/tools/install"):
    return 1

  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:rust] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let body = stripShebangAndFrontmatterBody(raw)
  if body.strip.len == 0:
    stderr.writeLine "[shebangsy:rust] empty script after shebang and frontmatter"
    return 1

  let specs = rustRequiresSpecsFromSource(raw)
  let cargoToml = rustCargoTomlGenerate(specs)
  if cargoToml.len == 0:
    return 1

  let flags = frontmatterDirectivesFromSource(raw).flags
  let shadow = cacheShadowDirFromBinary(binaryPath)
  createDir(shadow / "src")
  writeFile(shadow / "src/main.rs", body)
  writeFile(shadow / "Cargo.toml", cargoToml)

  ## Do not resolve `cargo` → `rustup` (same binary): argv[0] must stay ``cargo``
  ## or the multiplexer treats ``build`` as a rustup subcommand and fails.
  let cargoExe = findExe("cargo", followSymlinks = false)
  if cargoExe.len == 0:
    stderr.writeLine "[shebangsy:rust] cargo not found on PATH"
    return 1
  var cargoArgs = @["build", "--release"]
  for f in flags:
    cargoArgs.add f
  let code = processExitCodeWait(cargoExe, cargoArgs, shadow)
  if code != 0:
    return code

  let built = shadow / "target" / "release" / "shebangsy-rust-app"
  if not fileExists(built):
    stderr.writeLine "[shebangsy:rust] expected build output not found: ", built
    return 1

  copyFile(built, binaryPath)
  try:
    setFilePermissions(binaryPath, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
        fpOthersRead, fpOthersExec})
  except CatchableError:
    discard
  0


## Exec tuple for a cached Rust binary.
proc rustExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  (binaryPath, scriptArgs)


## Registers the Rust language runner.
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @["rs"],
    clearProc: rustCacheClear,
    compileProc: rustCompile,
    description: "Compile and run Rust scripts via Cargo",
    execProc: rustExecTupleForBinary,
    key: "rust",
  )
