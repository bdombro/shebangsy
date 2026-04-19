#!/usr/bin/env -S shebangsy nim
#!requires: argsbarg

#[
  PDF Compress

  CLI tool for compressing PDF files with batch operation and optional in-place replacement.
  Uses Ghostscript (``gs``) for compression. Writes a ``*-c.pdf`` sibling by default; with
  ``--replace``, the original is moved to Trash (unless ``--skipTrash``) and the compressed file
  is moved onto the original path. Safe interrupt handling.

  Usage:
    pdf-compress -h
    pdf-compress doc.pdf
    pdf-compress compress doc.pdf
    pdf-compress compress --replace doc.pdf
    pdf-compress compress --replace --skipTrash doc.pdf
    pdf-compress completions-zsh

  With no arguments the program prints overview help; paths and flags may omit ``compress``.

  Code Standards:
    - Non-bundled dependencies must be checked for, print install help if missing, and exit non-zero.
    - Multi-word identifiers:
      - order from general → specific (head-first: main concept, then qualifier)
      - typically topic → optional subtype/format → measured attribute → limit/qualifier
      - e.g. pdfPathCompressed, not compressedPathPdf
    - Field names:
      - minimal tokens within the owning type
      - no repeated type/module/domain prefixes unless required for disambiguation
    - module-scope (aka top-level, not-nested) declarations (except imports) must be
      - documented with a doc comment above the declaration
      - sorted alphabetically by identifier
      - prefixed with "pdf" if part of PDF or compression domain; else "core"
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
      - default to no shortened flags for newly added options (existing short flags preserved)
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
  ## Flags passed through the compress pipeline (avoids long primitive parameter lists).
  PdfCompressOptions = object
    ## CI mode: when true, never prompt for file paths if argv lists none (non-interactive).
    ci: bool
    ## Ghostscript preset: 1 screen, 2 ebook (default), 3 default (see ``pdfSettingStr``).
    quality: int
    ## When true, move compressed output onto the original path (same extension as source).
    replace: bool
    ## When true with ``replace``, remove the original with ``removeFile`` instead of ``trash``.
    skipTrash: bool
  ## One row in the batch report: paths, status, sizes, and optional note.
  PdfResult* = object
    bytesAfter*: int64 ## Output file size in bytes after compression.
    bytesBefore*: int64 ## Source file size in bytes before compression.
    destination*: string ## Output path (or final path after replace).
    message*: string ## Detail or empty.
    secondsElapsed*: float ## Wall time spent on this file.
    source*: string ## Input path for this row.
    status*: string ## ``pdfStatusProcessed``, ``pdfStatusSkipped``, or ``pdfStatusFailed``.


## Global flag set from the SIGINT handler (async-signal-safe).
var coreInterruptRequested {.global.}: Sig_atomic


