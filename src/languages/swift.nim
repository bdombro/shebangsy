#[
languages/swift – compile Swift scripts via swiftc or a shared SwiftPM workspace

Goal: let shebangsy execute .swift scripts with optional SwiftPM package dependencies
  declared via #!requires:, and automatically handle the -parse-as-library flag for
  scripts that use @main.

Why: swiftc is fast for dependency-free scripts but cannot resolve packages; Swift
  Package Manager needs a full Package.swift and workspace. The same SwiftPM workspace
  is shared across all scripts (locked with flock) to amortise the resolution cost.
  @main requires -parse-as-library which beginners often forget, so it is injected
  automatically when detected in the source.

How:
  - No #!requires: → write ``sidecar.swift`` under ``cacheShadowDirFromBinary(binaryPath)``,
    then swiftc -O that file -o binaryPath (+ any auto flags); remove the sidecar after compile.
  - With #!requires: → shared SwiftPM workspace at ~/.cache/shebangsy/swift-workspace;
    swift package add-dependency + add-target-dependency for each new dep;
    swift build -c release; copy .build/release/sheb to binaryPath.
  - @main detection: scan source for @main not followed by an identifier char
    (excludes @mainActor); inject -parse-as-library (bare for swiftc,
    -Xswiftc wrapped for SwiftPM) unless already present in #!flags:.

```mermaid
flowchart TD
    A[script.swift] --> B[strip frontmatter → body]
    B --> C{detect @main → inject -parse-as-library?}
    C --> D{#!requires: present?}
    D -- no --> E[swiftc -O sidecar.swift]
    D -- yes --> F[shared SwiftPM workspace]
    F --> G[swift package add-dependency]
    G --> H[swift build -c release]
    E --> I[copy to binaryPath]
    H --> I
```
]#

import std/[options, os, strutils]
import ../languages_common

## Clears the global shebangsy cache (SwiftPM workspace lives under it).
proc swiftCacheClear(): int =
  cacheClear()


## True for ASCII letters, digits, and underscore (Swift identifier continuation after ``@main``).
proc swiftCharIsIdentTail(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}


## True when ``body`` has ``@main`` not followed by an identifier tail (excludes ``@mainActor``).
proc swiftSourceHasMainAttribute(body: string): bool =
  var i = 0
  while i < body.len:
    let p = body.find("@main", i)
    if p < 0:
      return false
    let after = p + "@main".len
    if after >= body.len:
      return true
    if swiftCharIsIdentTail(body[after]):
      i = p + 1
      continue
    return true


## True when ``flags`` already include ``-parse-as-library`` (alone or after ``-Xswiftc``).
proc swiftFlagsAlreadyHaveParseAsLibrary(flags: seq[string]): bool =
  var i = 0
  while i < flags.len:
    if flags[i] == "-parse-as-library":
      return true
    if flags[i] == "-Xswiftc" and i + 1 < flags.len and flags[i + 1] == "-parse-as-library":
      return true
    inc i
  false


## Adds ``-parse-as-library`` for ``swiftc``, or ``-Xswiftc`` + that flag for SwiftPM, when needed.
proc swiftFlagsWithAutoParseAsLibrary(body: string; flags: seq[string]; spm: bool): seq[string] =
  result = flags
  if not swiftSourceHasMainAttribute(body):
    return
  if swiftFlagsAlreadyHaveParseAsLibrary(result):
    return
  if spm:
    result.add "-Xswiftc"
    result.add "-parse-as-library"
  else:
    result.add "-parse-as-library"


type
  ## Resolved SwiftPM dependency tuple after parsing a ``#!requires:`` token.
  SwiftDepResolved* = object
    url*: string
    version*: string
    product*: string
    packageId*: string


const swiftKnownPackages: seq[(string, string, string, string)] = @[
  ("swift-argument-parser", "https://github.com/apple/swift-argument-parser.git",
      "ArgumentParser", "swift-argument-parser"),
  ("apple/swift-argument-parser", "https://github.com/apple/swift-argument-parser.git",
      "ArgumentParser", "swift-argument-parser"),
  ("mxcl/promisekit", "https://github.com/mxcl/PromiseKit", "PromiseKit", "PromiseKit"),
]

