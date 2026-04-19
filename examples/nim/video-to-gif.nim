#!/usr/bin/env -S shebangsy nim
#!requires: argsbarg

#[
  Video To GIF

  CLI tool for converting video files to palette-optimized GIFs with ffmpeg, optional
  shrink-only width and frame-rate limits, timestamp preservation, batch operation, and safe
  interrupt handling.

  Writes ``stem.gif`` next to each source. With ``--replace``, the original video is removed after
  a successful conversion (Trash by default; ``--skipTrash`` for permanent delete).

  Usage:
    video-to-gif -h
    video-to-gif clip.mov
    video-to-gif convert clip.mov
    video-to-gif compress clip.mov
    video-to-gif --maxWidth=1280 --fps=6 clip.mov
    video-to-gif completions-zsh

  With no arguments the program prints overview help; paths and flags may omit ``convert`` (or
  ``compress`` as an alias).

  Code Standards:
    - Non-bundled dependencies must be checked for, print install help if missing, and exit non-zero.
    - Multi-word identifiers:
      - order from general → specific (head-first: main concept, then qualifier)
      - typically topic → optional subtype/format → measured attribute → limit/qualifier
      - e.g. gifFilterGraphFfmpeg, not ffmpegGraphFilterGif
    - Field names:
      - minimal tokens within the owning type
      - no repeated type/module/domain prefixes unless required for disambiguation
    - module-scope (aka top-level, not-nested) declarations (except imports) must be
      - documented with a doc comment above the declaration
      - sorted alphabetically by identifier
      - prefixed with "gif" if part of this tool's domain; else "core"
      - procs: callee before caller when required by the compiler; otherwise alphabetical
    - functions must have a human-readable doc comment, and a blank empty line after the function
    - Function shape:
      - entry-point and orchestration procs read top-down as a short sequence of named steps
      - keep the happy path obvious; move mechanics into helpers with intent-revealing names
    - Helper placement:
      - prefer nested helpers only for tiny logic tightly coupled to one block
      - promote helpers to module scope when nesting makes the caller hard to scan, even if the
        helper currently has one call site
      - shared by ≥2 call sites → smallest common ancestor (often a private proc at module scope)
      - must be visible to tests, callbacks, or exports → keep at the level visibility requires
      - recursion between helpers → shared scope as the language requires
    - Parameter shape:
      - if a proc takes more than four primitive or config parameters, prefer an options object
      - if the same cluster of values passes through multiple layers, define a named type for it
    - Branching:
      - materially different pipelines → separate helpers, not interleaved
      - repeated status literals and sentinels → centralized constants (or enums when suitable)
    - Assume unix arch and POSIX features are available
    - Use argsbarg for CLI features
      - default to no shortened flags for newly added options
    - Use line max-width of 100 characters, unless the line is a code block or a URL
    - ``CliCommand.handler`` must be a named proc, not an inline proc literal, and must implement
      the command directly rather than just forwarding to another proc
    - ``cliRun`` entrypoint: first argument must be an inline ``CliSchema(...)`` literal; second
      must be an inline argv expression (e.g. ``commandLineParams()``). Do not use a ``let`` bound
      only to pass schema or argv into ``cliRun`` alone (tests may use variables).

]#


import std/[options, os, osproc, posix, strformat, strutils, terminal, times]
import argsbarg

type
  ## Zsh completion behavior after a top-level subcommand word (word 2).
  CoreCliSurfaceZshTail = enum
    coreCliSurfaceZshTailNone
    coreCliSurfaceZshTailFiles
    coreCliSurfaceZshTailNestedWords

type
  ## One flag or option for zsh ``_arguments`` generation.
  CoreCliSurfaceOptionSpec = object
    ## Short help shown in zsh completion (sanitized for ``_arguments``).
    help: string
    ## Option spellings (e.g. ``-q`` and ``--quality``); combined into one zsh spec when grouped.
    names: seq[string]
    ## When true, expect ``:placeholder:`` value completion after the flag.
    takesValue: bool
    ## Placeholder label after the colon (e.g. ``pixels``, ``preset``).
    valuePlaceholder: string
    ## When non-empty, zsh offers these literals as the flag value.
    valueWords: seq[string]