const
  ## Sentinel returned by ``coreCommandRunExternal`` when the user requests cancel (Ctrl+C /
  ## SIGINT).
  coreCommandRunInterrupted = "\xffINTERRUPTED"
  ## Message when processing stopped due to SIGINT (paired with ``pdfStatusSkipped``).
  pdfMessageInterrupted = "interrupted"
  ## Default Ghostscript quality preset (maps to ``-dPDFSETTINGS`` via ``pdfSettingStr``).
  pdfQualityDefault = 2
  ## Stored in ``PdfResult.status`` for failures.
  pdfStatusFailed = "failed"
  ## Stored in ``PdfResult.status`` for successful rows.
  pdfStatusProcessed = "processed"
  ## Stored in ``PdfResult.status`` for skipped or interrupted rows.
  pdfStatusSkipped = "skipped"


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
  pdfCompressTopHelpOpts = @[
    CoreCliSurfaceOptionSpec(
      help: "Show help",
      names: @["-h", "--help"],
      takesValue: false,
      valuePlaceholder: "",
      valueWords: @[]),
  ]
  pdfCompressCmdOpts = @[
    CoreCliSurfaceOptionSpec(
      help: "CI mode: if argv has no paths, exit instead of prompting on a TTY",
      names: @["--ci"],
      takesValue: false,
      valuePlaceholder: "",
      valueWords: @[]),
    CoreCliSurfaceOptionSpec(
      help: "Move compressed output onto the original path (same extension as source)",
      names: @["-r", "--replace"],
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
      help: "Ghostscript preset: 1 screen, 2 ebook (default), 3 default",
      names: @["-q", "--quality"],
      takesValue: true,
      valuePlaceholder: "preset",
      valueWords: @["1", "2", "3"]),
  ]
  ## Declarative CLI surface for zsh completion and usage lines.
  pdfCompressCoreCliSurface = CoreCliSurfaceSpec(
    defaultSubcommand: "compress",
    prog: "pdf-compress",
    topCommands: @[
      CoreCliSurfaceTopCmd(
        name: "compress",
        nestedWords: @[],
        options: pdfCompressCmdOpts,
        usageLine: "",
        zshTail: coreCliSurfaceZshTailFiles),
      CoreCliSurfaceTopCmd(
        name: "completion",
        nestedWords: @["zsh"],
        options: @[],
        usageLine: "completions-zsh",
        zshTail: coreCliSurfaceZshTailNestedWords),
    ],
    topOptions: pdfCompressTopHelpOpts,
    usagePreamble: @["-h", "compress [options] [files...]", "[options] [files...]"],
    zshFunc: "_pdf-compress",
  )
  ## Zsh completion script (from ``pdfCompressCoreCliSurface``).
  pdfCompressZshCompletionScript = coreCliSurfaceZshScript(pdfCompressCoreCliSurface)


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


## Restores default ``SIGINT`` handling (``SIG_DFL``).
proc coreInterruptHandlerRestore() =
  var sa: Sigaction
  sa.sa_handler = SIG_DFL
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGINT, sa, nil)


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


## True if the user has pressed Ctrl+C since the handler was installed.
proc corePendingInterrupt*(): bool =
  coreInterruptRequested != 0


## Runs ``cmd`` with inherited stdio; returns empty on success, an error string on failure, or
## ``coreCommandRunInterrupted`` after SIGINT (child terminated with ``terminate``).
## The child runs under ``/bin/sh`` with ``trap '' INT`` so terminal Ctrl+C does not deliver SIGINT
## to ``gs`` (avoids noisy stack traces); the parent still handles interrupt via
## ``corePendingInterrupt`` and ``terminate``.
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
    of "gs", "ghostscript":
      "brew install ghostscript"
    of "trash":
      "brew install trash"
    else:
      "brew install <name> or see upstream docs"
  elif defined(linux):
    case cmd
    of "gs", "ghostscript":
      "sudo apt install ghostscript  # or: sudo dnf install ghostscript"
    of "trash":
      "sudo apt install trash-cli  # or: sudo dnf install trash-cli"
    else:
      "install with your distro package manager"
  else:
    "install from your OS vendor or project homepages (Ghostscript, trash)"


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


## True when stdin and stdout are both interactive TTYs.
proc coreTtyIs(): bool =
  isatty(stdin) and isatty(stdout)


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
## ``pdfFileProcess`` (interrupt or error).
proc pdfApplyCommandErr(res: var PdfResult; err: string): bool =
  if err == coreCommandRunInterrupted:
    res.status = pdfStatusSkipped
    res.message = pdfMessageInterrupted
    return true
  if err.len > 0:
    res.status = pdfStatusFailed
    res.message = err
    return true
  false


## Returns CLI paths as-is, or prompts interactively when stdin is a TTY and CI mode is off.
proc pdfInputsResolve(args: seq[string]; ci: bool): seq[string] =
  if args.len > 0:
    return args
  if ci or not coreTtyIs():
    return @[]
  let answer = coreLinePrompt("Enter one or more PDF files, separated by spaces or commas")
  if answer.len == 0:
    return @[]
  for part in answer.split({' ', '\t', ','}):
    let t = part.strip()
    if t.len > 0:
      result.add(t)


