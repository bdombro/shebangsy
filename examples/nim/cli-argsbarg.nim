#!/usr/bin/env -S shebangsy nim
#!requires: argsbarg

## Small CLI using argsbarg: the ``hello`` command greets ``world`` by default,
## optional ``--name`` / ``-n``, and ``--verbose`` / ``-v`` for extra output.
## Unknown flags or a missing subcommand fall through to ``hello`` (fallback mode).
##
## Usage:
##   ./examples/nim/cli-argsbarg.nim hello
##   ./examples/nim/cli-argsbarg.nim hello --name=Ada
##   ./examples/nim/cli-argsbarg.nim hello -n Ada -v
##   ./examples/nim/cli-argsbarg.nim --verbose
##
## Expected (``hello`` is colorized green when stdout is a TTY):
##   ``hello`` → ``hello world``
##   ``hello --name=Ada`` → ``hello Ada``
##   ``hello -n Ada -v`` → ``verbose mode enabled`` then ``hello Ada``
##   ``--verbose`` (fallback) → ``verbose mode enabled`` then ``hello world``

import std/[os, options]
import argsbarg

## Default greeting name when `--name` is omitted.
const helloNameDefault = "world"

## Prints a greeting using the optional `--name` value.
proc helloHandler(ctx: CliContext) =
  let nameOpt = ctx.optString("name")
  let name =
    if nameOpt.isSome:
      nameOpt.get
    else:
      helloNameDefault
  if ctx.optFlag("verbose"):
    echo "verbose mode enabled"
  echo styleGreen("hello"), " ", name

## Entry point when this file is compiled as the main module. Uses root fallback so flags can
## appear before ``hello`` (see README: ``fallbackCommand`` / ``fallbackMode``).
when isMainModule:
  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "hello",
          "Print a greeting.",
          helloHandler,
          options = @[
            cliOptString("name", "Name to greet.", 'n'),
            cliOptFlag("verbose", "Print extra logging before the greeting.", 'v'),
          ],
        ),
      ],
      description: "Minimal argsbarg example.",
      fallbackCommand: some("hello"),
      fallbackMode: cliFallbackWhenMissingOrUnknown,
      name: "nim_minimal",
    ),
    commandLineParams(),
  )