type
  ## One top-level subcommand plus zsh tail behavior and an optional usage line suffix.
  CoreCliSurfaceTopCmd = object
    ## Subcommand name offered at ``CURRENT == 2``.
    name: string
    ## Words offered at ``CURRENT == 3`` when ``zshTail`` is ``coreCliSurfaceZshTailNestedWords``.
    nestedWords: seq[string]
    ## Flags and options valid after this subcommand (or for ``defaultSubcommand`` before it is spelled).
    options: seq[CoreCliSurfaceOptionSpec]
    ## Text after ``prog & " "`` for one usage line; empty to omit from usage output.
    usageLine: string
    ## How zsh completes further tokens under this subcommand.
    zshTail: CoreCliSurfaceZshTail

type
  ## Declarative CLI surface for zsh completion text and indented usage lines.
  CoreCliSurfaceSpec = object
    ## When set, ``options`` on that subcommand may appear before its word (implicit subcommand).
    defaultSubcommand: string
    ## Program name for ``#compdef`` and usage lines.
    prog: string
    ## Top-level subcommands (TAB at word 2).
    topCommands: seq[CoreCliSurfaceTopCmd]
    ## Options valid before a subcommand word (e.g. global ``-h`` / ``--help``).
    topOptions: seq[CoreCliSurfaceOptionSpec]
    ## Usage line suffixes (after ``prog & " "``) printed before per-command lines.
    usagePreamble: seq[string]
    ## Zsh completion function name including leading underscore.
    zshFunc: string

type
  ## Flags and limits passed through the GIF conversion pipeline.
  GifConvertOptions = object
    ## CI mode: when true, never prompt for file paths if argv lists none (non-interactive).
    ci: bool
    ## Upper bound on palette colors for ``palettegen`` (2–256).
    colors: int
    ## Target frames per second after the ``fps`` filter.
    fps: int
    ## When true, remove the source video after a successful ``stem.gif`` write (see ``skipTrash``).
    replace: bool
    ## When true with ``replace``, remove the original with ``removeFile`` instead of ``trash``.
    skipTrash: bool
    ## Upper bound on width in pixels; ffmpeg shrinks only, never enlarges.
    widthMax: int
  ## One row in the batch report: paths, status, sizes, and optional note.
  GifResult* = object
    bytesAfter*: int64 ## Output file size in bytes after conversion.
    bytesBefore*: int64 ## Source file size in bytes before conversion.
    destination*: string ## Output ``stem.gif`` path (unchanged after ``--replace``).
    message*: string ## Detail or empty.
    secondsElapsed*: float ## Wall time spent on this file.
    source*: string ## Input path for this row.
    status*: string ## ``gifStatusProcessed``, ``gifStatusSkipped``, or ``gifStatusFailed``.


## Global flag set from the SIGINT handler (async-signal-safe).
var coreInterruptRequested {.global.}: Sig_atomic


const
  ## Sentinel returned by ``coreCommandRunExternal`` when the user requests cancel (Ctrl+C /
  ## SIGINT).
  coreCommandRunInterrupted = "\xffINTERRUPTED"
  ## Default palette size for ``palettegen`` (2–256; smaller often yields smaller files).
  gifColorsDefault = 64
  ## Default output frames per second after ``fps`` filter.
  gifFpsDefault = 4
  ## Message when processing stopped due to SIGINT (paired with ``gifStatusSkipped``).
  gifMessageInterrupted = "interrupted"
  ## Stored in ``GifResult.status`` for failures.
  gifStatusFailed = "failed"
  ## Stored in ``GifResult.status`` for successful rows.
  gifStatusProcessed = "processed"
  ## Stored in ``GifResult.status`` for skipped or interrupted rows.
  gifStatusSkipped = "skipped"
  ## Default maximum width in pixels; ffmpeg shrinks only, never enlarges.
  gifWidthDefault = 800


## Indented usage lines from ``spec.usagePreamble`` and non-empty ``usageLine`` fields.
proc coreCliSurfaceUsageIndented(spec: CoreCliSurfaceSpec): string =
  var lines: seq[string]
  for p in spec.usagePreamble:
    lines.add("  " & spec.prog & " " & p)
  for c in spec.topCommands:
    if c.usageLine.len > 0:
      lines.add("  " & spec.prog & " " & c.usageLine)
  lines.join("\n")


## Sanitizes help text for zsh ``_arguments`` bracket descriptions.
proc coreCliSurfaceZshBracketDesc(help: string): string =
  const maxLen = 72
  var n = 0
  for c in help:
    if n >= maxLen:
      break
    case c
    of '[', ']', ':', ';', '\'', '"', '\\', '\n', '\r':
      result.add(' ')
    else:
      result.add(c)
    inc n
  result = result.strip()
  if result.len == 0:
    result = "option"


