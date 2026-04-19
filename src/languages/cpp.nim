#[
languages/cpp – compile C++ scripts via CMake with FetchContent, vcpkg, or Conan

Goal: let shebangsy execute single-file .cpp scripts with ``#!requires:`` lines that pull
  dependencies from GitHub (CMake FetchContent), vcpkg manifest mode, or Conan.

Why: C++ has no single package manager; CMake is the common denominator. Per-cache-key
  shadow directories isolate dependency graphs so scripts do not clobber each other.

How:
  1. Parse ``#!requires:`` tokens into ``CppDepSpec`` (``github:``, ``vcpkg:``, ``conan:``).
  2. Reject bare names (e.g. ``cli11@1``) with a migration hint.
  3. Emit ``CMakeLists.txt`` (+ ``vcpkg.json`` / ``conanfile.txt`` when needed) under
     ``cacheShadowDirFromBinary(binaryPath)``.
  4. Optionally bootstrap vcpkg under ``~/.cache/shebangsy/vcpkg``.
  5. Run ``conan install`` before CMake when Conan specs are present.
  6. ``cmake -S/-B`` with the right toolchain, ``cmake --build``, copy binary to cache path.
  A per-binary flock prevents concurrent compiles for the same artifact.

```mermaid
flowchart TD
    A[script.cpp] --> B[cppDepSpecsFromRequires]
    B --> C[cppCMakeListsGenerate]
    C --> D[shadow dir + files]
    D --> E[flock]
    E --> F[conan install if needed]
    F --> G[cmake configure]
    G --> H[cmake build]
    H --> I[copy binary]
```
]#

import std/[os, strutils]
import ../languages_common

type
  CppDepKind = enum
    cdGithub
    cdVcpkg
    cdConan

  CppDepSpec = object
    kind: CppDepKind
    githubRepo: string
    githubTag: string
    githubCmakeTarget: string
    vcpkgName: string
    vcpkgVer: string
    vcpkgCmakeTarget: string
    conanRequire: string
    conanCmakeTarget: string


## True when ``s`` was parsed successfully (used after ``cppDepSpecParse``).
proc cppDepSpecValid(s: CppDepSpec): bool =
  case s.kind
  of cdGithub:
    s.githubRepo.len > 0 and s.githubTag.len > 0
  of cdVcpkg:
    s.vcpkgName.len > 0 and s.vcpkgVer.len > 0
  of cdConan:
    s.conanRequire.len > 0


## Turns ``owner/repo`` into a CMake-safe FetchContent identifier (letters, digits, underscore).
proc cppGithubFetchId(repo: string): string =
  for c in repo:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9':
      result.add c
    else:
      result.add '_'


## Parses ``github:owner/repo@tag`` with optional ``:CMakeTarget`` (may contain ``::``).
proc cppGithubSpecParse(rest: string): CppDepSpec =
  let at = rest.find('@')
  if at < 1 or at >= rest.len - 1:
    stderr.writeLine "[shebangsy:cpp] invalid github: spec (need owner/repo@tag): ", rest
    return
  let repo = rest[0 ..< at].strip
  if '/' notin repo:
    stderr.writeLine "[shebangsy:cpp] invalid github: spec (owner/repo): ", rest
    return
  let tail = rest[at + 1 .. ^1].strip
  var gitTag = tail
  var cmakeT = ""
  let colon = tail.find(':')
  if colon >= 0:
    gitTag = tail[0 ..< colon].strip
    cmakeT = tail[colon + 1 .. ^1].strip
  if gitTag.len == 0:
    stderr.writeLine "[shebangsy:cpp] invalid github: spec (empty tag): ", rest
    return
  result = CppDepSpec(kind: cdGithub, githubRepo: repo, githubTag: gitTag,
      githubCmakeTarget: cmakeT)


## Parses ``vcpkg:name@ver`` with optional ``:CMakeTarget`` suffix.
proc cppVcpkgSpecParse(rest: string): CppDepSpec =
  let at = rest.find('@')
  if at < 1 or at >= rest.len - 1:
    stderr.writeLine "[shebangsy:cpp] invalid vcpkg: spec (need name@version): ", rest
    return
  let name = rest[0 ..< at].strip
  let tail = rest[at + 1 .. ^1].strip
  var ver = tail
  var cmakeT = ""
  let colon = tail.find(':')
  if colon >= 0:
    ver = tail[0 ..< colon].strip
    cmakeT = tail[colon + 1 .. ^1].strip
  if name.len == 0 or ver.len == 0:
    stderr.writeLine "[shebangsy:cpp] invalid vcpkg: spec: ", rest
    return
  result = CppDepSpec(kind: cdVcpkg, vcpkgName: name, vcpkgVer: ver, vcpkgCmakeTarget: cmakeT)


