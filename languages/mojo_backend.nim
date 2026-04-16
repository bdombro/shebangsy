import std/[os, strutils]
from std/posix import Mode, O_CLOEXEC, O_CREAT, O_WRONLY
import ./common

proc posixOpen(path: cstring; oflag: cint; mode: Mode): cint {.importc: "open", header: "<fcntl.h>",
    sideEffect.}
proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>", sideEffect.}
proc posixClose(fd: cint): cint {.importc: "close", header: "<unistd.h>", sideEffect.}

const LOCK_EX = 2.cint


proc cacheLockPathFromBinary(binaryPath: string): string =
  binaryPath & ".lock"


proc cacheProjectDirFromBinary(binaryPath: string): string =
  binaryPath & ".project"


proc cacheCompileLockAcquire(lockPath: string): cint =
  let fd = posixOpen(cstring(lockPath), cint(O_CREAT or O_WRONLY or O_CLOEXEC), Mode(0o600))
  if fd < 0:
    stderr.writeLine "[shebangsy:mojo] warning: could not open compile lock: ", lockPath
    return -1.cint
  if flock(fd, LOCK_EX) != 0:
    stderr.writeLine "[shebangsy:mojo] warning: flock failed: ", lockPath
    discard posixClose(fd)
    return -1.cint
  fd


proc cacheSameScriptStaleRemove(scriptCacheDir, keepBinaryPath: string) =
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
    except CatchableError:
      discard


proc mojoCacheClear(): int =
  cacheLanguageClear("mojo")


proc mojoRequiresFromSource(content: string): seq[string] =
  result = @[]
  var lineNum = 0
  for line in content.splitLines:
    inc lineNum
    if lineNum > 40:
      break
    if line.startsWith("#!"):
      continue
    let s = line.strip
    const prefix = "# requires:"
    if not s.startsWith(prefix):
      continue
    for part in s[prefix.len .. ^1].split(','):
      let w = part.strip
      if w.len > 0:
        result.add w


proc pixiPyPiDependencyLine(pkgSpec: string): string =
  let parts = pkgSpec.split('@', maxsplit = 1)
  let name = parts[0].strip
  if name.len == 0:
    return ""
  if parts.len == 1 or parts[1].strip.len == 0:
    return name & " = \"*\""
  name & " = \"==" & parts[1].strip & "\""


proc pixiHostPlatformGet(): string =
  when defined(macosx):
    when defined(arm64):
      "osx-arm64"
    elif defined(amd64) or defined(x86_64):
      "osx-64"
    else:
      stderr.writeLine "[shebangsy:mojo] unsupported macOS architecture for pixi host platform"
      quit(1)
  elif defined(linux):
    when defined(arm64):
      "linux-aarch64"
    elif defined(amd64) or defined(x86_64):
      "linux-64"
    else:
      stderr.writeLine "[shebangsy:mojo] unsupported Linux architecture for pixi host platform"
      quit(1)
  else:
    stderr.writeLine "[shebangsy:mojo] unsupported host OS for pixi host platform"
    quit(1)


proc pixiProjectWrite(projectDir: string; pkgs: seq[string]) =
  var depsBlock = ""
  if pkgs.len > 0:
    depsBlock.add "\n[pypi-dependencies]\n"
    for spec in pkgs:
      let line = pixiPyPiDependencyLine(spec)
      if line.len > 0:
        depsBlock.add line & "\n"

  let manifest = @[
    "[workspace]",
    "authors = [\"shebangsy\"]",
    "channels = [\"https://conda.modular.com/max-nightly\", \"conda-forge\"]",
    "name = \"shebangsy-mojo-cache\"",
    "platforms = [\"" & pixiHostPlatformGet() & "\"]",
    "version = \"0.1.0\"",
    "",
    "[dependencies]",
    "mojo = \">=0.26.0,<0.27\"",
    "python = \"==3.11\"",
  ].join("\n")
  writeFile(projectDir / "pixi.toml", manifest & depsBlock)


proc pixiManifestHasPyDeps(manifest: string): bool =
  if not fileExists(manifest):
    return false
  try:
    readFile(manifest).contains("[pypi-dependencies]")
  except CatchableError:
    false


proc mojoCompileWithPixi(projectDir: string; binaryPath: string): int =
  let pixiExe = findExe("pixi")
  if pixiExe.len == 0:
    stderr.writeLine "[shebangsy:mojo] pixi is not on PATH"
    stderr.writeLine "[shebangsy:mojo] install hint: https://pixi.sh"
    return 1

  let manifest = projectDir / "pixi.toml"
  let buildCode = processExitCodeWait(
    pixiExe,
    ["run", "--manifest-path", manifest, "mojo", "build", "main.mojo"],
    projectDir,
  )
  if buildCode != 0:
    return buildCode

  let builtBinary = projectDir / "main"
  if not fileExists(builtBinary):
    stderr.writeLine "[shebangsy:mojo] expected build output not found: ", builtBinary
    return 1

  copyFile(builtBinary, binaryPath)
  try:
    setFilePermissions(binaryPath, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
        fpOthersRead, fpOthersExec})
  except CatchableError:
    discard
  0


proc mojoRunInPixiEnv(binaryPath: string; scriptArgs: seq[string]): int =
  let projectDir = cacheProjectDirFromBinary(binaryPath)
  let manifest = projectDir / "pixi.toml"
  if pixiManifestHasPyDeps(manifest):
    let pixiExe = findExe("pixi")
    if pixiExe.len == 0:
      stderr.writeLine "[shebangsy:mojo] pixi is not on PATH; required for cached runtime"
      stderr.writeLine "[shebangsy:mojo] install hint: https://pixi.sh"
      return 1
    var args = @["run", "--manifest-path", manifest, "mojo", "run", projectDir / "main.mojo"]
    if scriptArgs.len > 0:
      args.add "--"
      for arg in scriptArgs:
        args.add arg
    return processExitCodeWait(pixiExe, args)

  runBinaryWithArgs(binaryPath, scriptArgs)


proc mojoRun(scriptPath: string; scriptArgs: seq[string]): int =
  if not toolEnsureOnPath("pixi", "https://pixi.sh"):
    return 1

  let scriptAbs = expandFilename(scriptPath)
  if not fileExists(scriptAbs):
    stderr.writeLine "[shebangsy:mojo] script not found: ", scriptAbs
    return 1

  let binaryPath = cacheScriptBinaryPathGet("mojo", scriptAbs)
  let scriptCacheDir = parentDir(binaryPath)
  createDir(scriptCacheDir)

  if fileExists(binaryPath):
    return mojoRunInPixiEnv(binaryPath, scriptArgs)

  let lockPath = cacheLockPathFromBinary(binaryPath)
  discard cacheCompileLockAcquire(lockPath)
  if fileExists(binaryPath):
    return mojoRunInPixiEnv(binaryPath, scriptArgs)

  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:mojo] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let requires = mojoRequiresFromSource(raw)
  let projectDir = cacheProjectDirFromBinary(binaryPath)
  createDir(projectDir)
  writeFile(projectDir / "main.mojo", raw)
  pixiProjectWrite(projectDir, requires)

  let compileCode = mojoCompileWithPixi(projectDir, binaryPath)
  if compileCode != 0:
    return compileCode

  cacheSameScriptStaleRemove(scriptCacheDir, binaryPath)

  mojoRunInPixiEnv(binaryPath, scriptArgs)


proc createRunner*(): LanguageRunner =
  LanguageRunner(
    key: "mojo",
    aliases: @[],
    description: "Compile and run Mojo scripts",
    runProc: mojoRun,
    clearProc: mojoCacheClear,
  )
