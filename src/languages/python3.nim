#[
languages/python3 – run .py scripts with an isolated venv and pip-installed ``#!requires:``

Goal: treat Python like other shebangsy backends: a cache key (size+mtime) maps to a
  stored artifact and a sidecar directory for build state.

Why: ``#!requires:`` maps to ``pip install`` so scripts can depend on PyPI packages without
  polluting the user environment. The stripped script body is written to ``binaryPath``;
  the interpreter is the venv Python under ``cacheShadowDirFromBinary(binaryPath)``.

How:
  1. ``stripShebangAndFrontmatterBody`` → write body to ``binaryPath``.
  2. Ensure ``shadow/.venv`` exists (``python3 -m venv``).
  3. ``pip install`` each token from ``frontmatterDirectivesFromSource`` (``#!flags:`` ignored).

```mermaid
flowchart TD
  A[script.py] --> B[stripShebangAndFrontmatterBody]
  B --> C[writeFile binaryPath]
  C --> D{venv exists?}
  D -- no --> E[python3 -m venv .venv]
  D -- yes --> F[pip install specs]
  E --> F
  F --> G[return 0]
```
]#

import std/[os, strutils]
import ../languages_common


## Writes stripped source, ensures venv, runs ``pip install`` for each ``#!requires:`` token.
proc python3Compile*(scriptAbs, binaryPath: string): int =
  if not toolEnsureOnPath("python3", "https://www.python.org/downloads/"):
    return 1
  let py3Exe = findExe("python3")
  if py3Exe.len == 0:
    stderr.writeLine "[shebangsy:python3] python3 not found on PATH"
    return 1

  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:python3] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let body = stripShebangAndFrontmatterBody(raw)
  if body.strip.len == 0:
    stderr.writeLine "[shebangsy:python3] empty script body after shebang/directives"
    return 1

  let directives = frontmatterDirectivesFromSource(raw)
  let shadow = cacheShadowDirFromBinary(binaryPath)
  try:
    createDir(shadow)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:python3] cannot create shadow dir: ", shadow, ": ", e.msg
    return 1

  proc venvPython(): string =
    shadow / ".venv" / "bin" / "python"

  if not fileExists(venvPython()):
    let code = processExitCodeWait(py3Exe, @["-m", "venv", ".venv"], shadow)
    if code != 0:
      stderr.writeLine "[shebangsy:python3] python3 -m venv failed in ", shadow
      return code

  try:
    writeFile(binaryPath, body)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:python3] cannot write cache entry: ", binaryPath, ": ", e.msg
    return 1

  let venvPy = venvPython()
  for spec in directives.requires:
    var pipCode = processExitCodeWait(venvPy, @["-m", "pip", "install", spec], shadow)
    if pipCode != 0:
      try:
        removeDir(shadow, checkDir = false)
      except CatchableError:
        discard
      try:
        createDir(shadow)
      except CatchableError as e:
        stderr.writeLine "[shebangsy:python3] cannot recreate shadow dir: ", shadow, ": ", e.msg
        return 1
      pipCode = processExitCodeWait(py3Exe, @["-m", "venv", ".venv"], shadow)
      if pipCode != 0:
        stderr.writeLine "[shebangsy:python3] venv recreate failed in ", shadow
        return pipCode
      pipCode = processExitCodeWait(venvPython(), @["-m", "pip", "install", spec], shadow)
      if pipCode != 0:
        stderr.writeLine "[shebangsy:python3] pip install failed after retry: ", spec
        return pipCode
  0


## Exec tuple: venv Python with the cached script path as ``argv[1]``.
proc python3ExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  let shadow = cacheShadowDirFromBinary(binaryPath)
  let venvPy = shadow / ".venv" / "bin" / "python"
  (venvPy, @[binaryPath] & scriptArgs)


## Registers the Python3 language runner.
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @["python"],
    compileProc: python3Compile,
    description: "Run Python3 scripts: isolated venv per cache key; pip install for #!requires:",
    execProc: python3ExecTupleForBinary,
    key: "python3",
    warmPathKind: wpSpawnCachedRetryCompile,
  )