## True if any result row has status ``pdfStatusFailed``.
proc pdfFailuresPresent(results: seq[PdfResult]): bool =
  for r in results:
    if r.status == pdfStatusFailed:
      return true
  false


## File size in bytes, or zero if stat fails.
proc pdfFileSizeSafe(path: string): int64 =
  try:
    getFileSize(path)
  except OSError:
    0


## Lowercase file extension without the leading dot.
proc pdfExtLower(path: string): string =
  let e = splitFile(path).ext
  if e.len > 1:
    e[1 .. ^1].toLowerAscii()
  else:
    ""


## Returns the file name including extension (``splitFile`` stem + ext).
proc pdfBaseFile(path: string): string =
  let (_, name, ext) = splitFile(path)
  name & ext


## Sibling path with stem suffixed by ``-c`` before ``pathExtensionSuffixOut``.
proc pdfPathCompressed(source: string; pathExtensionSuffixOut: string): string =
  let (dir, name, _) = splitFile(source)
  joinPath(dir, name & "-c" & pathExtensionSuffixOut)


## Ghostscript ``-dPDFSETTINGS`` value for preset ``quality`` (1 screen, 2 ebook, 3 default).
proc pdfSettingStr(quality: int): string =
  case quality
  of 1:
    "/screen"
  of 3:
    "/default"
  else:
    "/ebook"


## After a successful compress row, optionally move the compressed file onto the original path.
proc pdfReplaceApply(res: var PdfResult; opts: PdfCompressOptions; source, destination: string) =
  if not opts.replace:
    return
  if splitFile(source).ext.toLowerAscii() != splitFile(destination).ext.toLowerAscii():
    res.status = pdfStatusSkipped
    res.message = "skipping replace because extensions do not match"
    return
  if opts.skipTrash:
    try:
      removeFile(source)
    except CatchableError as e:
      res.status = pdfStatusFailed
      res.message = e.msg
      return
  else:
    if pdfApplyCommandErr(res, coreCommandRunExternal("trash", @[source])):
      return
  try:
    moveFile(destination, source)
  except CatchableError as e:
    res.status = pdfStatusFailed
    res.message = e.msg
    return
  res.destination = source


## Prints one ``ok`` / ``skip`` / ``fail`` line for a result row.
proc pdfStatusPrint(r: PdfResult) =
  case r.status
  of pdfStatusProcessed:
    let extra = if r.message.len > 0: " " & r.message else: ""
    let mbBefore = coreBytesMbFrom(r.bytesBefore)
    let mbAfter = coreBytesMbFrom(r.bytesAfter)
    let saved = coreBytesMbFrom(r.bytesBefore - r.bytesAfter)
    let lineOut =
      &"ok {r.source} -> {r.destination} ({mbBefore:.2f} MB -> {mbAfter:.2f} MB, saved " &
      &"{saved:.2f} MB)"
    stdout.writeLine(lineOut & extra)
  of pdfStatusSkipped:
    stdout.writeLine &"skip {r.source}: {r.message}"
  else:
    stdout.writeLine &"fail {r.source}: {r.message}"


## Prints aggregate counts and size totals for the batch.
proc pdfSummaryPrint(results: seq[PdfResult]) =
  var processed, skipped, failed: int
  var bytesBeforeTotal, bytesAfterTotal: int64
  for r in results:
    bytesBeforeTotal += r.bytesBefore
    bytesAfterTotal += r.bytesAfter
    case r.status
    of pdfStatusProcessed:
      inc processed
    of pdfStatusSkipped:
      inc skipped
    of pdfStatusFailed:
      inc failed
    else:
      discard
  stdout.writeLine "\nSummary"
  stdout.writeLine &"  Processed: {processed}"
  stdout.writeLine &"  Skipped: {skipped}"
  stdout.writeLine &"  Failed: {failed}"
  stdout.writeLine &"  Original MB: {coreBytesMbFrom(bytesBeforeTotal):.2f}"
  stdout.writeLine &"  Compressed MB: {coreBytesMbFrom(bytesAfterTotal):.2f}"
  stdout.writeLine &"  Saved MB: {coreBytesMbFrom(bytesBeforeTotal - bytesAfterTotal):.2f}\n"


