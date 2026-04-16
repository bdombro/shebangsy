import std/[os, strutils]
import ./common


proc goCacheClear(): int =
  cacheLanguageClear("go")


proc goCompile(scriptAbs, binaryPath: string): int =
  let goExe = findExe("go")
  if goExe.len == 0:
    stderr.writeLine "[shebangsy] go compiler not found on PATH"
    return 1

  let scriptContent = readFile(scriptAbs)
  let lines = scriptContent.splitLines()
  let normalizedSource =
    if scriptContent.startsWith("#!") and lines.len > 1:
      lines[1 .. ^1].join("\n") & "\n"
    elif scriptContent.startsWith("#!"):
      ""
    else:
      scriptContent

  let tmpDir = getTempDir() / ("shebangsy-go-build-" & cachePathSegmentEncode(scriptAbs))
  createDir(tmpDir)
  let stagedPath = tmpDir / "main.go"
  writeFile(stagedPath, normalizedSource)
  processExitCodeWait(goExe, ["build", "-o", binaryPath, stagedPath])


proc goRun(scriptPath: string; scriptArgs: seq[string]): int =
  if not toolEnsureOnPath("go", "https://go.dev/doc/install"):
    return 1

  let (binaryPath, _, code) = cacheScriptBinaryEnsure("go", scriptPath, goCompile)
  if code != 0:
    return code

  runBinaryWithArgs(binaryPath, scriptArgs)


proc createRunner*(): LanguageRunner =
  LanguageRunner(
    key: "go",
    aliases: @["golang"],
    description: "Compile and run Go scripts",
    runProc: goRun,
    clearProc: goCacheClear,
  )