## Snippet inserted into shared ``Package.swift`` when no ``platforms:`` key exists.
const swiftWorkspacePlatformsLine = "\n    platforms: [.macOS(\"26.0\"), .iOS(\"26.0\"), " &
    ".watchOS(\"13.0\"), .tvOS(\"26.0\"), .visionOS(\"3.0\")],"


## Looks up a shorthand package key in ``swiftKnownPackages``.
proc swiftKnownLookup(keyLower: string): (bool, string, string, string) =
  for (k, url, prod, pid) in swiftKnownPackages:
    if k == keyLower:
      return (true, url, prod, pid)
  (false, "", "", "")


## Ensures GitHub dependency URLs end with ``.git`` when applicable.
proc swiftNormalizeDepUrl(url: string): string =
  result = url.strip
  if result.len == 0:
    return
  if (result.startsWith("https://github.com/") or result.startsWith("http://github.com/")) and
      not result.endsWith(".git"):
    result.add ".git"


## Last path segment of a git URL (repo name), stripping ``.git``.
proc swiftPackageIdFromUrl(url: string): string =
  var u = url.strip
  if u.endsWith(".git"):
    u = u[0 ..< ^4]
  let slash = u.rfind('/')
  if slash >= 0 and slash + 1 < u.len:
    result = u[slash + 1 .. ^1]
  else:
    result = u


## ``owner/repo`` lowercased from a GitHub URL, or empty when not GitHub-shaped.
proc swiftGithubOwnerRepoKey(url: string): string =
  var s = url.strip
  if s.endsWith(".git"):
    s = s[0 ..< ^4]
  const needle = "github.com/"
  let p = s.find(needle)
  if p < 0:
    return ""
  let rest = s[p + needle.len .. ^1].strip
  let slash = rest.find('/')
  if slash < 0 or slash + 1 >= rest.len:
    return ""
  let owner = rest[0 ..< slash]
  var tail = rest[slash + 1 .. ^1]
  let slash2 = tail.find('/')
  let repo =
    if slash2 < 0:
      tail
    else:
      tail[0 ..< slash2]
  return (owner & "/" & repo).toLowerAscii


## Parses one ``#!requires:`` token into ``SwiftDepResolved`` or ``none`` on error.
proc swiftResolveRequiresToken(spec: string): Option[SwiftDepResolved] =
  let s = spec.strip
  if s.len == 0:
    stderr.writeLine "[shebangsy:swift] empty #!requires: token"
    return none(SwiftDepResolved)
  let lastAt = s.rfind('@')
  if lastAt < 0:
    stderr.writeLine "[shebangsy:swift] #!requires: missing @version: ", spec
    return none(SwiftDepResolved)
  let left = s[0 ..< lastAt].strip
  var right = s[lastAt + 1 .. ^1].strip
  if left.len == 0 or right.len == 0:
    stderr.writeLine "[shebangsy:swift] invalid #!requires: token: ", spec
    return none(SwiftDepResolved)
  var ver = right
  var explicitProduct = ""
  let colon = right.find(':')
  if colon > 0 and colon < right.len - 1:
    ver = right[0 ..< colon].strip
    explicitProduct = right[colon + 1 .. ^1].strip
  if ver.len == 0:
    stderr.writeLine "[shebangsy:swift] empty version in #!requires: ", spec
    return none(SwiftDepResolved)

  var url = ""
  var product = explicitProduct
  var packageId = ""

  if left.startsWith("https://") or left.startsWith("http://"):
    url = swiftNormalizeDepUrl(left)
    packageId = swiftPackageIdFromUrl(url)
    if product.len == 0:
      let (found, mUrl, mProd, mPid) = swiftKnownLookup(swiftGithubOwnerRepoKey(url))
      if found:
        url = swiftNormalizeDepUrl(mUrl)
        product = mProd
        packageId = mPid
    if product.len == 0:
      stderr.writeLine "[shebangsy:swift] unknown dependency URL; append :Product: ", spec
      return none(SwiftDepResolved)
  elif '/' in left:
    let key = left.toLowerAscii
    let (found, mUrl, mProd, mPid) = swiftKnownLookup(key)
    if found:
      url = swiftNormalizeDepUrl(mUrl)
      if product.len == 0:
        product = mProd
      packageId = mPid
    else:
      url = swiftNormalizeDepUrl("https://github.com/" & left)
      packageId = swiftPackageIdFromUrl(url)
      if product.len == 0:
        stderr.writeLine "[shebangsy:swift] unknown package ", left,
            "; append :ProductName after the version or use a mapped shorthand"
        return none(SwiftDepResolved)
  else:
    let (found, mUrl, mProd, mPid) = swiftKnownLookup(left.toLowerAscii)
    if not found:
      stderr.writeLine "[shebangsy:swift] unknown package ", left,
          "; use owner/repo@version, a full URL, or a mapped name (see README)"
      return none(SwiftDepResolved)
    url = swiftNormalizeDepUrl(mUrl)
    if product.len == 0:
      product = mProd
    packageId = mPid

  some(SwiftDepResolved(url: url, version: ver, product: product, packageId: packageId))


