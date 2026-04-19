#[
languages/mojo – compile and run Mojo scripts via Pixi (conda-based environment manager)

Goal: let shebangsy execute .mojo scripts, optionally with PyPI dependencies, by managing
  a per-script Pixi project that installs Mojo from the Modular conda channel.

Why: Mojo is distributed exclusively through the Modular conda channel and requires
  Python 3.11 in the same environment; Pixi is the only practical way to reproduce
  that environment without polluting the user's system Python or requiring manual conda
  setup.

How:
  1. Parse #!requires: specs (treated as PyPI deps; Mojo itself is always added) and
     optional #!version: (pixi version constraint for the mojo conda dependency).
  2. Write a pixi.toml with Modular + conda-forge channels and an optional
     [pypi-dependencies] table under ``cacheShadowDirFromBinary(binaryPath)``.
  3. Copy the script source to projectDir/main.mojo.
  4. pixi run mojo build → copy the output binary to binaryPath.
  5. At runtime: execv the cached binary directly when there are no PyPI deps; when
     [pypi-dependencies] is present, run ``pixi run mojo run`` so Python interop sees
     the pixi environment.

```mermaid
flowchart TD
    A[script.mojo] --> B[parseDirectives]
    B --> C[write pixi.toml + main.mojo]
    C --> D[pixi run mojo build]
    D --> E[copy to binaryPath]
    E --> F{has PyPI deps?}
    F -- yes --> G[pixi run mojo run]
    F -- no --> H[execv binary]
```
]#

import std/[os, strutils]
import ../languages_common


const mojoCondaChannel = "https://conda.modular.com/max-nightly"
const mojoVersionDefault = ">=0.26.0,<0.27"


## One ``pixi.toml`` ``[pypi-dependencies]`` line for a ``name@version`` spec.
proc pixiPyPiDependencyLine(pkgSpec: string): string =
  let parts = pkgSpec.split('@', maxsplit = 1)
  let name = parts[0].strip
  if name.len == 0:
    return ""
  if parts.len == 1 or parts[1].strip.len == 0:
    return name & " = \"*\""
  name & " = \"==" & parts[1].strip & "\""


## Pixi ``platforms = [...]`` token for the current OS and CPU.
proc pixiHostPlatformGet(): string =
  when defined(macosx):
    when defined(arm64):
      "osx-arm64"
    elif defined(amd64) or defined(x86_64):
      "osx-64"
    else:
      stderr.writeLine "[shebangsy:mojo] unsupported macOS arch for pixi host platform"
      quit(1)
  elif defined(linux):
    when defined(arm64):
      "linux-aarch64"
    elif defined(amd64) or defined(x86_64):
      "linux-64"
    else:
      stderr.writeLine "[shebangsy:mojo] unsupported Linux arch for pixi host platform"
      quit(1)
  else:
    stderr.writeLine "[shebangsy:mojo] unsupported host OS for pixi host platform"
    quit(1)


## Writes ``projectDir/pixi.toml`` with Modular + conda-forge channels and optional PyPI deps.
proc pixiProjectWrite(projectDir: string; pkgs: seq[string]; mojoVersion = "") =
  var depsBlock = ""
  if pkgs.len > 0:
    depsBlock.add "\n[pypi-dependencies]\n"
    for spec in pkgs:
      let line = pixiPyPiDependencyLine(spec)
      if line.len > 0:
        depsBlock.add line & "\n"

  let ver = if mojoVersion.len > 0: mojoVersion else: mojoVersionDefault
  let condaChannels =
    "channels = [\"" & mojoCondaChannel & "\", \"conda-forge\"]"
  let manifest = @[
    "[workspace]",
    "authors = [\"shebangsy\"]",
    condaChannels,
    "name = \"shebangsy-mojo-cache\"",
    "platforms = [\"" & pixiHostPlatformGet() & "\"]",
    "version = \"0.1.0\"",
    "",
    "[dependencies]",
    "mojo = \"" & ver & "\"",
    "python = \"==3.11\"",
  ].join("\n")
  writeFile(projectDir / "pixi.toml", manifest & depsBlock)


## True when ``manifest`` exists and declares a ``[pypi-dependencies]`` table.
proc pixiManifestHasPyDeps(manifest: string): bool =
  if not fileExists(manifest):
    return false
  try:
    readFile(manifest).contains("[pypi-dependencies]")
  except CatchableError:
    false


## Runs ``pixi run mojo build`` in ``projectDir`` and copies ``main`` to ``binaryPath``.
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


## Exec tuple: direct execv when no PyPI deps; ``pixi run mojo run`` when Python interop needs the env.
proc mojoExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  let shadow = cacheShadowDirFromBinary(binaryPath)
  let manifest = shadow / "pixi.toml"
  if pixiManifestHasPyDeps(manifest):
    let pixiExe = findExe("pixi")
    if pixiExe.len > 0:
      return (pixiExe, @["run", "--manifest-path", manifest, "mojo", "run", binaryPath] & scriptArgs)
    stderr.writeLine "[shebangsy:mojo] pixi not found on PATH; running binary directly (PyPI deps may be unavailable)"
  (binaryPath, scriptArgs)


## Materializes the pixi project and builds ``main.mojo`` to the cache binary path.
proc mojoCompile*(scriptAbs, binaryPath: string): int =
  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:mojo] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let directives = frontmatterDirectivesFromSource(raw)
  let shadow = cacheShadowDirFromBinary(binaryPath)
  createDir(shadow)
  writeFile(shadow / "main.mojo", raw)
  pixiProjectWrite(shadow, directives.requires, directives.version)

  mojoCompileWithPixi(shadow, binaryPath)


## Registers the Mojo language runner.
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @[],
    compileProc: mojoCompile,
    description: "Compile and run Mojo scripts",
    execProc: mojoExecTupleForBinary,
    key: "mojo",
  )