## Parses ``conan:name/version`` with optional ``:CMakeTarget`` suffix (first ``:`` after ref).
proc cppConanSpecParse(rest: string): CppDepSpec =
  let colon = rest.find(':')
  if colon < 0:
    if rest.strip.len == 0:
      stderr.writeLine "[shebangsy:cpp] invalid conan: spec (empty)"
      return
    return CppDepSpec(kind: cdConan, conanRequire: rest.strip)
  let req = rest[0 ..< colon].strip
  let cmakeT = rest[colon + 1 .. ^1].strip
  if req.len == 0:
    stderr.writeLine "[shebangsy:cpp] invalid conan: spec: ", rest
    return
  result = CppDepSpec(kind: cdConan, conanRequire: req, conanCmakeTarget: cmakeT)


## Parses one ``#!requires:`` token; prints an error and returns invalid spec on failure.
proc cppDepSpecParse(spec: string): CppDepSpec =
  let s = spec.strip
  const pGh = "github:"
  const pVp = "vcpkg:"
  const pCn = "conan:"
  if s.startsWith(pGh):
    return cppGithubSpecParse(s[pGh.len .. ^1])
  if s.startsWith(pVp):
    return cppVcpkgSpecParse(s[pVp.len .. ^1])
  if s.startsWith(pCn):
    return cppConanSpecParse(s[pCn.len .. ^1])
  stderr.writeLine "[shebangsy:cpp] bare #!requires: not supported; use github:, vcpkg:, or conan: — got: ",
      spec
  stderr.writeLine "[shebangsy:cpp] example: github:CLIUtils/CLI11@v2.4.1:CLI11::CLI11"
  result = CppDepSpec(kind: cdGithub)


## Parses every requires token; returns empty seq on first error.
proc cppDepSpecsFromRequires(requires: seq[string]): seq[CppDepSpec] =
  for spec in requires:
    let p = cppDepSpecParse(spec)
    if not cppDepSpecValid(p):
      return @[]
    result.add p


## Whether ``specs`` include any vcpkg or conan entries (single pass).
proc cppDepKindsPresent(specs: seq[CppDepSpec]): tuple[hasVcpkg: bool, hasConan: bool] =
  for s in specs:
    case s.kind
    of cdVcpkg:
      result.hasVcpkg = true
    of cdConan:
      result.hasConan = true
    of cdGithub:
      discard


## Default ``Pkg::pkg``-style link target for a vcpkg port name (override with ``:CMakeTarget``).
proc cppVcpkgLinkTargetDefault(port: string): string =
  let n = port.strip
  if n.len == 0:
    return ""
  n & "::" & n


## Default link target from a Conan ref ``name/version`` (override with ``:CMakeTarget``).
proc cppConanLinkTargetDefault(conanRef: string): string =
  let slash = conanRef.find('/')
  if slash < 1:
    return ""
  let name = conanRef[0 ..< slash].strip
  if name.len == 0:
    return ""
  name & "::" & name


## Emits FetchContent CMake for all GitHub deps; separate link lines when ``githubCmakeTarget`` set.
proc cppFetchContentBlockEmit(deps: seq[CppDepSpec]): tuple[fetch: string, linkLines: seq[string]] =
  for d in deps:
    if d.kind != cdGithub:
      continue
    let id = cppGithubFetchId(d.githubRepo)
    let url = "https://github.com/" & d.githubRepo & ".git"
    result.fetch.add "FetchContent_Declare(\n  " & id & "\n  GIT_REPOSITORY " & url & "\n  GIT_TAG " &
        d.githubTag & "\n)\nFetchContent_MakeAvailable(" & id & ")\n"
    if d.githubCmakeTarget.len > 0:
      result.linkLines.add d.githubCmakeTarget


