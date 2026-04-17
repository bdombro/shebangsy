#[
languages/nim – compile and run single-file Nim scripts with Nimble/pixi support

Goal: let shebangsy execute .nim files that declare #!requires: Nimble package
  dependencies, automatically installing them and injecting --path: flags into nim c.

Why: Nim filenames must be valid module identifiers; scripts with hyphens or other
  special characters need a sanitised copy under ``cacheShadowDirFromBinary(binaryPath)``
  (same per-key sidecar as Rust/Go). Nimble package paths must be resolved and threaded
  in as --path: flags. ``nimPixiTomlPathFind`` walks from the original ``scriptAbs``, so
  pixi discovery is unchanged when the staged file lives in the shadow tree. When a
  pixi.toml is found above the script, pixi run nim c is used to stay inside the managed
  environment.

How:
  1. Parse #!requires: specs; run nimble install -Y for any missing package.
  2. Collect --path: flags from nimble path for each installed package.
  3. If the script filename is not a valid Nim module identifier (or would shadow a
     require), write a sanitised copy under the per-key shadow directory.
  4. Invoke nim c (or pixi run nim c) with all flags, outputting to binaryPath. On compile
     failure only, remove the shadow directory so the next compile starts clean.

```mermaid
flowchart TD
    A[script.nim] --> B[parse #!requires: / #!flags:]
    B --> C[nimble install + path flags]
    C --> D{filename valid module?}
    D -- yes --> E[nim c -o binaryPath]
    D -- no --> F[copy to shadow/safe_name.nim]
    F --> E
```
]#

import std/[os, osproc, strutils]
import ../languages_common

## True when ``stem`` is a valid Nim identifier stem.
proc nimIdentStemIsValid(stem: string): bool =
  if stem.len == 0:
    return false
  case stem[0]
  of 'a' .. 'z', 'A' .. 'Z', '_': discard
  of '0' .. '9': return false
  else: return false
  for i in 1 ..< stem.len:
    case stem[i]
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_': discard
    else: return false
  true


## Reads ``#!flags:`` directives from the first 40 lines of source and returns the
## whitespace-separated tokens as a flat list passed to ``nim c``.
proc nimFlagsFromSource(content: string): seq[string] =
  frontmatterDirectivesFromSource(content).flags


## Returns true when the path has a ``.nim`` extension and a basename that is a valid Nim
## module identifier (so the compiler can accept it without a temp rename).
proc nimModuleFilenameIsCompatible(path: string): bool =
  let (_, name, ext) = splitFile(path)
  ext == ".nim" and nimIdentStemIsValid(name)


## Reads ``#!requires: pkg1,pkg2@ver`` lines from the first 40 lines of source and returns
## the package specs as a flat list. Multiple directives are merged in order.
proc nimRequiresFromSource(content: string): seq[string] =
  frontmatterDirectivesFromSource(content).requires


## True when ``scriptPath`` basename equals a nimble package stem from ``requireSpecs`` (so the
## script module would shadow ``import <pkg>`` during compilation).
proc nimModuleStemShadowsRequire(scriptPath: string; requireSpecs: seq[string]): bool =
  let (_, stem, ext) = splitFile(scriptPath)
  if ext != ".nim":
    return false
  for spec in requireSpecs:
    let p = spec.split('@')[0].strip
    if p.len > 0 and stem == p:
      return true
  false


## Ensures every package spec in ``pkgs`` is installed via ``nimble install -Y`` (output streams
## live when a package is missing) and returns a ``--path:dir`` flag for each resolved location.
## Exits with a message if nimble is not on PATH or any install or path-lookup fails.
proc nimRequiresInstallPaths(pkgs: seq[string]): seq[string] =
  result = @[]
  if pkgs.len == 0:
    return
  let nimbleExe = findExe("nimble")
  if nimbleExe.len == 0:
    stderr.writeLine "[nimr] nimble is not on PATH; needed for # requires: ", pkgs.join(", ")
    stderr.writeLine "[nimr] install Nim/Nimble: https://nim-lang.org/install.html"
    quit(1)
  for pkg in pkgs:
    let pkgStem = pkg.split('@')[0].strip
    let (pathPre, pathPreCode) = execCmdEx(nimbleExe & " --silent path " & pkgStem)
    if pathPreCode != 0 or pathPre.strip.len == 0:
      let installCode = processExitCodeWait(nimbleExe, ["install", "-Y", pkg], "")
      if installCode != 0:
        stderr.writeLine "[nimr] nimble install failed for: ", pkg
        quit(1)
    let (pathOut, pathCode) = execCmdEx(nimbleExe & " --silent path " & pkgStem)
    if pathCode != 0 or pathOut.strip.len == 0:
      stderr.writeLine "[nimr] nimble path failed for: ", pkgStem
      quit(1)
    for line in pathOut.splitLines:
      let w = line.strip
      if w.len > 0:
        result.add "--path:" & w
        break


