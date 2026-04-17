#[
languages/go – compile and run single-file Go scripts with optional module dependencies

Goal: let shebangsy execute .go files that carry #!requires: module-path directives
  without requiring the user to maintain a go.mod or module structure.

Why: Go's module system requires a go.mod for any import beyond the standard library.
  This module stages each compile in ``cacheShadowDirFromBinary(binaryPath)`` (next to
  the cache artifact), wipes that shadow at compile start so ``go mod init`` always
  succeeds, then fetches deps via go get and builds a static binary to the cache path.

How:
  1. Parse frontmatter with ``frontmatterDirectivesFromSource`` and stage the body with
     ``stripShebangAndFrontmatterBody`` (same contract as Rust/Swift/cpp).
  2. Stage the body as main.go under the per-key shadow directory.
  3. go mod init → go get <each dep> → go mod tidy → go build -o binaryPath.

```mermaid
flowchart TD
    A[script.go] --> B[directives + strip body]
    B --> C[stage in shadow/main.go]
    C --> D[go mod init]
    D --> E[go get each dep]
    E --> F[go mod tidy]
    F --> G[go build -o binaryPath]
```
]#

import std/[os, strutils]
import ../languages_common


## Stages the script under ``cacheShadowDirFromBinary``, runs ``go get`` for ``#!requires:``,
## and builds to ``binaryPath``.
proc goCompile*(scriptAbs, binaryPath: string): int =
  let goExe = findExe("go")
  if goExe.len == 0:
    stderr.writeLine "[shebangsy] go compiler not found on PATH"
    return 1

  let scriptContent =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:go] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let directives = frontmatterDirectivesFromSource(scriptContent)
  let staged = stripShebangAndFrontmatterBody(scriptContent)
  if staged.strip.len == 0:
    stderr.writeLine "[shebangsy:go] empty script body after shebang/directives"
    return 1

  let shadow = cacheShadowDirFromBinary(binaryPath)
  if dirExists(shadow):
    try:
      removeDir(shadow, checkDir = false)
    except CatchableError:
      discard
  createDir(shadow)
  let stagedPath = shadow / "main.go"
  writeFile(stagedPath, staged)

  var code = processExitCodeWait(goExe, ["mod", "init", "script-shebangsy"], shadow)
  if code != 0:
    return code
  for spec in directives.requires:
    for c in spec:
      if c in Whitespace:
        stderr.writeLine "[shebangsy:go] requires: module must be a single token: ", spec
        return 1
    if not (spec.contains('.') or spec.contains('/')):
      stderr.writeLine "[shebangsy:go] requires: expected full module path: ", spec
      return 1
    code = processExitCodeWait(goExe, ["get", spec], shadow)
    if code != 0:
      return code
  code = processExitCodeWait(goExe, ["mod", "tidy"], shadow)
  if code != 0:
    return code
  var buildArgs = @["build"]
  for f in directives.flags:
    buildArgs.add f
  buildArgs.add @["-o", binaryPath, stagedPath]
  processExitCodeWait(goExe, buildArgs, shadow)


## Exec tuple for a cached Go binary (no wrapper).
proc goExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  (binaryPath, scriptArgs)


## Registers the Go language runner with shebangsy.
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @["golang"],
    compileProc: goCompile,
    description: "Compile and run Go scripts",
    execProc: goExecTupleForBinary,
    key: "go",
  )