## Emits ``vcpkg.json`` body for vcpkg-kind deps, or empty string if none.
proc vcpkgJsonGenerate(deps: seq[CppDepSpec]): string =
  var lines: seq[string] = @[]
  for d in deps:
    if d.kind != cdVcpkg:
      continue
    let name = d.vcpkgName
    let ver = d.vcpkgVer
    lines.add "    { \"name\": \"" & name & "\", \"version>=\": \"" & ver & "\" }"
  if lines.len == 0:
    return ""
  let depsBlock = lines.join(",\n")
  result = "{\n  \"$schema\": \"https://raw.githubusercontent.com/microsoft/vcpkg-tool/main/docs/vcpkg.schema.json\",\n  \"dependencies\": [\n" &
    depsBlock & "\n  ]\n}\n"


## Emits ``conanfile.txt`` for Conan-kind deps, or empty string if none.
proc conanfileTxtGenerate(deps: seq[CppDepSpec]): string =
  var reqs: seq[string] = @[]
  for d in deps:
    if d.kind != cdConan:
      continue
    reqs.add d.conanRequire
  if reqs.len == 0:
    return ""
  result = "[requires]\n" & reqs.join("\n") & "\n\n[generators]\nCMakeDeps\nCMakeToolchain\n"


## Runs ``conan install`` into ``buildDir`` from ``shadowDir`` (contains ``conanfile.txt``).
proc conanInstall(conanExe, shadowDir, buildDir: string): int =
  processExitCodeWait(conanExe,
      @["install", ".", "--output-folder=" & buildDir, "--build=missing"], shadowDir)


## Resolves vcpkg root: ``PATH``, else clones and bootstraps under ``~/.cache/shebangsy/vcpkg``.
proc vcpkgRootGet(): string =
  let onPath = findExe("vcpkg")
  if onPath.len > 0:
    return parentDir(expandFilename(onPath))
  if not toolEnsureOnPath("git", "https://git-scm.com/downloads"):
    return ""
  let cacheRoot = cacheRootDirGet()
  let root = cacheRoot / "vcpkg"
  if fileExists(root / "vcpkg"):
    return root
  try:
    createDir(cacheRoot)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:cpp] could not create cache root: ", e.msg
    return ""
  var code = processExitCodeWait("git", @["clone", "--depth", "1",
      "https://github.com/microsoft/vcpkg.git", root])
  if code != 0:
    stderr.writeLine "[shebangsy:cpp] git clone vcpkg failed"
    return ""
  when defined(windows):
    code = processExitCodeWait("cmd.exe", @["/c", "bootstrap-vcpkg.bat"], root)
  else:
    code = processExitCodeWait("/bin/sh", @["./bootstrap-vcpkg.sh"], root)
  if code != 0:
    stderr.writeLine "[shebangsy:cpp] vcpkg bootstrap failed"
    return ""
  if not fileExists(root / "vcpkg"):
    stderr.writeLine "[shebangsy:cpp] vcpkg bootstrap did not produce vcpkg executable"
    return ""
  root


## ``find_package`` + link names for vcpkg deps (port name used for CONFIG mode).
proc cppVcpkgFindPackageLines(deps: seq[CppDepSpec]): tuple[findLines: seq[string], linkNames: seq[string]] =
  for d in deps:
    if d.kind != cdVcpkg:
      continue
    let pkg = d.vcpkgName
    result.findLines.add "find_package(" & pkg & " CONFIG REQUIRED)"
    var tgt = d.vcpkgCmakeTarget.strip
    if tgt.len == 0:
      tgt = cppVcpkgLinkTargetDefault(pkg)
    if tgt.len > 0:
      result.linkNames.add tgt


## ``find_package`` + link names for Conan deps.
proc cppConanFindPackageLines(deps: seq[CppDepSpec]): tuple[findLines: seq[string], linkNames: seq[string]] =
  for d in deps:
    if d.kind != cdConan:
      continue
    let slash = d.conanRequire.find('/')
    if slash < 1:
      continue
    let pkg = d.conanRequire[0 ..< slash].strip
    result.findLines.add "find_package(" & pkg & " CONFIG REQUIRED)"
    var tgt = d.conanCmakeTarget.strip
    if tgt.len == 0:
      tgt = cppConanLinkTargetDefault(d.conanRequire)
    if tgt.len > 0:
      result.linkNames.add tgt