## Comma-separated brace group for zsh (``{-h,--help}``).
proc coreCliSurfaceZshOptBraceNames(names: seq[string]): string =
  result = "{"
  for i, n in names:
    if i > 0:
      result.add(',')
    result.add(n)
  result.add('}')


## One ``_arguments`` spec line for a flag or value-taking option.
proc coreCliSurfaceZshOptionArgumentLine(o: CoreCliSurfaceOptionSpec): string =
  if o.names.len == 0:
    return ""
  let desc = coreCliSurfaceZshBracketDesc(o.help)
  let excl = "(" & o.names.join(" ") & ")"
  let brace = coreCliSurfaceZshOptBraceNames(o.names)
  if not o.takesValue:
    return "'" & excl & "'" & brace & "'[" & desc & "]'"
  let phRaw = o.valuePlaceholder.strip()
  let ph = if phRaw.len > 0: phRaw else: "value"
  if o.valueWords.len > 0:
    var inner = "(("
    for i, w in o.valueWords:
      if i > 0:
        inner.add(' ')
      inner.add(w)
    inner.add("))")
    return "'" & excl & "'" & brace & "'[" & desc & "]:" & ph & ":" & inner & "'"
  "'" & excl & "'" & brace & "'[" & desc & "]:" & ph & ":'"


## ``_arguments`` block for file-taking subcommands (flags then files).
proc coreCliSurfaceZshCompressArgumentsWithIndent(opts: seq[CoreCliSurfaceOptionSpec]; sp: string): string =
  if opts.len == 0:
    return sp & "_files && return 0\n"
  result = sp & "_arguments -s -S \\\n"
  for o in opts:
    let line = coreCliSurfaceZshOptionArgumentLine(o)
    if line.len > 0:
      result.add(sp & "  ")
      result.add(line)
      result.add(" \\\n")
  result.add(sp & "  '*:file:_files' && return 0\n")


## Dedupes strings while preserving first-seen order.
proc coreCliSurfaceSeqDedupePreserve(xs: seq[string]): seq[string] =
  for x in xs:
    var seen = false
    for y in result:
      if y == x:
        seen = true
        break
    if not seen:
      result.add(x)


## Words offered at ``CURRENT == 2`` (subcommands plus global and implicit-subcommand flags).
proc coreCliSurfaceZshWordTwoCompaddWords(spec: CoreCliSurfaceSpec): seq[string] =
  for o in spec.topOptions:
    for n in o.names:
      result.add(n)
  if spec.defaultSubcommand.len > 0:
    for c in spec.topCommands:
      if c.name == spec.defaultSubcommand:
        for o in c.options:
          for n in o.names:
            result.add(n)
        break
  for c in spec.topCommands:
    result.add(c.name)


## Options for the implicit default subcommand, or empty.
proc coreCliSurfaceOptionsForDefault(spec: CoreCliSurfaceSpec): seq[CoreCliSurfaceOptionSpec] =
  if spec.defaultSubcommand.len == 0:
    return @[]
  for c in spec.topCommands:
    if c.name == spec.defaultSubcommand:
      return c.options
  @[]


## Builds the zsh completion script body (``#compdef``, ``_arguments``, ``case`` arms, ``_files``).
proc coreCliSurfaceZshScript(spec: CoreCliSurfaceSpec): string =
  let w2 = coreCliSurfaceSeqDedupePreserve(coreCliSurfaceZshWordTwoCompaddWords(spec))
  let w2line = w2.join(" ")
  let dopts = coreCliSurfaceOptionsForDefault(spec)
  var arms = ""
  for c in spec.topCommands:
    arms.add("    ")
    arms.add(c.name)
    arms.add(")\n")
    case c.zshTail
    of coreCliSurfaceZshTailNone:
      arms.add("      return 0\n      ;;\n")
    of coreCliSurfaceZshTailFiles:
      arms.add("      compset -n 2\n")
      arms.add(coreCliSurfaceZshCompressArgumentsWithIndent(c.options, "      "))
      arms.add("      ;;\n")
    of coreCliSurfaceZshTailNestedWords:
      arms.add("      if (( CURRENT == 3 )); then\n")
      arms.add("        compadd ")
      arms.add(c.nestedWords.join(" "))
      arms.add(" && return 0\n      fi\n      return 0\n      ;;\n")
  var tail = "    esac\n"
  if spec.defaultSubcommand.len > 0:
    tail = "    *)\n"
    tail.add("      compset -n 1\n")
    tail.add(coreCliSurfaceZshCompressArgumentsWithIndent(dopts, "      "))
    tail.add("      ;;\n    esac\n")
  result = "#compdef " & spec.prog & "\n\n" & spec.zshFunc & "() {\n"
  result.add("  if (( CURRENT == 2 )); then\n")
  result.add("    compadd -- ")
  result.add(w2line)
  result.add("\n    return\n  fi\n")
  result.add("  if (( CURRENT > 2 )); then\n")
  result.add("    case ${words[2]} in\n")
  result.add(arms)
  result.add(tail)
  result.add("  fi\n  _files\n}\n\n")
  result.add(spec.zshFunc)
  result.add(" \"$@\"\n")