## Inserts ``platforms:`` into ``Package.swift`` when missing (high OS floors for Swift 6 APIs).
proc swiftPackageEnsureLatestPlatforms(wsDir: string): int =
  let path = wsDir / "Package.swift"
  var content: string
  try:
    content = readFile(path)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:swift] cannot read Package.swift: ", e.msg
    return 1
  if content.contains("platforms:"):
    return 0
  const marker = "name: \"sheb\","
  let pos = content.find(marker)
  if pos < 0:
    stderr.writeLine "[shebangsy:swift] Package.swift missing expected " &
      "`name: \"sheb\",`; cannot add platforms"
    return 1
  let after = pos + marker.len
  content = content[0 ..< after] & swiftWorkspacePlatformsLine & content[after .. ^1]
  try:
    writeFile(path, content)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:swift] cannot write Package.swift: ", e.msg
    return 1
  0


## Updates shared SwiftPM workspace (manifest, sources, deps) and runs ``swift build``.
proc swiftCompileSpm(
    wsDir: string; body: string; deps: seq[SwiftDepResolved]; flags: seq[string]): int =
  let swiftExe = findExe("swift")
  if swiftExe.len == 0:
    stderr.writeLine "[shebangsy:swift] swift not found on PATH"
    return 1

  try:
    createDir(wsDir)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:swift] could not create workspace: ", wsDir, ": ", e.msg
    return 1

  if not fileExists(wsDir / "Package.swift"):
    var code = processExitCodeWait(swiftExe, [
        "package", "init", "--type", "executable", "--name", "sheb",
      ], wsDir)
    if code != 0:
      return code

  if swiftPackageEnsureLatestPlatforms(wsDir) != 0:
    return 1

  let shebSwift = wsDir / "Sources" / "sheb" / "sheb.swift"
  try:
    createDir(parentDir(shebSwift))
    writeFile(shebSwift, body)
  except CatchableError as e:
    stderr.writeLine "[shebangsy:swift] cannot write ", shebSwift, ": ", e.msg
    return 1

  for d in deps:
    var manifest = ""
    try:
      manifest = readFile(wsDir / "Package.swift")
    except CatchableError as e:
      stderr.writeLine "[shebangsy:swift] cannot read Package.swift: ", e.msg
      return 1
    if manifest.contains(d.url):
      continue
    var code = processExitCodeWait(swiftExe, [
        "package", "add-dependency", d.url, "--exact", d.version,
      ], wsDir)
    if code != 0:
      return code
    code = processExitCodeWait(swiftExe, [
        "package", "add-target-dependency", d.product, "sheb", "--package", d.packageId,
      ], wsDir)
    if code != 0:
      return code

  if not dirExists(wsDir / ".build"):
    stderr.writeLine "[shebangsy:swift] No SwiftPM build cache at ", wsDir, "/.build yet; ",
        "this compile will take longer than usual."

  var buildArgs = @["build", "-c", "release"]
  for f in flags:
    buildArgs.add f
  processExitCodeWait(swiftExe, buildArgs, wsDir)


