#[
languages/cpp – compile C++ scripts via CMake with optional CLI11 dependency

Goal: let shebangsy execute single-file .cpp scripts, optionally pulling in CLI11 via
  CMake FetchContent when #!requires: cli11 is declared.

Why: C++ has no standard package manager; CMake + FetchContent is the most portable
  approach for fetching a header-only dependency at build time. A shared workspace
  directory is reused across script runs to avoid repeated cmake configure steps.

How:
  1. Generate a CMakeLists.txt from the #!requires: spec (cli11 only for now).
  2. Write the stripped source as src/main.cpp inside the shared workspace at
     ~/.cache/shebangsy/cpp-workspace.
  3. cmake configure (-S wsDir -B buildDir) → cmake build → copy to binaryPath.
  A workspace-level flock prevents concurrent cmake runs from corrupting state.

```mermaid
flowchart TD
    A[script.cpp] --> B[parse #!requires:]
    B --> C[generate CMakeLists.txt]
    C --> D[write src/main.cpp in workspace]
    D --> E[flock workspace]
    E --> F[cmake configure]
    F --> G[cmake build]
    G --> H[copy to binaryPath]
```
]#

import std/[os, strutils]
import ../languages_common

## Normalizes a CLI11 version string to a ``v``-prefixed git tag when missing.
proc cli11GitTagNormalize(ver: string): string =
  let v = ver.strip
  if v.len == 0:
    return "v2.4.1"
  if v[0] in {'v', 'V'}:
    return v
  "v" & v


## Emits ``CMakeLists.txt`` body for supported ``#!requires:`` (cli11 only); empty string on error.
proc cppCMakeListsGenerate(requires: seq[string]): string =
  var fetchBlock = ""
  var linkBlock = ""
  for spec in requires:
    let parts = spec.split('@', maxsplit = 1)
    let pkg = parts[0].strip.toLowerAscii
    if pkg != "cli11":
      stderr.writeLine "[shebangsy:cpp] unsupported #!requires: " &
        "(only cli11 is supported): ", spec
      return ""
    let ver =
      if parts.len > 1:
        parts[1].strip
      else:
        "2.4.1"
    let tag = cli11GitTagNormalize(ver)
    let repo = "https://github.com/CLIUtils/CLI11.git"
    fetchBlock =
      "FetchContent_Declare(\n  cli11\n  GIT_REPOSITORY " & repo & "\n  GIT_TAG " & tag &
      "\n)\nFetchContent_MakeAvailable(cli11)\n"
    linkBlock = "target_link_libraries(shebangsy_cpp_app PRIVATE CLI11::CLI11)\n"
  var body = "cmake_minimum_required(VERSION 3.14)\nproject(ShebangsyCpp LANGUAGES CXX)\n" &
    "set(CMAKE_CXX_STANDARD 17)\nset(CMAKE_CXX_STANDARD_REQUIRED ON)\n"
  if fetchBlock.len > 0:
    body.add "include(FetchContent)\n"
    body.add fetchBlock
  body.add "add_executable(shebangsy_cpp_app src/main.cpp)\n"
  body.add linkBlock
  body


## Configures and builds the shared cpp workspace, linking the script as ``main.cpp``.
proc cppCompile*(scriptAbs, binaryPath: string): int =
  if not toolEnsureOnPath("cmake", "https://cmake.org/download/"):
    return 1

  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:cpp] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let body = stripShebangAndFrontmatterBody(raw)
  if body.strip.len == 0:
    stderr.writeLine "[shebangsy:cpp] empty script after shebang and frontmatter"
    return 1

  let dirs = frontmatterDirectivesFromSource(raw)
  let cmakeText = cppCMakeListsGenerate(dirs.requires)
  if cmakeText.len == 0:
    return 1

  let cacheRoot = cacheRootDirGet()
  let wsDir = cacheRoot / "cpp-workspace"
  let lockPath = cacheRoot / "cpp-workspace.lock"
  try:
    createDir(cacheRoot)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:cpp] could not create cache root: ", e.msg
    return 1

  let wsLockFd = cacheCompileLockAcquire(lockPath)
  try:
    try:
      createDir(wsDir / "src")
    except CatchableError as e:
      stderr.writeLine "[shebangsy:cpp] could not create workspace src: ", e.msg
      return 1
    try:
      writeFile(wsDir / "src" / "main.cpp", body)
      writeFile(wsDir / "CMakeLists.txt", cmakeText)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:cpp] cannot write workspace files: ", e.msg
      return 1

    let buildDir = wsDir / "build"
    let cmakeExe = findExe("cmake")
    if cmakeExe.len == 0:
      stderr.writeLine "[shebangsy:cpp] cmake not found on PATH"
      return 1
    var cmakeArgs = @["-S", wsDir, "-B", buildDir, "-DCMAKE_BUILD_TYPE=Release"]
    for f in dirs.flags:
      cmakeArgs.add f
    var code = processExitCodeWait(cmakeExe, cmakeArgs)
    if code != 0:
      return code
    code = processExitCodeWait(cmakeExe, @["--build", buildDir])
    if code != 0:
      return code

    let built = buildDir / "shebangsy_cpp_app"
    if not fileExists(built):
      stderr.writeLine "[shebangsy:cpp] expected build output not found: ", built
      return 1

    try:
      copyFile(built, binaryPath)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:cpp] copy to cache failed: ", e.msg
      return 1
    try:
      setFilePermissions(binaryPath, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
          fpOthersRead, fpOthersExec})
    except CatchableError:
      discard
  finally:
    cacheCompileLockRelease(wsLockFd)
  0


## Exec tuple for a cached C++ binary.
proc cppExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  (binaryPath, scriptArgs)


## Registers the cpp language runner.
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @[],
    compileProc: cppCompile,
    description: "Compile and run cpp scripts via CMake",
    execProc: cppExecTupleForBinary,
    key: "cpp",
  )