const
  gifConvertTopHelpOpts = @[
    CoreCliSurfaceOptionSpec(
      help: "Show help",
      names: @["-h", "--help"],
      takesValue: false,
      valuePlaceholder: "",
      valueWords: @[]),
  ]
  gifConvertCmdOpts = @[
    CoreCliSurfaceOptionSpec(
      help: "CI mode: if argv has no paths, exit instead of prompting on a TTY",
      names: @["--ci"],
      takesValue: false,
      valuePlaceholder: "",
      valueWords: @[]),
    CoreCliSurfaceOptionSpec(
      help: "After a successful GIF: remove the original video (Trash unless --skipTrash)",
      names: @["--replace"],
      takesValue: false,
      valuePlaceholder: "",
      valueWords: @[]),
    CoreCliSurfaceOptionSpec(
      help: "With replace: delete the original with removeFile instead of trash(1)",
      names: @["--skipTrash"],
      takesValue: false,
      valuePlaceholder: "",
      valueWords: @[]),
    CoreCliSurfaceOptionSpec(
      help: "Max width in pixels (ffmpeg shrink-only)",
      names: @["--maxWidth"],
      takesValue: true,
      valuePlaceholder: "pixels",
      valueWords: @[]),
    CoreCliSurfaceOptionSpec(
      help: "Output frames per second after fps filter",
      names: @["--fps"],
      takesValue: true,
      valuePlaceholder: "n",
      valueWords: @[]),
    CoreCliSurfaceOptionSpec(
      help: "Palette size for GIF (2-256)",
      names: @["--colors"],
      takesValue: true,
      valuePlaceholder: "n",
      valueWords: @[]),
  ]
  ## Declarative CLI surface for zsh completion and usage lines.
  gifConvertCoreCliSurface = CoreCliSurfaceSpec(
    defaultSubcommand: "convert",
    prog: "video-to-gif",
    topCommands: @[
      CoreCliSurfaceTopCmd(
        name: "convert",
        nestedWords: @[],
        options: gifConvertCmdOpts,
        usageLine: "",
        zshTail: coreCliSurfaceZshTailFiles),
      CoreCliSurfaceTopCmd(
        name: "compress",
        nestedWords: @[],
        options: gifConvertCmdOpts,
        usageLine: "",
        zshTail: coreCliSurfaceZshTailFiles),
      CoreCliSurfaceTopCmd(
        name: "completion",
        nestedWords: @["zsh"],
        options: @[],
        usageLine: "completions-zsh",
        zshTail: coreCliSurfaceZshTailNestedWords),
    ],
    topOptions: gifConvertTopHelpOpts,
    usagePreamble: @[
      "-h",
      "convert [options] [files...]",
      "compress [options] [files...]",
      "[options] [files...]",
    ],
    zshFunc: "_video-to-gif",
  )
  ## Zsh completion script (from ``gifConvertCoreCliSurface``).
  gifConvertZshCompletionScript = coreCliSurfaceZshScript(gifConvertCoreCliSurface)


## Converts a byte count to a floating megabyte value (base 1024).
proc coreBytesMbFrom(size: int64): float =
  float64(size) / 1024.0 / 1024.0


## Writes ``body`` to stdout with a blank line before and after (for ``-h`` / help output).
## Optional ``docAttrsPrefix`` / ``docAttrsSuffix`` wrap ``body`` (e.g. faint ANSI for no-arg help).
proc coreCliHelpStdoutWrite(body: string; docAttrsPrefix = ""; docAttrsSuffix = "") =
  stdout.write '\n'
  stdout.write docAttrsPrefix
  stdout.write body
  stdout.write docAttrsSuffix
  if not body.endsWith('\n'):
    stdout.write '\n'
  stdout.write '\n'


## True if ``cmd`` resolves on ``PATH``.
proc coreCommandAvailableOnPath(cmd: string): bool =
  findExe(cmd).len > 0