## Runs Ghostscript to ``destination``, then sets destination mtime from ``source``.
proc pdfWriteGsPipeline(source, destination: string; quality: int): string =
  let settings = pdfSettingStr(quality)
  let err = coreCommandRunExternal("gs", @[
    "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.4", "-dPDFSETTINGS=" & settings,
    "-dNOPAUSE", "-dQUIET", "-dBATCH", "-sOutputFile=" & destination, source])
  if err.len > 0:
    return err
  try:
    let t = getLastModificationTime(source)
    setLastModificationTime(destination, t)
  except CatchableError as e:
    return e.msg
  ""


## Returns an error message if required tools are missing; empty string if the runtime is usable.
proc pdfRuntimeValidate(replace, skipTrash: bool): string =
  proc missingCommands(commands: openArray[string]): seq[string] =
    for c in commands:
      if not coreCommandAvailableOnPath(c):
        result.add(c)

  var parts: seq[string]
  let missing = missingCommands(["gs"])
  if missing.len > 0:
    parts.add("missing required commands: " & missing.join(", "))
    parts.add("Install hints:")
    for m in missing:
      parts.add("  " & m & ":  " & coreInstallHint(m))
  if replace and not skipTrash and not coreCommandAvailableOnPath("trash"):
    parts.add("trash command is required for --replace unless --skipTrash is set")
    parts.add("  trash:  " & coreInstallHint("trash"))
  parts.join("\n")


## Handles the case where compressed output is larger than the source.
## With ``replace``, keeps source untouched and skips replace with a warning.
## Without ``replace``, rewrites destination with a copy of source and warns.
proc pdfLargerOutputHandle(res: var PdfResult; opts: PdfCompressOptions; source, destination: string): bool =
  if res.bytesAfter <= res.bytesBefore:
    return false
  if opts.replace:
    res.message = "warning: compressed file is larger than source; skipping replace"
    return true
  try:
    removeFile(destination)
    copyFile(source, destination)
  except CatchableError as e:
    res.status = pdfStatusFailed
    res.message = e.msg
    return true
  res.bytesAfter = res.bytesBefore
  res.message = "warning: compressed file is larger than source; copied original to destination"
  true


## Compresses one PDF, copies mtime from source, optional in-place replace; returns a row for
## reporting.
proc pdfFileProcess(source: string; opts: PdfCompressOptions): PdfResult =
  result.source = source
  if not fileExists(source):
    result.status = pdfStatusSkipped
    result.message = "no such file"
    return
  if dirExists(source):
    result.status = pdfStatusSkipped
    result.message = "path is a directory, not a file"
    return
  if pdfExtLower(source) != "pdf":
    result.status = pdfStatusSkipped
    result.message = "unsupported extension: " & pdfExtLower(source)
    return
  let destination = pdfPathCompressed(source, ".pdf")
  result.destination = destination
  if fileExists(destination):
    result.status = pdfStatusSkipped
    result.message = pdfBaseFile(destination) & " already exists"
    return
  let bytesBefore = pdfFileSizeSafe(source)
  result.bytesBefore = bytesBefore
  let parent = parentDir(destination)
  if parent.len > 0:
    try:
      createDir(parent)
    except CatchableError as e:
      result.status = pdfStatusFailed
      result.message = e.msg
      return
  let errGs = pdfWriteGsPipeline(source, destination, opts.quality)
  if pdfApplyCommandErr(result, errGs):
    return
  if not fileExists(destination):
    result.status = pdfStatusFailed
    result.message = "Ghostscript did not write the destination file"
    return
  let bytesAfter = pdfFileSizeSafe(destination)
  result.bytesAfter = bytesAfter
  result.status = pdfStatusProcessed
  if pdfLargerOutputHandle(result, opts, source, destination):
    return
  pdfReplaceApply(result, opts, source, destination)


