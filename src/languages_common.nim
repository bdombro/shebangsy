#[
languages_common – shared types, cache utilities, and POSIX helpers

Goal: give every language backend the types, filesystem helpers, and process utilities
  they need, so individual language modules stay focused solely on compilation logic.

Why: the cache-keying strategy (mtime + size → unique binary path), the flock-based
  compile guard, and the execv warm-path are identical across all language backends.
  Centralising them here avoids duplication and makes the contract between shebangsy.nim
  and each backend explicit via the CompileProc / ExecProc type aliases.

How:
  - Types: LanguageRunner, FrontmatterDirectives, and the proc-type aliases used across
    the codebase.
  - Cache keys: the absolute script path is flattened to a safe directory name;
    mtime + size form the binary filename so a changed script automatically misses.
  - Compile guard: flock on a sidecar .lock file prevents duplicate compilations when
    the same script is launched concurrently.
  - execv helpers: cacheWarmRunTryExec replaces the process on a cache hit; on ENOENT
    it returns false so the caller proceeds to compile.

```mermaid
flowchart LR
    A[scriptPath] --> B[stat → mtime+size key]
    B --> C{binary exists?}
    C -- hit --> D[execv]
    C -- miss --> E[acquire flock]
    E --> F{binary exists now?}
    F -- hit --> D
    F -- miss --> G[compileProc]
    G --> H[remove stale siblings]
    H --> D
```
]#

import std/[os, osproc, strutils, syncio, times]
from std/posix import Mode, O_CLOEXEC, O_CREAT, O_WRONLY, execv, ENOENT

## POSIX ``open(2)`` for compile lock files (internal).
proc posixOpen(path: cstring; oflag: cint; mode: Mode): cint {.importc: "open", header: "<fcntl.h>",
    sideEffect.}


## POSIX ``flock(2)`` (internal).
proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>", sideEffect.}


## POSIX ``close(2)`` (internal).
proc posixClose(fd: cint): cint {.importc: "close", header: "<unistd.h>", sideEffect.}


## Exclusive lock flag for ``flock``.
const LOCK_EX = 2.cint

type
  WarmPathKind* = enum
    ## Default: try cached artifact with ``execv``; on miss flock then ``compileProc`` then ``execv``.
    wpExecvCached
    ## Interpreted: ``spawn`` + wait; cold miss uses the same flock + ``compileProc`` contract as ``wpExecvCached``.
    wpSpawnCachedRetryCompile

  FrontmatterDirectives* = object
    ## Whitespace-separated tokens from ``#!flags:`` lines.
    flags*: seq[string]
    ## Comma-separated package specs from ``#!requires:`` lines.
    requires*: seq[string]

  ## Compiles ``scriptAbs`` to ``binaryPath``; returns 0 on success.
  CompileProc* = proc(scriptAbs, binaryPath: string): int {.nimcall.}

  ## Executable path plus argument vector for ``execProc`` results.
  ExecTuple* = tuple[exe: string, args: seq[string]]

  ## Builds ``(executable, argv)`` for running a cached binary with script arguments.
  ExecProc* = proc(binaryPath: string; scriptArgs: seq[string]): ExecTuple {.nimcall.}

  LanguageRunner* = object
    ## Extra argv tokens that select this runner (e.g. ``golang``).
    aliases*: seq[string]
    compileProc*: CompileProc
    ## Short human-readable label for this runner (logging, docs, future tooling).
    description*: string
    execProc*: ExecProc
    ## Primary language token (e.g. ``go``).
    key*: string
    ## How ``shebangsy.nim`` runs after resolving the cache key (default ``wpExecvCached``).
    warmPathKind*: WarmPathKind