## True when ``e`` looks like interrupt during ``readLine`` (``syncio`` errno 4 ``EINTR`` or macOS
## errno 5 ``EIO`` on stdin), not an unrelated I/O failure.
proc coreIoErrorIsPromptCancel(e: ref IOError): bool =
  e.msg.startsWith("errno: 4 ") or e.msg.startsWith("errno: 5 ")


## Prompts on stdout and reads one trimmed line from stdin. ``readLine`` can raise ``IOError`` on
## Ctrl+C; only treat cancel-shaped errors as user exit (130).
proc coreLinePrompt(msg: string): string =
  stdout.write(msg & ": ")
  try:
    result = readLine(stdin).strip()
  except IOError as e:
    if isatty(stdin) and coreIoErrorIsPromptCancel(e):
      quit(130)
    raise


## SIGINT callback: sets ``coreInterruptRequested`` (keep minimal; async-signal-safe).
proc coreSigIntHandler(sig: cint) {.noconv.} =
  coreInterruptRequested = 1


## Installs ``SIGINT`` handling and clears the interrupt flag.
proc coreInterruptHandlerInstall() =
  coreInterruptRequested = 0
  var sa: Sigaction
  sa.sa_handler = coreSigIntHandler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGINT, sa, nil)


## Restores default ``SIGINT`` handling (``SIG_DFL``).
proc coreInterruptHandlerRestore() =
  var sa: Sigaction
  sa.sa_handler = SIG_DFL
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGINT, sa, nil)


## True if the user has pressed Ctrl+C since the handler was installed.
proc corePendingInterrupt*(): bool =
  coreInterruptRequested != 0


## Runs ``cmd`` with inherited stdio; returns empty on success, an error string on failure, or
## ``coreCommandRunInterrupted`` after SIGINT (child terminated with ``terminate``).
## The child runs under ``/bin/sh`` with ``trap '' INT`` so terminal Ctrl+C does not deliver SIGINT
## to ``ffmpeg``. The parent still handles interrupt via ``corePendingInterrupt`` and ``terminate``.
proc coreCommandRunExternal(cmd: string; args: openArray[string]): string =
  let resolved = if findExe(cmd).len > 0: findExe(cmd) else: cmd
  var shLine = "trap '' INT; exec " & quoteShell(resolved)
  for a in args:
    shLine.add ' '
    shLine.add quoteShell(a)
  var p = startProcess("/bin/sh", args = @["-c", shLine], options = {poParentStreams})
  while true:
    if corePendingInterrupt():
      try:
        terminate(p)
      except CatchableError:
        discard
      discard waitForExit(p)
      close(p)
      return coreCommandRunInterrupted
    let code = peekExitCode(p)
    if code != -1:
      close(p)
      if code != 0:
        return cmd & " failed (exit " & $code & ")"
      return ""
    sleep(40)


## Typical package-manager install for ``cmd`` (macOS / Linux); generic hint otherwise.
proc coreInstallHint(cmd: string): string =
  when defined(macosx):
    case cmd
    of "ffmpeg":
      "brew install ffmpeg"
    of "trash":
      "brew install trash"
    else:
      "brew install <name> or see upstream docs"
  elif defined(linux):
    case cmd
    of "ffmpeg":
      "sudo apt install ffmpeg  # or: sudo dnf install ffmpeg"
    of "trash":
      "sudo apt install trash-cli  # or: sudo dnf install trash-cli"
    else:
      "install with your distro package manager"
  else:
    "install from your OS vendor or project homepages (ffmpeg, trash)"


## Returns an error message if required tools are missing; empty string if the runtime is usable.
proc coreRuntimeValidate(replace, skipTrash: bool): string =
  proc missingCommands(commands: openArray[string]): seq[string] =
    for c in commands:
      if not coreCommandAvailableOnPath(c):
        result.add(c)

  var parts: seq[string]
  let missing = missingCommands(["ffmpeg"])
  if missing.len > 0:
    parts.add("missing required commands: " & missing.join(", "))
    parts.add("Install hints:")
    for m in missing:
      parts.add("  " & m & ":  " & coreInstallHint(m))
  if replace and not skipTrash and not coreCommandAvailableOnPath("trash"):
    parts.add("trash command is required for --replace unless --skipTrash is set")
    parts.add("  trash:  " & coreInstallHint("trash"))
  parts.join("\n")


## True when stdin and stdout are both interactive TTYs.
proc coreTtyIs(): bool =
  isatty(stdin) and isatty(stdout)