## Builds ``CMakeLists.txt`` for the shadow project, or ``""`` on validation error.
proc cppCMakeListsGenerate(deps: seq[CppDepSpec]): string =
  var nV = 0
  var nC = 0
  for d in deps:
    case d.kind
    of cdVcpkg:
      inc nV
    of cdConan:
      inc nC
    of cdGithub:
      discard
  if nV > 0 and nC > 0:
    stderr.writeLine "[shebangsy:cpp] vcpkg: and conan: cannot be mixed in one script"
    return ""

  let (fetchBlock, ghLinks) = cppFetchContentBlockEmit(deps)
  let (vpFind, vpLinks) = cppVcpkgFindPackageLines(deps)
  let (cnFind, cnLinks) = cppConanFindPackageLines(deps)

  var body = "cmake_minimum_required(VERSION 3.15)\nproject(ShebangsyCpp LANGUAGES CXX)\n" &
    "set(CMAKE_CXX_STANDARD 17)\nset(CMAKE_CXX_STANDARD_REQUIRED ON)\n"
  if fetchBlock.len > 0:
    body.add "include(FetchContent)\n"
    body.add fetchBlock
  for ln in vpFind:
    body.add ln & "\n"
  for ln in cnFind:
    body.add ln & "\n"
  body.add "add_executable(shebangsy_cpp_app src/main.cpp)\n"
  var allLinks: seq[string] = @[]
  for x in ghLinks:
    allLinks.add x
  for x in vpLinks:
    allLinks.add x
  for x in cnLinks:
    allLinks.add x
  if allLinks.len > 0:
    body.add "target_link_libraries(shebangsy_cpp_app PRIVATE " & allLinks.join(" ") & ")\n"
  body


## Configures and builds a per-binary CMake tree, linking the script as ``src/main.cpp``.
proc cppCompile*(scriptAbs, binaryPath: string): int =
  if not toolEnsureOnPath("cmake", "https://cmake.org/download/"):
    return 1
  let cmakeExe = findExe("cmake")
  if cmakeExe.len == 0:
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
  let specs = cppDepSpecsFromRequires(dirs.requires)
  if dirs.requires.len > 0 and specs.len == 0:
    return 1

  let (hasVcpkg, hasConan) = cppDepKindsPresent(specs)
  var vcpkgToolchain = ""
  if hasVcpkg:
    let root = vcpkgRootGet()
    if root.len == 0:
      return 1
    vcpkgToolchain = root / "scripts" / "buildsystems" / "vcpkg.cmake"

  let cmakeText = cppCMakeListsGenerate(specs)
  if cmakeText.len == 0 and specs.len > 0:
    return 1

  let wsDir = cacheShadowDirFromBinary(binaryPath)
  let buildDir = wsDir / "build"

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

  if hasConan:
    let cf = conanfileTxtGenerate(specs)
    if cf.len == 0:
      stderr.writeLine "[shebangsy:cpp] internal: conan specs but empty conanfile"
      return 1
    try:
      writeFile(wsDir / "conanfile.txt", cf)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:cpp] cannot write conanfile.txt: ", e.msg
      return 1
    if not toolEnsureOnPath("conan", "https://docs.conan.io/"):
      return 1
    let conanExe = findExe("conan")
    if conanExe.len == 0:
      return 1
    let ccode = conanInstall(conanExe, wsDir, buildDir)
    if ccode != 0:
      return ccode

  if hasVcpkg:
    let j = vcpkgJsonGenerate(specs)
    if j.len == 0:
      stderr.writeLine "[shebangsy:cpp] internal: vcpkg specs but empty vcpkg.json"
      return 1
    try:
      writeFile(wsDir / "vcpkg.json", j)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:cpp] cannot write vcpkg.json: ", e.msg
      return 1

  var cmakeArgs = @["-S", wsDir, "-B", buildDir, "-DCMAKE_BUILD_TYPE=Release"]
  if hasConan:
    cmakeArgs.add "-DCMAKE_TOOLCHAIN_FILE=" & (buildDir / "conan_toolchain.cmake")
  elif vcpkgToolchain.len > 0:
    cmakeArgs.add "-DCMAKE_TOOLCHAIN_FILE=" & vcpkgToolchain
  for f in dirs.flags:
    cmakeArgs.add f
  var code = processExitCodeWait(cmakeExe, cmakeArgs)
  if code != 0:
    return code
  code = processExitCodeWait(cmakeExe, @["--build", buildDir, "--config", "Release"])
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
  0


## Exec tuple for a cached C++ binary.
proc cppExecTupleForBinary(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
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
