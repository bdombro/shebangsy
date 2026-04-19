#[
shebangsy – CLI entry point and warm-path orchestration

Goal: parse argv as ``shebangsy <language> <script> [args...]`` and dispatch to the
  correct language runner. All language backends share the same binary-caching
  warm-path, so it lives here rather than in each language module.

Why: keeping the hot path (stat → cache key → execv) in one place means each language
  module only needs to supply a compile proc and an exec proc. The flock/execv machinery
  is not duplicated.

How:
  1. Require at least two argv tokens; validate the first is a known language token.
  2. Resolve ``LanguageRunner`` once from ``registryByToken()`` and call shebangsyDispatch.
  shebangsyWarmPathExec drives the hot path:
    stat script → derive cache key (size+mtime) → try execv on cached binary →
    acquire flock → compile if still missing → execv.

```mermaid
flowchart TD
  A[argv] --> B{"len >= 2 and\ntoken in registry?"}
  B -- yes --> C[shebangsyDispatch]
  B -- no  --> D["stderr usage + quit(1)"]
  C --> E[shebangsyWarmPathExec or shebangsyInterpretedWarmRun]
```

POSIX only (macOS, Linux, and similar). Windows is not supported.
]#

import std/[os, strutils, tables, times]
import ./languages_common
import ./languages_registry


const ShebangsyUsage = "usage: shebangsy <language> <script> [args...]"


## Resolves ``scriptPath`` to an absolute path or prints an error and exits.
proc expandScriptPathOrQuit(scriptPath: string): string =
  try:
    expandFilename(scriptPath)
  except CatchableError as e:
    stderr.writeLine "[shebangsy] cannot read script: ", scriptPath, ": ", e.msg
    quit(1)


## Unified warm-path runner: stat → cache lookup → compile if needed → execv.
## All languages share this orchestration after backends provide compile and exec procs.
proc shebangsyWarmPathExec(
    scriptPath: string; scriptArgs: seq[string]; compileProc: CompileProc; execProc: ExecProc) =
  let tExpand = epochTime()
  let scriptAbs = expandScriptPathOrQuit(scriptPath)
  warmProfileLog("shebangsyWarmPathExec.expandFilename", tExpand)

  let tBinary = epochTime()
  let binaryPath = cacheScriptBinaryPathFromAbsGet(scriptAbs)
  warmProfileLog("shebangsyWarmPathExec.cacheScriptBinaryPathGet", tBinary)
  let (warmExe, warmArgs) = execProc(binaryPath, scriptArgs)
  if cacheWarmRunTryExec(warmExe, warmArgs):
    return

  createDir(parentDir(binaryPath))
  let lockPath = cacheLockPathFromBinary(binaryPath)
  # Lock is intentionally not released here: execv replaces this process and the OS
  # releases all file descriptors. shebangsyInterpretedWarmRun must release explicitly
  # because it spawns a child instead of exec-ing.
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
  let scriptAbs = expandScriptPathOrQuit(scriptPath)

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


## Runs one backend after argv has been parsed to a resolved ``LanguageRunner``.
proc shebangsyDispatch(r: LanguageRunner; scriptAndArgs: seq[string]) =
  if scriptAndArgs.len == 0:
    stderr.writeLine "[shebangsy] ", r.key, ": expected <script> [args...]"
    quit(1)

  let script = scriptAndArgs[0]
  let args =
    if scriptAndArgs.len > 1:
      scriptAndArgs[1 .. ^1]
    else:
      @[]

  case r.warmPathKind
  of wpExecvCached:
    shebangsyWarmPathExec(script, args, r.compileProc, r.execProc)
  of wpSpawnCachedRetryCompile:
    shebangsyInterpretedWarmRun(script, args, r.compileProc, r.execProc)


when isMainModule:
  let ps = commandLineParams()
  if ps.len < 2:
    stderr.writeLine ShebangsyUsage
    quit(1)
  let lang = ps[0].toLowerAscii
  let tok = registryByToken()
  if lang notin tok:
    stderr.writeLine "[shebangsy] unsupported language: ", ps[0]
    stderr.writeLine ShebangsyUsage
    quit(1)
  shebangsyDispatch(tok[lang], ps[1 .. ^1])