## Returns CLI paths as-is, or prompts interactively when stdin is a TTY and CI mode is off.
proc coreInputsResolve(args: seq[string]; ci: bool): seq[string] =
  if args.len > 0:
    return args
  if ci or not coreTtyIs():
    return @[]
  let answer = coreLinePrompt("Enter one or more video files, separated by spaces or commas")
  if answer.len == 0:
    return @[]
  for part in answer.split({' ', '\t', ','}):
    let t = part.strip()
    if t.len > 0:
      result.add(t)


## If ``absPath`` starts with ``home`` as a directory prefix, returns tilde form (``~`` + suffix).
proc corePathDisplayTilde(home, absPath: string): string =
  if home.len == 0 or absPath.len < home.len:
    return absPath
  if not absPath.startsWith(home):
    return absPath
  if absPath.len > home.len and absPath[home.len] != DirSep:
    return absPath
  if absPath.len == home.len:
    return "~"
  "~" & absPath[home.len .. ^1]


## Writes ``contents`` to ``HOME/.zsh/completions/zshFileName``. Warns when the directory is created;
## prints an ``fpath``/``compinit`` hint only in that case.
proc coreZshCompletionFileWrite(appBin, zshFileName, contents: string) =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine appBin, ": HOME is not set"
    quit(1)
  let dir = home / ".zsh" / "completions"
  let dirExisted = dir.dirExists
  if not dirExisted:
    stderr.writeLine appBin, ": warning: ", corePathDisplayTilde(home, dir),
      " did not exist; creating it"
    createDir(dir)
  let path = dir / zshFileName
  writeFile(path, contents)
  stdout.writeLine appBin, ": wrote ", corePathDisplayTilde(home, path)
  if not dirExisted:
    stdout.writeLine appBin, ": add ", corePathDisplayTilde(home, dir),
      " to fpath before compinit, then restart zsh or run: compinit"


## Maps ``coreCommandRunExternal`` output into ``res``; returns true if the caller should return from
## ``gifFileProcess`` (interrupt or error).
proc gifApplyCommandErr(res: var GifResult; err: string): bool =
  if err == coreCommandRunInterrupted:
    res.status = gifStatusSkipped
    res.message = gifMessageInterrupted
    return true
  if err.len > 0:
    res.status = gifStatusFailed
    res.message = err
    return true
  false


## Returns the file name including extension (``splitFile`` stem + ext).
proc gifBaseFile(path: string): string =
  let (_, name, ext) = splitFile(path)
  name & ext


## ffmpeg filter graph: fps cap, shrink-only scale, even dimensions, ``palettegen`` +
## ``paletteuse``.
proc gifFilterGraphFfmpeg(fps, widthMax, colors: int): string =
  &"fps={fps},scale='min(iw,{widthMax})':-2:flags=lanczos," &
  &"crop=iw-mod(iw\\,2):ih-mod(ih\\,2),split[s0][s1];" &
  &"[s0]palettegen=max_colors={colors}:stats_mode=diff[p];" &
  &"[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"


## Sibling output path: same directory as ``source`` with stem ``.gif``.
proc gifPathOutput(source: string): string =
  let (dir, name, _) = splitFile(source)
  joinPath(dir, name & ".gif")


## File size in bytes, or zero if stat fails.
proc gifFileSizeSafe(path: string): int64 =
  try:
    getFileSize(path)
  except OSError:
    0


## Invokes ffmpeg with the palette GIF pipeline.
proc gifWritePipeline(source, destination: string; opts: GifConvertOptions): string =
  let vf = gifFilterGraphFfmpeg(opts.fps, opts.widthMax, opts.colors)
  coreCommandRunExternal("ffmpeg", @[
    "-nostdin",
    "-v", "error",
    "-hide_banner",
    "-loglevel", "quiet",
    "-i", source,
    "-vf", vf,
    "-f", "gif",
    "-loop", "0",
    destination,
  ])


## Copies the source modification time to ``destination``; mutates ``res`` on failure; returns true
## if caller should return.
proc gifTimestampApply(source, destination: string; res: var GifResult): bool =
  try:
    let t = getLastModificationTime(source)
    setLastModificationTime(destination, t)
  except CatchableError as e:
    res.status = gifStatusFailed
    res.message = e.msg
    return true
  false