## Parses ``#!requires:`` and ``#!flags:`` from the first ``maxLines`` lines of a script.
proc frontmatterDirectivesFromSource*(content: string; maxLines = 40): FrontmatterDirectives =
  result = FrontmatterDirectives(requires: @[], flags: @[])
  var lineNum = 0
  for line in content.splitLines:
    inc lineNum
    if lineNum > maxLines:
      break
    if lineNum == 1 and line.startsWith("#!/"):
      continue
    let s = line.strip
    const requiresPrefix = "#!requires:"
    const flagsPrefix = "#!flags:"
    if s.startsWith(requiresPrefix):
      let rest = s[requiresPrefix.len .. ^1].strip
      if rest.len == 0:
        continue
      for part in rest.split(','):
        let w = part.strip
        if w.len > 0:
          result.requires.add w
      continue
    if s.startsWith(flagsPrefix):
      let rest = s[flagsPrefix.len .. ^1].strip
      if rest.len == 0:
        continue
      for tok in rest.splitWhitespace:
        if tok.len > 0:
          result.flags.add tok


## Drops the shebang line and any leading blank lines and ``#!requires:`` / ``#!flags:`` lines.
##
## Blank lines in that prefix are skipped and do not appear at the start of the returned
## string; the result begins at the first line whose trimmed form is non-empty and is not a
## shebangsy directive. Inner blank lines in the remaining body are preserved.
proc stripShebangAndFrontmatterBody*(raw: string): string =
  let lines = raw.splitLines()
  var i = 0
  if i < lines.len and lines[i].startsWith("#!/"):
    inc i
  while i < lines.len:
    let s = lines[i].strip
    if s.len == 0:
      inc i
      continue
    if s.startsWith("#!requires:") or s.startsWith("#!flags:"):
      inc i
      continue
    break
  if i >= lines.len:
    return ""
  lines[i .. ^1].join("\n")


## ``$HOME/.cache/shebangsy`` or quits if ``HOME`` is unset.
proc cacheRootDirGet*(): string =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine "[shebangsy] HOME is not set"
    quit(1)
  home / ".cache" / "shebangsy"


## True when ``SHEBANGSY_PROFILE_WARM`` is set (warm-path timing to stderr).
proc warmProfileEnabled*(): bool =
  getEnv("SHEBANGSY_PROFILE_WARM").len > 0


## If profiling is enabled, prints elapsed ms since ``startedAt`` for ``label``.
proc warmProfileLog*(label: string; startedAt: float) =
  if warmProfileEnabled():
    let elapsedMs = (epochTime() - startedAt) * 1000.0
    stderr.writeLine "[shebangsy:profile] ", label, ": ", elapsedMs, " ms"


## Encodes an arbitrary string as a safe single path segment (non-alnum → ``_``, trim edges).
proc cachePathSegmentEncode*(seg: string): string =
  var lastWasUnderscore = false
  for c in seg:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', '_':
      result.add c
      lastWasUnderscore = c == '_'
    else:
      if result.len > 0 and not lastWasUnderscore:
        result.add '_'
        lastWasUnderscore = true
  while result.len > 0 and result[0] == '_':
    result = result[1 .. ^1]
  while result.len > 0 and result[^1] == '_':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "_"


## Flattens an absolute script path into a unique cache directory name (``__`` between segments).
proc cacheScriptPathFlatten*(scriptAbsPath: string): string =
  var startedSegment = false
  var emittedAnySegment = false
  var lastWasUnderscore = false

  template startSegment() =
    if emittedAnySegment:
      result.add "__"
    emittedAnySegment = true
    startedSegment = true
    lastWasUnderscore = false

  for c in scriptAbsPath:
    let ch =
      if c == '\\':
        '/'
      else:
        c

    if ch == '/':
      if startedSegment:
        while result.len > 0 and result[^1] == '_':
          result.setLen(result.len - 1)
        startedSegment = false
        lastWasUnderscore = false
      continue

    if not startedSegment:
      startSegment()

    case ch
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', '_':
      result.add ch
      lastWasUnderscore = ch == '_'
    else:
      if result.len > 0 and not lastWasUnderscore:
        result.add '_'
        lastWasUnderscore = true

  if startedSegment:
    while result.len > 0 and result[^1] == '_':
      result.setLen(result.len - 1)

  if result.len == 0:
    result = "_"


