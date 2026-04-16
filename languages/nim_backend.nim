import std/[os]
import ./common


proc nimCacheClear(): int =
  cacheLanguageClear("nim")


proc nimCompile(scriptAbs, binaryPath: string): int =
  processExitCodeWait(
    "nim",
    ["c", "-d:release", "--hints:off", "--verbosity:0", "-o:" & binaryPath, scriptAbs],
    parentDir(scriptAbs)
  )


proc nimRun(scriptPath: string; scriptArgs: seq[string]): int =
  if not toolEnsureOnPath("nim", "https://nim-lang.org/install.html"):
    return 1

  let (binaryPath, _, code) = cacheScriptBinaryEnsure("nim", scriptPath, nimCompile)
  if code != 0:
    return code

  runBinaryWithArgs(binaryPath, scriptArgs)


proc createRunner*(): LanguageRunner =
  LanguageRunner(
    key: "nim",
    aliases: @[],
    description: "Compile and run Nim scripts",
    runProc: nimRun,
    clearProc: nimCacheClear,
  )