## ``swiftc`` for scripts without deps; locked SwiftPM build for ``#!requires:`` scripts.
proc swiftCompile*(scriptAbs, binaryPath: string): int =
  let raw =
    try:
      readFile(scriptAbs)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:swift] cannot read script: ", scriptAbs, ": ", e.msg
      return 1

  let body = stripShebangAndFrontmatterBody(raw)
  if body.strip.len == 0:
    stderr.writeLine "[shebangsy:swift] empty script after shebang and frontmatter"
    return 1

  let dirs = frontmatterDirectivesFromSource(raw)
  let flags = swiftFlagsWithAutoParseAsLibrary(body, dirs.flags, spm = dirs.requires.len > 0)

  if dirs.requires.len == 0:
    if not toolEnsureOnPath("swiftc", "https://www.swift.org/install/"):
      return 1
    let shadow = cacheShadowDirFromBinary(binaryPath)
    try:
      createDir(shadow)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:swift] could not create shadow dir: ", shadow, ": ", e.msg
      return 1
    let sidecar = shadow / "sidecar.swift"
    try:
      writeFile(sidecar, body)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:swift] cannot write sidecar: ", e.msg
      return 1
    let swiftcExe = findExe("swiftc")
    if swiftcExe.len == 0:
      stderr.writeLine "[shebangsy:swift] swiftc not found on PATH"
      return 1
    var swiftcArgs = @["-O", sidecar, "-o", binaryPath]
    for f in flags:
      swiftcArgs.add f
    let code = processExitCodeWait(swiftcExe, swiftcArgs, "")
    try:
      removeFile(sidecar)
    except CatchableError:
      discard
    if code != 0:
      return code
  else:
    if not toolEnsureOnPath("swift", "https://www.swift.org/install/"):
      return 1

    var deps: seq[SwiftDepResolved] = @[]
    for spec in dirs.requires:
      let r = swiftResolveRequiresToken(spec)
      if r.isNone:
        return 1
      deps.add r.get

    let cacheRoot = cacheRootDirGet()
    let wsDir = cacheRoot / "swift-workspace"
    let lockPath = cacheRoot / "swift-workspace.lock"
    try:
      createDir(cacheRoot)
    except CatchableError as e:
      stderr.writeLine "[shebangsy:swift] could not create cache root: ", e.msg
      return 1

    let wsLockFd = cacheCompileLockAcquire(lockPath)
    try:
      let code = swiftCompileSpm(wsDir, body, deps, flags)
      if code != 0:
        return code

      let built = wsDir / ".build" / "release" / "sheb"
      if not fileExists(built):
        stderr.writeLine "[shebangsy:swift] expected build output not found: ", built
        return 1

      try:
        copyFile(built, binaryPath)
      except CatchableError as e:
        stderr.writeLine "[shebangsy:swift] copy to cache failed: ", e.msg
        return 1
      try:
        setFilePermissions(binaryPath, {
            fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
            fpOthersExec,
          })
      except CatchableError:
        discard
    finally:
      cacheCompileLockRelease(wsLockFd)
  0


## Exec tuple for a cached Swift binary.
proc swiftExecTupleForBinary*(binaryPath: string; scriptArgs: seq[string]): ExecTuple =
  (binaryPath, scriptArgs)


## Registers the Swift runner (swiftc / SwiftPM; auto ``-parse-as-library`` when ``@main``).
proc createRunner*(): LanguageRunner =
  LanguageRunner(
    aliases: @[],
    clearProc: swiftCacheClear,
    compileProc: swiftCompile,
    description:
      "Swift scripts: swiftc or SwiftPM; adds -parse-as-library when source has @main",
    execProc: swiftExecTupleForBinary,
    key: "swift",
  )