## Cache binary path from absolute script path using size + mtime in the filename.
proc cacheScriptBinaryPathFromAbsGet*(scriptAbs: string): string =
  let tInfo = epochTime()
  let info = getFileInfo(scriptAbs)
  warmProfileLog("cacheScriptBinaryPathFromAbsGet.getFileInfo", tInfo)
  let mtimeUnix = $toUnix(info.lastWriteTime)
  let size = $info.size
  let tFlatten = epochTime()
  let scriptDir = cacheRootDirGet() / cacheScriptPathFlatten(scriptAbs)
  warmProfileLog("cacheScriptBinaryPathFromAbsGet.cacheScriptPathFlatten", tFlatten)
  scriptDir / ("s_" & size & "_t_" & mtimeUnix)


## Resolves ``scriptPath`` to absolute, then returns ``cacheScriptBinaryPathFromAbsGet``.
proc cacheScriptBinaryPathGet*(scriptPath: string): string =
  let tExpand = epochTime()
  let scriptAbs = expandFilename(scriptPath)
  warmProfileLog("cacheScriptBinaryPathGet.expandFilename", tExpand)
  cacheScriptBinaryPathFromAbsGet(scriptAbs)


## Per-cache-key sidecar directory for build trees (venv, Cargo, pixi, etc.).
proc cacheShadowDirFromBinary*(binaryPath: string): string =
  binaryPath & ".project"


## Prints ``shebangsy: compiling`` once before a cache-miss compile (stdout).
proc shebangsyCompileMissNotice*() =
  stdout.writeLine "shebangsy: compiling"
  flushFile(stdout)


## Ensures ``scriptPath`` is compiled with ``compileProc``; returns cache path and outcome.
proc cacheScriptBinaryEnsure*(scriptPath: string;
    compileProc: proc(scriptAbs, binaryPath: string): int {.nimcall.}):
    tuple[binaryPath: string, compiled: bool, exitCode: int] =
  let scriptAbs = expandFilename(scriptPath)
  if not fileExists(scriptAbs):
    stderr.writeLine "[shebangsy] script not found: ", scriptAbs
    return ("", false, 1)

  let binaryPath = cacheScriptBinaryPathFromAbsGet(scriptAbs)
  createDir(parentDir(binaryPath))

  if fileExists(binaryPath):
    return (binaryPath, false, 0)

  shebangsyCompileMissNotice()
  let compileCode = compileProc(scriptAbs, binaryPath)
  if compileCode != 0:
    return (binaryPath, true, compileCode)

  if not fileExists(binaryPath):
    stderr.writeLine "[shebangsy] expected compiled binary missing: ", binaryPath
    return (binaryPath, true, 1)

  result = (binaryPath, true, 0)


## Removes the entire shebangsy cache root directory (library helper; the binary does
## not expose a cache-clear command—users typically ``rm -rf ~/.cache/shebangsy``).
proc cacheClear*(): int =
  let dir = cacheRootDirGet()
  if not dirExists(dir):
    return 0
  try:
    removeDir(dir, checkDir = false)
    stderr.writeLine "[shebangsy] cleared ", dir
    return 0
  except CatchableError as e:
    stderr.writeLine "[shebangsy] could not clear cache: ", e.msg
    return 1


## Path to the flock file alongside a cached binary.
proc cacheLockPathFromBinary*(binaryPath: string): string =
  binaryPath & ".lock"


## Opens ``lockPath`` and takes an exclusive flock; returns fd or ``-1`` on failure.
proc cacheCompileLockAcquire*(lockPath: string): cint =
  let fd = posixOpen(cstring(lockPath), cint(O_CREAT or O_WRONLY or O_CLOEXEC), Mode(0o600))
  if fd < 0:
    stderr.writeLine "[shebangsy] warning: could not open compile lock: ", lockPath
    return -1.cint
  if flock(fd, LOCK_EX) != 0:
    stderr.writeLine "[shebangsy] warning: flock failed: ", lockPath
    discard posixClose(fd)
    return -1.cint
  fd