## After a successful GIF row, optionally delete the original video (output stays ``stem.gif``).
proc gifReplaceApply(res: var GifResult; opts: GifConvertOptions; source: string) =
  if not opts.replace:
    return
  if opts.skipTrash:
    try:
      removeFile(source)
    except CatchableError as e:
      res.status = gifStatusFailed
      res.message = e.msg
      return
  else:
    if gifApplyCommandErr(res, coreCommandRunExternal("trash", @[source])):
      return


## Converts one video to ``stem.gif``, copies timestamp metadata, optionally removes the source;
## returns a row for reporting.
proc gifFileProcess(source: string; opts: GifConvertOptions): GifResult =
  result.source = source
  if not fileExists(source):
    result.status = gifStatusSkipped
    result.message = "no such file"
    return
  if dirExists(source):
    result.status = gifStatusSkipped
    result.message = "path is a directory, not a file"
    return
  if splitFile(source).ext.toLowerAscii() == ".gif":
    result.status = gifStatusSkipped
    result.message = "source is already a GIF"
    return
  let destination = gifPathOutput(source)
  result.destination = destination
  if normalizedPath(source) == normalizedPath(destination):
    result.status = gifStatusSkipped
    result.message = "source and destination are the same path"
    return
  if fileExists(destination):
    result.status = gifStatusSkipped
    result.message = gifBaseFile(destination) & " already exists"
    return
  let bytesBefore = gifFileSizeSafe(source)
  result.bytesBefore = bytesBefore
  let parent = parentDir(destination)
  if parent.len > 0:
    try:
      createDir(parent)
    except CatchableError as e:
      result.status = gifStatusFailed
      result.message = e.msg
      return
  let errGif = gifWritePipeline(source, destination, opts)
  if gifApplyCommandErr(result, errGif):
    if fileExists(destination) and errGif != coreCommandRunInterrupted:
      try:
        removeFile(destination)
      except CatchableError:
        discard
    return
  if not fileExists(destination):
    result.status = gifStatusFailed
    result.message = "ffmpeg did not write the destination file"
    return
  if gifTimestampApply(source, destination, result):
    return
  result.bytesAfter = gifFileSizeSafe(destination)
  result.status = gifStatusProcessed
  gifReplaceApply(result, opts, source)


## True if any result row has status ``gifStatusFailed``.
proc gifFailuresPresent(results: seq[GifResult]): bool =
  for r in results:
    if r.status == gifStatusFailed:
      return true
  false


## Prints one ``ok`` / ``skip`` / ``fail`` line for a result row.
proc gifStatusPrint(r: GifResult) =
  case r.status
  of gifStatusProcessed:
    let extra = if r.message.len > 0: " " & r.message else: ""
    let mbBefore = coreBytesMbFrom(r.bytesBefore)
    let mbAfter = coreBytesMbFrom(r.bytesAfter)
    let saved = coreBytesMbFrom(r.bytesBefore - r.bytesAfter)
    let lineOut =
      &"ok {r.source} -> {r.destination} ({mbBefore:.2f} MB -> {mbAfter:.2f} MB, saved " &
      &"{saved:.2f} MB)"
    stdout.writeLine(lineOut & extra)
  of gifStatusSkipped:
    stdout.writeLine &"skip {r.source}: {r.message}"
  else:
    stdout.writeLine &"fail {r.source}: {r.message}"


## Prints aggregate counts and size totals for the batch.
proc gifSummaryPrint(results: seq[GifResult]) =
  var processed, skipped, failed: int
  var bytesBeforeTotal, bytesAfterTotal: int64
  for r in results:
    bytesBeforeTotal += r.bytesBefore
    bytesAfterTotal += r.bytesAfter
    case r.status
    of gifStatusProcessed:
      inc processed
    of gifStatusSkipped:
      inc skipped
    of gifStatusFailed:
      inc failed
    else:
      discard
  stdout.writeLine "\nSummary"
  stdout.writeLine &"  Processed: {processed}"
  stdout.writeLine &"  Skipped: {skipped}"
  stdout.writeLine &"  Failed: {failed}"
  stdout.writeLine &"  Original MB: {coreBytesMbFrom(bytesBeforeTotal):.2f}"
  stdout.writeLine &"  GIF MB: {coreBytesMbFrom(bytesAfterTotal):.2f}"
  stdout.writeLine &"  Saved MB: {coreBytesMbFrom(bytesBeforeTotal - bytesAfterTotal):.2f}\n"


