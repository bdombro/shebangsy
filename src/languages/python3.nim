#[
languages/python3 – run .py scripts with an isolated venv and ``#!requires:`` via uv or pip

Goal: treat Python like other shebangsy backends: a cache key (size+mtime) maps to a
  stored artifact and a sidecar directory for build state.

Why: ``#!requires:`` maps to package install (``uv pip install`` when ``uv`` is on ``PATH``,
  otherwise ``pip install``) so scripts can depend on PyPI without polluting the user
  environment. The stripped script body is written to ``binaryPath``; the interpreter is
  the venv Python under ``cacheShadowDirFromBinary(binaryPath)``. ``#!flags:`` is ignored.

How:
  1. If ``findExe("uv")`` succeeds, require ``uv`` only (no ``python3`` on PATH needed).
     Else require ``python3`` and use ``python3 -m venv``.
  2. ``createDir(shadow)``; if ``.venv/bin/python`` missing, ``uv venv .venv`` or ``python3 -m venv``.
  3. ``writeFile(binaryPath, body)``.
  4. If ``#!requires:`` tokens exist, one batched install; on failure wipe ``shadow``, recreate
     venv, retry install once.

```mermaid
flowchart TD
  A[script.py] --> B[strip + directives]
  B --> C{uv on PATH?}
  C -->|yes| D[uv venv if needed]
  C -->|no| E[python3 -m venv if needed]
  D --> F[write cached body]
  E --> F
  F --> G{requires empty?}
  G -->|yes| H[return 0]
  G -->|no| I[uv pip install OR pip install all specs]
  I --> J{ok?}
  J -->|yes| H
  J -->|no| K[wipe shadow + venv + retry batch once]
  K --> L{retry ok?}
  L -->|yes| H
  L -->|no| M[return error code]
```
]#

import std/[os, strutils]
import ../languages_common


## True when ``uv`` is available for venv + installs.
proc python3UvAvailable(): bool =
  findExe("uv").len > 0


## Absolute path to the venv interpreter under ``shadow``.
proc python3VenvPython(shadow: string): string =
  absolutePath(shadow / ".venv" / "bin" / "python")


## One batched install of all ``specs`` into ``shadow``'s venv (``venvPy`` absolute).
proc python3InstallAll(shadow, venvPy: string; specs: seq[string]; useUv: bool; uvExe: string): int =
  if specs.len == 0:
    return 0
  if useUv:
    processExitCodeWait(uvExe, @["pip", "install", "-p", venvPy] & specs, shadow)
  else:
    processExitCodeWait(venvPy, @["-m", "pip", "install"] & specs, shadow)


## Writes stripped source, ensures venv, batched install for ``#!requires:`` (uv or pip).
proc python3Compile*(scriptAbs, binaryPath: string): int =
  let useUv = python3UvAvailable()
  if useUv:
    if not toolEnsureOnPath("uv", "https://docs.astral.sh/uv/", runnerKey = "python3"):
      return 1
  else:
    if not toolEnsureOnPath("python3", "https://www.python.org/downloads/", runnerKey = "python3"):
      return 1

  let uvExe = if useUv: findExe("uv") else: ""
  let py3Exe = if not useUv: findExe("python3") else: ""
  if useUv and uvExe.len == 0:
    stderr.writeLine "[shebangsy:python3] uv not found on PATH"
    return 1
  if not useUv and py3Exe.len == 0:
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

  if not fileExists(python3VenvPython(shadow)):
    let vcode =
      if useUv:
        processExitCodeWait(uvExe, @["venv", ".venv"], shadow)
      else:
        processExitCodeWait(py3Exe, @["-m", "venv", ".venv"], shadow)
    if vcode != 0:
      stderr.writeLine "[shebangsy:python3] venv creation failed in ", shadow
      return vcode

  try:
    writeFile(binaryPath, body)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:python3] cannot write cache entry: ", binaryPath, ": ", e.msg
    return 1

  if directives.requires.len == 0:
    return 0

  let venvPy = python3VenvPython(shadow)
  var code = python3InstallAll(shadow, venvPy, directives.requires, useUv, uvExe)
  if code != 0:
    try:
      removeDir(shadow, checkDir = false)
    except CatchableError:
      discard
    try:
      createDir(shadow)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:python3] cannot recreate shadow dir: ", shadow, ": ", e.msg
      return 1
    let v2 =
      if useUv:
        processExitCodeWait(uvExe, @["venv", ".venv"], shadow)
      else:
        processExitCodeWait(py3Exe, @["-m", "venv", ".venv"], shadow)
    if v2 != 0:
      stderr.writeLine "[shebangsy:python3] venv recreate failed in ", shadow
      return v2
    code = python3InstallAll(shadow, python3VenvPython(shadow), directives.requires, useUv, uvExe)
    if code != 0:
      stderr.writeLine "[shebangsy:python3] package install failed after retry"
  code


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
    description:
      "Run Python3 scripts: isolated venv per cache key; uv (if on PATH) or pip for #!requires:",
    execProc: python3ExecTupleForBinary,
    key: "python3",
    warmPathKind: wpSpawnCachedRetryCompile,
  )