## Closes a lock fd from ``cacheCompileLockAcquire`` (no-op if ``fd < 0``).
proc cacheCompileLockRelease*(fd: cint) =
  if fd >= 0:
    discard posixClose(fd)


## Deletes other cache files in ``scriptCacheDir`` except ``keepBinaryPath`` and its lock file.
## For each removed artifact file ``p``, also removes ``cacheShadowDirFromBinary(p)`` when present
## so per-key ``.project`` trees do not accumulate for superseded ``s_*_t_*`` keys.
proc cacheSameScriptStaleRemove*(scriptCacheDir, keepBinaryPath: string) =
  let keepLock = cacheLockPathFromBinary(keepBinaryPath)
  if not dirExists(scriptCacheDir):
    return
  for kind, path in walkDir(scriptCacheDir):
    if kind != pcFile:
      continue
    if path == keepBinaryPath or path == keepLock:
      continue
    try:
      removeFile(path)
      removeDir(cacheShadowDirFromBinary(path), checkDir = false)
    except CatchableError:
      discard


## Runs ``cmd`` with ``args``; waits for exit; returns status (1 if spawn fails).
proc processExitCodeWait*(cmd: string; args: openArray[string]; workingDir = ""): int =
  try:
    let opts = {poParentStreams}
    let process =
      if workingDir.len == 0:
        startProcess(cmd, args = args, options = opts)
      else:
        startProcess(cmd, args = args, workingDir = workingDir, options = opts)
    result = waitForExit(process)
    close(process)
  except OSError as e:
    stderr.writeLine "[shebangsy] failed to start process: ", cmd
    stderr.writeLine "[shebangsy] ", e.msg
    result = 1


## ``processExitCodeWait`` for a cached executable with script arguments.
proc runBinaryWithArgs*(binaryPath: string; scriptArgs: seq[string]): int =
  processExitCodeWait(binaryPath, scriptArgs)


## Replaces this process with ``exe`` via ``execv``; on failure prints and quits 126.
proc cacheWarmRunExec*(exe: string; args: openArray[string]) =
  flushFile(stdout)
  flushFile(stderr)
  var cmdline = newSeqOfCap[string](1 + args.len)
  cmdline.add exe
  for i in 0 ..< args.len:
    cmdline.add args[i]
  let argvC = allocCStringArray(cmdline)
  discard execv(cstring(exe), argvC)
  stderr.writeLine "[shebangsy] exec failed: ", exe, ": ", osErrorMsg(osLastError())
  quit(126)


## Tries ``execv`` for warm path; returns false only on ``ENOENT``; otherwise exec or quit 126.
proc cacheWarmRunTryExec*(exe: string; args: openArray[string]): bool =
  flushFile(stdout)
  flushFile(stderr)
  let tExec = epochTime()
  var cmdline = newSeqOfCap[string](1 + args.len)
  cmdline.add exe
  for i in 0 ..< args.len:
    cmdline.add args[i]
  let argvC = allocCStringArray(cmdline)
  warmProfileLog("cacheWarmRunTryExec.execv", tExec)
  discard execv(cstring(exe), argvC)
  let err = osLastError()
  if err == OSErrorCode(ENOENT):
    return false
  stderr.writeLine "[shebangsy] exec failed: ", exe, ": ", osErrorMsg(err)
  quit(126)


## True if ``findExe(tool)`` succeeds; else prints hint and returns false.
proc toolEnsureOnPath*(tool, installHint: string): bool =
  if findExe(tool).len > 0:
    return true
  stderr.writeLine "[shebangsy] required tool not found on PATH: ", tool
  if installHint.len > 0:
    stderr.writeLine "[shebangsy] install hint: ", installHint
  false
