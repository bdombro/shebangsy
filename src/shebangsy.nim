#[
shebangsy – CLI entry point and warm-path orchestration

Goal: parse argv and dispatch to the correct language runner, or handle built-in CLI
  commands (cache-clear, --help, completion). All language backends share the same
  binary-caching warm-path, so it lives here rather than in each language module.

Why: keeping the hot path (stat → cache key → execv) in one place means each language
  module only needs to supply a compile proc and an exec proc. The flock/execv machinery
  is not duplicated.

How:
  1. If argv[0] is a known language token, call shebangsyLanguageRunHandle directly.
  2. Otherwise fall through to cliRun (argsbarg) for --help / cache-clear / completion.
  shebangsyWarmPathExec drives the hot path:
    stat script → derive cache key (size+mtime) → try execv on cached binary →
    acquire flock → compile if still missing → execv.

```mermaid
flowchart TD
    A[argv] --> B{token in registry?}
    B -- yes --> C[shebangsyLanguageRunHandle]
    B -- no --> E[cliRun / --help / cache-clear]
    C --> F[shebangsyWarmPathExec]
    F --> G{binary cached?}
    G -- hit --> H[execv cached binary]
    G -- miss --> I[compile + execv]
```

POSIX only (macOS, Linux, and similar). Windows is not supported.
]#

import std/[os, strutils, tables, times]
import argsbarg
import ./languages_common
import ./languages_registry


## Unified warm-path runner: stat → cache lookup → compile if needed → execv.
## All languages share this orchestration after backends provide compile and exec procs.
proc shebangsyWarmPathExec(
    scriptPath: string; scriptArgs: seq[string]; compileProc: CompileProc; execProc: ExecProc) =
  let tExpand = epochTime()
  let scriptAbs =
    try:
      expandFilename(scriptPath)
    except CatchableError as e:
      stderr.writeLine "[shebangsy] cannot read script: ", scriptPath, ": ", e.msg
      quit(1)
  warmProfileLog("shebangsyWarmPathExec.expandFilename", tExpand)

  let tBinary = epochTime()
  let binaryPath = cacheScriptBinaryPathFromAbsGet(scriptAbs)
  warmProfileLog("shebangsyWarmPathExec.cacheScriptBinaryPathGet", tBinary)
  let (warmExe, warmArgs) = execProc(binaryPath, scriptArgs)
  if cacheWarmRunTryExec(warmExe, warmArgs):
    return

  createDir(parentDir(binaryPath))
  let lockPath = cacheLockPathFromBinary(binaryPath)
  discard cacheCompileLockAcquire(lockPath)
  let (lockExe, lockArgs) = execProc(binaryPath, scriptArgs)
  if cacheWarmRunTryExec(lockExe, lockArgs):
    return

  shebangsyCompileMissNotice()
  let compileCode = compileProc(scriptAbs, binaryPath)
  if compileCode != 0:
    quit(compileCode)

  let scriptCacheDir = parentDir(binaryPath)
  cacheSameScriptStaleRemove(scriptCacheDir, binaryPath)

  let (exe, args) = execProc(binaryPath, scriptArgs)
  if cacheWarmRunTryExec(exe, args):
    return
  stderr.writeLine "[shebangsy] expected compiled binary missing: ", binaryPath
  quit(1)


## Warm path for interpreted backends: ``spawn`` + wait; flock + compile on cold miss.
proc shebangsyInterpretedWarmRun(
    scriptPath: string; scriptArgs: seq[string]; compileProc: CompileProc; execProc: ExecProc) =
  let scriptAbs =
    try:
      expandFilename(scriptPath)
    except CatchableError as e:
      stderr.writeLine "[shebangsy] cannot read script: ", scriptPath, ": ", e.msg
      quit(1)

  let binaryPath = cacheScriptBinaryPathFromAbsGet(scriptAbs)

  if fileExists(binaryPath):
    let (warmExe, warmArgs) = execProc(binaryPath, scriptArgs)
    quit(processExitCodeWait(warmExe, warmArgs))

  createDir(parentDir(binaryPath))
  let lockPath = cacheLockPathFromBinary(binaryPath)
  let lockFd = cacheCompileLockAcquire(lockPath)

  if fileExists(binaryPath):
    let (exe, args) = execProc(binaryPath, scriptArgs)
    if lockFd >= 0:
      cacheCompileLockRelease(lockFd)
    quit(processExitCodeWait(exe, args))

  shebangsyCompileMissNotice()
  let compileCode = compileProc(scriptAbs, binaryPath)
  if compileCode != 0:
    if lockFd >= 0:
      cacheCompileLockRelease(lockFd)
    quit(compileCode)

  let scriptCacheDir = parentDir(binaryPath)
  cacheSameScriptStaleRemove(scriptCacheDir, binaryPath)

  if lockFd >= 0:
    cacheCompileLockRelease(lockFd)

  if not fileExists(binaryPath):
    stderr.writeLine "[shebangsy] expected cached script missing: ", binaryPath
    quit(1)

  let (exe, args) = execProc(binaryPath, scriptArgs)
  quit(processExitCodeWait(exe, args))


## Runs one compiled-script backend using shebang-style args: ``<language> <script> [args...]``.
proc shebangsyLanguageRunHandle(language: string; scriptAndArgs: seq[string]) =
  if scriptAndArgs.len == 0:
    stderr.writeLine "[shebangsy] ", language, ": expected <script> [args...]"
    quit(1)

  let script = scriptAndArgs[0]
  let args =
    if scriptAndArgs.len > 1:
      scriptAndArgs[1 .. ^1]
    else:
      @[]

  let langKey = language.toLowerAscii
  let tbl = registryByToken()
  if langKey notin tbl:
    stderr.writeLine "[shebangsy] unsupported language: ", language
    quit(1)
  let r = tbl[langKey]
  case r.warmPathKind
  of wpExecvCached:
    shebangsyWarmPathExec(script, args, r.compileProc, r.execProc)
  of wpSpawnCachedRetryCompile:
    shebangsyInterpretedWarmRun(script, args, r.compileProc, r.execProc)


## Clears every shebangsy cache tree for all supported languages.
proc shebangsyCacheClearHandle(ctx: CliContext) =
  discard ctx
  for r in registryAll():
    let c = r.clearProc()
    if c != 0:
      quit(c)


when isMainModule:
  let ps = commandLineParams()
  if ps.len >= 1:
    let head = ps[0].toLowerAscii
    let tok = registryByToken()
    if head in tok:
      let tail =
        if ps.len > 1:
          ps[1 .. ^1]
        else:
          @[]
      shebangsyLanguageRunHandle(head, tail)

  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "cache-clear",
          "Remove shebangsy caches (all languages by default).",
          shebangsyCacheClearHandle,
        ),
      ],
      description:
        "Single-file multi-language runner (POSIX): language-token dispatch for " &
        "nim/go/mojo/cpp/rust/swift/python3 with metadata-keyed run caches.",
      name: "shebangsy",
      options: @[],
    ),
    commandLineParams(),
  )
