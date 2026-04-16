#!/usr/bin/env -S shebangsy nim

#[
  shebangsy-stat (Nim)

  Print size and last-write time for each regular file with a fancy CLI interface.

  Usage:
    shebangsy-stat -h
    shebangsy-stat stat [--ci] [files...]
    shebangsy-stat [--ci] [files...]
    shebangsy-stat completion zsh
]#


import std/[options, os, posix, strformat, strutils, terminal, times]
import grab
grab "argsbarg"

type
  ## Flags passed through the stat subcommand.
  StatOptions = object
    ## CI mode: when true, never prompt for paths if argv lists none (non-interactive).
    ci: bool
  ## One row of stat output: path, outcome, optional note, and fields filled when ``statStatusOk``.
  StatRow* = object
    bytes*: int64 ## File size in bytes when ok; otherwise zero.
    lastWrite*: string ## Formatted mtime when ok; otherwise empty.
    message*: string ## Detail or empty.
    path*: string ## Path that was examined.
    status*: string ## ``statStatusOk``, ``statStatusSkipped``, or ``statStatusFailed``.


## Global flag set from the SIGINT handler (async-signal-safe).
var coreInterruptRequested {.global.}: Sig_atomic


const
  ## Stored in ``StatRow.status`` for failures.
  statStatusFailed = "failed"
  ## Stored in ``StatRow.status`` for successful rows.
  statStatusOk = "ok"
  ## Stored in ``StatRow.status`` for skipped rows.
  statStatusSkipped = "skipped"


## Converts a byte count to a floating mebibyte value (base 1024).
proc coreBytesMbFrom(size: int64): float =
  float64(size) / 1024.0 / 1024.0

## Writes ``body`` to stdout with a blank line before and after (for ``-h`` / help output).
proc coreCliHelpStdoutWrite(body: string; docAttrsPrefix = ""; docAttrsSuffix = "") =
  stdout.write '\n'
  stdout.write docAttrsPrefix
  stdout.write body
  stdout.write docAttrsSuffix
  if not body.endsWith('\n'):
    stdout.write '\n'
  stdout.write '\n'


## True when ``e`` looks like interrupt during ``readLine`` (errno 4 EINTR or macOS errno 5 EIO on stdin).
proc coreIoErrorIsPromptCancel(e: ref IOError): bool =
  e.msg.startsWith("errno: 4 ") or e.msg.startsWith("errno: 5 ")

## Prompts on stdout and reads one trimmed line from stdin.
proc coreLinePrompt(msg: string): string =
  stdout.write(msg & ": ")
  try:
    result = readLine(stdin).strip()
  except IOError as e:
    if isatty(stdin) and coreIoErrorIsPromptCancel(e):
      quit(130)
    raise

## True when stdin and stdout are both interactive TTYs.
proc coreTtyIs(): bool =
  isatty(stdin) and isatty(stdout)

## Returns CLI paths as-is, or prompts interactively when stdin is a TTY and CI mode is off.
proc coreInputsResolve(args: seq[string]; ci: bool): seq[string] =
  if args.len > 0:
    return args
  if ci or not coreTtyIs():
    return @[]
  let answer = coreLinePrompt(
    "Enter one or more file paths, separated by spaces or commas")
  if answer.len == 0:
    return @[]
  for part in answer.split({' ', '\t', ','}):
    let t = part.strip()
    if t.len > 0:
      result.add(t)

## True if the user has pressed Ctrl+C since the handler was installed.
proc corePendingInterrupt*(): bool =
  coreInterruptRequested != 0

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

## Collects size and mtime for one path; fills ``StatRow`` for reporting.
proc statFileProcess(path: string): StatRow =
  result.path = path
  if not fileExists(path):
    result.status = statStatusSkipped
    result.message = "no such file"
    return
  if dirExists(path):
    result.status = statStatusSkipped
    result.message = "path is a directory, not a regular file"
    return
  try:
    let info = getFileInfo(path, followSymlink = true)
    result.status = statStatusOk
    result.bytes = info.size
    result.lastWrite = format(info.lastWriteTime, "yyyy-MM-dd HH:mm:sszzz")
  except CatchableError as e:
    result.status = statStatusFailed
    result.message = e.msg

## Prints one line for a stat row (ok / skip / fail).
proc statStatusPrint(r: StatRow) =
  case r.status
  of statStatusOk:
    let mib = coreBytesMbFrom(r.bytes)
    stdout.writeLine(&"{r.path}  {r.bytes} bytes  ({mib:.2f} MiB)  mtime {r.lastWrite}")
  of statStatusSkipped:
    stdout.writeLine(&"skip {r.path}: {r.message}")
  else:
    stdout.writeLine(&"fail {r.path}: {r.message}")

## Resolves inputs, stats each path, prints lines; exits non-zero if any path failed.
proc statRun(files: seq[string]; opts: StatOptions) =
  coreInterruptHandlerInstall()
  defer:
    coreInterruptHandlerRestore()
  let resolved = coreInputsResolve(files, opts.ci)
  if resolved.len == 0:
    stderr.writeLine "provide one or more paths"
    quit(1)
  var anyFailed = false
  for p in resolved:
    if corePendingInterrupt():
      stderr.writeLine ""
      stderr.writeLine "Interrupted."
      quit(130)
    let r = statFileProcess(p)
    statStatusPrint(r)
    if r.status == statStatusFailed:
      anyFailed = true
  if anyFailed:
    quit(1)


## Prints size and last-write time for each regular file.
proc nimStatHandle(ctx: CliContext) =
  statRun(ctx.args, StatOptions(ci: ctx.optFlag("ci")))


when isMainModule:
  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "stat",
          "Print size and last-write time for each regular file.",
          nimStatHandle,
          arguments = @[
            cliOptPositional(
              "files",
              "Paths to regular files (size and mtime printed for each).",
              isRepeated = true,
            ),
          ],
          options = @[
            cliOptFlag("ci", "CI mode: if argv has no paths, exit instead of prompting on a TTY."),
          ],
        ),
      ],
      description: "Example shebangsy/nim script: print size and last-write time for each regular file.",
      fallbackCommand: some("stat"),
      fallbackMode: cliFallbackWhenUnknown,
      name: "stat",
      options: @[],
    ),
    commandLineParams(),
  )
