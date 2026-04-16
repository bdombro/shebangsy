import std/[os, osproc, strutils, times]

type
  RunProc* = proc(scriptPath: string; scriptArgs: seq[string]): int {.nimcall.}
  ClearProc* = proc(): int {.nimcall.}

  LanguageRunner* = object
    key*: string
    aliases*: seq[string]
    description*: string
    runProc*: RunProc
    clearProc*: ClearProc


proc cacheRootDirGet*(): string =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine "[shebangsy] HOME is not set"
    quit(1)
  home / ".cache" / "shebangsy"


proc cachePathSegmentEncode*(seg: string): string =
  for c in seg:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', '_':
      result.add c
    else:
      result.add '_'
  while result.contains "__":
    result = result.replace("__", "_")
  result = result.strip(chars = {'_'})
  if result.len == 0:
    result = "_"


proc cacheScriptPathFlatten*(scriptAbsPath: string): string =
  var normPath = scriptAbsPath.replace("\\", "/")
  var segs: seq[string] = @[]
  if not normPath.startsWith("/"):
    normPath = "/" & normPath
  for part in normPath.split('/'):
    if part.len == 0:
      continue
    segs.add cachePathSegmentEncode(part)
  result = segs.join("__")


proc cacheScriptBinaryPathGet*(languageKey, scriptPath: string): string =
  let scriptAbs = expandFilename(scriptPath)
  let info = getFileInfo(scriptAbs)
  let mtimeUnix = $toUnix(info.lastWriteTime)
  let size = $info.size
  let scriptDir = cacheRootDirGet() / languageKey / cacheScriptPathFlatten(scriptAbs)
  scriptDir / ("s_" & size & "_t_" & mtimeUnix)


proc cacheScriptBinaryEnsure*(languageKey, scriptPath: string;
    compileProc: proc(scriptAbs, binaryPath: string): int {.nimcall.}):
    tuple[binaryPath: string, compiled: bool, exitCode: int] =
  let scriptAbs = expandFilename(scriptPath)
  if not fileExists(scriptAbs):
    stderr.writeLine "[shebangsy] script not found: ", scriptAbs
    return ("", false, 1)

  let binaryPath = cacheScriptBinaryPathGet(languageKey, scriptAbs)
  createDir(parentDir(binaryPath))

  if fileExists(binaryPath):
    return (binaryPath, false, 0)

  let compileCode = compileProc(scriptAbs, binaryPath)
  if compileCode != 0:
    return (binaryPath, true, compileCode)

  if not fileExists(binaryPath):
    stderr.writeLine "[shebangsy] expected compiled binary missing: ", binaryPath
    return (binaryPath, true, 1)

  result = (binaryPath, true, 0)


proc cacheLanguageClear*(languageKey: string): int =
  let dir = cacheRootDirGet() / languageKey
  if not dirExists(dir):
    return 0
  try:
    removeDir(dir, checkDir = false)
    stderr.writeLine "[shebangsy] cleared ", dir
    return 0
  except CatchableError as e:
    stderr.writeLine "[shebangsy] could not clear cache: ", e.msg
    return 1


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


proc runBinaryWithArgs*(binaryPath: string; scriptArgs: seq[string]): int =
  processExitCodeWait(binaryPath, scriptArgs)


proc toolEnsureOnPath*(tool, installHint: string): bool =
  if findExe(tool).len > 0:
    return true
  stderr.writeLine "[shebangsy] required tool not found on PATH: ", tool
  if installHint.len > 0:
    stderr.writeLine "[shebangsy] install hint: ", installHint
  false