## Walks up the directory tree from ``walkFromFile`` and returns the first ``pixi.toml`` found,
## or an empty string if none exists.
proc nimPixiTomlPathFind(walkFromFile: string): string =
  var dir = parentDir(expandFilename(absolutePath(walkFromFile)))
  while true:
    let manifest = dir / "pixi.toml"
    if fileExists(manifest):
      return manifest
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  ""


## Compiles ``nimSource`` to ``binaryPath``. Uses ``pixi run nim c`` when a ``pixi.toml`` is found
## above the script; otherwise invokes ``nim c`` directly.
proc nimCompileInvoke(nimSource: string; scriptPathForPixiWalk: string; binaryPath: string;
    nimExtraFlags: openArray[string]): int =
  let workDir = parentDir(nimSource)
  var compileTail = @["c"]
  for f in nimExtraFlags:
    compileTail.add f
  compileTail.add @[
    "--verbosity:0",
    "--hints:off",
    "-o:" & binaryPath,
    nimSource,
  ]
  let manifest = nimPixiTomlPathFind(scriptPathForPixiWalk)
  if manifest.len > 0:
    let pixiExe = findExe("pixi")
    if pixiExe.len == 0:
      stderr.writeLine "[nimr] pixi.toml found (", manifest, ") but pixi is not on PATH"
      stderr.writeLine "[nimr] install pixi: https://pixi.sh"
      quit(1)
    let args = @["run", "--manifest-path", manifest, "nim"] & compileTail
    return processExitCodeWait(pixiExe, args, workDir)
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    stderr.writeLine "[nimr] nim is not on PATH"
    stderr.writeLine "[nimr] install Nim, or add pixi.toml + nim via pixi (https://pixi.sh)"
    quit(1)
  processExitCodeWait(nimExe, compileTail, workDir)


## Derives the base name for the synthesized ``.nim`` copy when the original filename is not a
## valid Nim module identifier (e.g. ``nimr-neo`` → ``nimr_neo``).
proc nimStemForNaming(path: string): string =
  let (_, name, ext) = splitFile(path)
  if ext == ".nim":
    name
  else:
    name & ext


## Replaces any character that is not a Nim identifier character with ``_``, collapses runs of
## underscores, strips leading/trailing underscores, and prepends ``_`` if the stem starts with
## a digit.
proc nimStemSanitize(stem: string): string =
  var r = ""
  for c in stem:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_':
      r.add c
    else:
      r.add '_'
  while r.contains "__":
    r = r.replace("__", "_")
  r = r.strip(chars = {'_'})
  if r.len == 0:
    r = "script"
  if r[0] in '0' .. '9':
    r = "_" & r
  r


## Reads the script, resolves nimble paths/flags, may copy to a valid module filename under
## ``cacheShadowDirFromBinary(binaryPath)``, then compiles. On failure, removes that shadow
## dir only when staging was used; on success the shadow is left for reuse.
proc nimCompile*(scriptAbs, binaryPath: string): int =
  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[nimr] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let requireSpecs = nimRequiresFromSource(raw)
  let requirePaths = nimRequiresInstallPaths(requireSpecs)
  let allFlags = requirePaths & nimFlagsFromSource(raw)

  var nimSource = scriptAbs
  var tmpRoot = ""
  if not nimModuleFilenameIsCompatible(scriptAbs) or nimModuleStemShadowsRequire(
      scriptAbs, requireSpecs):
    tmpRoot = cacheShadowDirFromBinary(binaryPath)
    createDir(tmpRoot)
    let baseStem = nimStemSanitize(nimStemForNaming(scriptAbs))
    let fileStem =
      if nimModuleStemShadowsRequire(scriptAbs, requireSpecs):
        nimStemSanitize(baseStem & "_shebangsy_script")
      else:
        baseStem
    nimSource = tmpRoot / (fileStem & ".nim")
    writeFile(nimSource, raw)

  let code = nimCompileInvoke(nimSource, scriptAbs, binaryPath, allFlags)
  if tmpRoot.len > 0 and code != 0:
    try:
      removeDir(tmpRoot, checkDir = false)
    except CatchableError:
      discard
  code


## Exec tuple for a cached Nim binary.
proc nimExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  (binaryPath, scriptArgs)


## Registers the Nim language runner.
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @[],
    compileProc: nimCompile,
    description: "Compile and run Nim scripts (nimble/pixi aware)",
    execProc: nimExecTupleForBinary,
    key: "nim",
  )