## Validates runtime, resolves inputs, runs the batch, prints summary; exits non-zero on failure or
## interrupt.
proc gifConvertRun(files: seq[string]; opts: GifConvertOptions) =
  coreInterruptHandlerInstall()
  defer:
    coreInterruptHandlerRestore()
  let v = coreRuntimeValidate(opts.replace, opts.skipTrash)
  if v.len > 0:
    stderr.writeLine v
    quit(1)
  let resolved = coreInputsResolve(files, opts.ci)
  if resolved.len == 0:
    stderr.writeLine "provide one or more video files"
    quit(1)
  var results: seq[GifResult]
  for source in resolved:
    if corePendingInterrupt():
      stderr.writeLine ""
      stderr.writeLine "Interrupted."
      gifSummaryPrint(results)
      quit(130)
    let t0 = epochTime()
    var r = gifFileProcess(source, opts)
    r.secondsElapsed = epochTime() - t0
    results.add(r)
    gifStatusPrint(r)
    if r.message == gifMessageInterrupted:
      stderr.writeLine ""
      stderr.writeLine "Interrupted."
      gifSummaryPrint(results)
      quit(130)
  gifSummaryPrint(results)
  if gifFailuresPresent(results):
    quit(1)


proc gifParseDim(raw: string; name: string; dflt: int): int =
  if raw.len == 0:
    return dflt
  try:
    result = parseInt(raw)
  except ValueError:
    stderr.writeLine "invalid ", name, ": ", raw
    quit(1)


proc gifParseFps(raw: string): int =
  result = gifParseDim(raw, "fps", gifFpsDefault)
  if result < 1:
    stderr.writeLine "--fps must be at least 1"
    quit(1)


proc gifParseColors(raw: string): int =
  if raw.len == 0:
    return gifColorsDefault
  try:
    result = parseInt(raw)
  except ValueError:
    stderr.writeLine "invalid colors: ", raw
    quit(1)
  if result < 2 or result > 256:
    stderr.writeLine "--colors must be between 2 and 256"
    quit(1)


## Converts video to palette-optimized GIF.
proc gifConvertHandle(ctx: CliContext) =
  let maxWidthRaw = ctx.optString("maxWidth")
  let fpsRaw = ctx.optString("fps")
  let colorsRaw = ctx.optString("colors")
  let maxWidth = gifParseDim(if maxWidthRaw.isSome: maxWidthRaw.get else: $gifWidthDefault, "maxWidth", gifWidthDefault)
  if maxWidth < 1:
    stderr.writeLine "--maxWidth must be at least 1"
    quit(1)
  let fps = gifParseFps(if fpsRaw.isSome: fpsRaw.get else: $gifFpsDefault)
  let colors = gifParseColors(if colorsRaw.isSome: colorsRaw.get else: $gifColorsDefault)
  let o = GifConvertOptions(
    ci: ctx.optFlag("ci"),
    colors: colors,
    fps: fps,
    replace: ctx.optFlag("replace"),
    skipTrash: ctx.optFlag("skipTrash"),
    widthMax: maxWidth,
  )
  gifConvertRun(ctx.args, o)


when isMainModule:
  let gifCliArgumentFiles = @[
    cliArgList(
      "files",
      "Input video paths (writes stem.gif next to each unless blocked).",
      min = 0,
      max = 0,
    ),
  ]
  let gifCliOptions = @[
    cliOptFlag("ci", "CI mode: if argv has no paths, exit instead of prompting on a TTY."),
    cliOptFlag(
      "replace",
      "After a successful GIF: remove the original video (Trash unless --skipTrash).",
    ),
    cliOptFlag(
      "skipTrash",
      "With --replace: delete the original with removeFile instead of trash(1).",
    ),
    cliOptString("maxWidth", "Max width in pixels (ffmpeg shrink-only; never upscale)."),
    cliOptString("fps", "Output frames per second after fps filter."),
    cliOptString(
      "colors",
      "Palette size for GIF (2-256; smaller often means smaller files).",
    ),
  ]
  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "compress",
          "Same behavior as convert (alternate name).",
          gifConvertHandle,
          arguments = gifCliArgumentFiles,
          options = gifCliOptions,
        ),
        cliLeaf(
          "convert",
          "Convert video to palette-optimized GIF (writes stem.gif next to each source).",
          gifConvertHandle,
          arguments = gifCliArgumentFiles,
          options = gifCliOptions,
        ),
      ],
      description: "CLI tool for converting video files to palette-optimized GIFs with ffmpeg.",
      fallbackCommand: some("convert"),
      fallbackMode: cliFallbackWhenUnknown,
      name: "video-to-gif",
      options: @[],
    ),
    commandLineParams(),
  )