## Validates runtime, resolves inputs, runs the batch, prints summary; exits non-zero on failure or
## interrupt.
proc pdfCompressRun(files: seq[string]; opts: PdfCompressOptions) =
  coreInterruptHandlerInstall()
  defer:
    coreInterruptHandlerRestore()
  let v = pdfRuntimeValidate(opts.replace, opts.skipTrash)
  if v.len > 0:
    stderr.writeLine v
    quit(1)
  if opts.quality < 1 or opts.quality > 3:
    stderr.writeLine "quality must be 1, 2, or 3 (Ghostscript presets)"
    quit(1)
  let resolved = pdfInputsResolve(files, opts.ci)
  if resolved.len == 0:
    stderr.writeLine "provide one or more PDF files"
    quit(1)
  var results: seq[PdfResult]
  for src in resolved:
    if corePendingInterrupt():
      stderr.writeLine ""
      stderr.writeLine "Interrupted."
      pdfSummaryPrint(results)
      quit(130)
    let t0 = epochTime()
    var r = pdfFileProcess(src, opts)
    r.secondsElapsed = epochTime() - t0
    results.add(r)
    pdfStatusPrint(r)
    if r.message == pdfMessageInterrupted:
      stderr.writeLine ""
      stderr.writeLine "Interrupted."
      pdfSummaryPrint(results)
      quit(130)
  pdfSummaryPrint(results)
  if pdfFailuresPresent(results):
    quit(1)


proc pdfParseQualityPreset(raw: string): int =
  if raw.len == 0:
    return pdfQualityDefault
  try:
    result = parseInt(raw)
  except ValueError:
    stderr.writeLine "invalid quality: ", raw
    quit(1)
  if result < 1 or result > 3:
    stderr.writeLine "quality must be 1, 2, or 3 (Ghostscript presets)"
    quit(1)


## Compresses PDFs with Ghostscript.
proc pdfCompressHandle(ctx: CliContext) =
  let qualityRaw = ctx.optString("quality")
  let q = pdfParseQualityPreset(if qualityRaw.isSome: qualityRaw.get else: $pdfQualityDefault)
  let o = PdfCompressOptions(
    ci: ctx.optFlag("ci"),
    quality: q,
    replace: ctx.optFlag("replace"),
    skipTrash: ctx.optFlag("skipTrash"),
  )
  pdfCompressRun(ctx.args, o)


when isMainModule:
  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "compress",
          "Compress PDFs with Ghostscript (writes *-c.pdf* sibling unless --replace).",
          pdfCompressHandle,
          arguments = @[
            cliArgList(
              "files",
              "Input PDF paths (writes *-c.pdf* sibling unless --replace).",
              min = 0,
              max = 0,
            ),
          ],
          options = @[
            cliOptFlag("ci", "CI mode: if argv has no paths, exit instead of prompting on a TTY."),
            cliOptFlag(
              "replace",
              "Move compressed output onto the original path (same extension as source).",
              'r',
            ),
            cliOptFlag(
              "skipTrash",
              "With --replace: delete the original with removeFile instead of trash(1).",
            ),
            cliOptString(
              "quality",
              "Ghostscript preset: 1 screen, 2 ebook (default), 3 default.",
              'q',
            ),
          ],
        ),
      ],
      description: "CLI tool for compressing PDF files with Ghostscript.",
      fallbackCommand: some("compress"),
      fallbackMode: cliFallbackWhenUnknown,
      name: "pdf-compress",
      options: @[],
    ),
    commandLineParams(),
  )
