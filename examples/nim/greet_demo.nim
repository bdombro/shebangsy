#!/usr/bin/env -S shebangsy nim
#!requires: argsbarg

#[
  Minimal argsbarg CLI (mirrors examples/go/cobra.go).

  File must not be named ``argsbarg.nim`` (that shadows the ``argsbarg`` package on ``import``).

  Usage:
    chmod +x examples/nim/greet_demo.nim
    ./examples/nim/greet_demo.nim
    ./examples/nim/greet_demo.nim World
]#


import argsbarg


## Prints ``Hello, <name>!`` using the first positional argument or ``world`` when none are given.
proc nimGreetHandle(ctx: CliContext) =
  if ctx.args.len > 1:
    stderr.writeLine("expected at most one name argument")
    quit(1)
  let name =
    if ctx.args.len == 0:
      "world"
    else:
      ctx.args[0]
  stdout.writeLine("Hello, " & name & "!")


when isMainModule:
  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "greet",
          "Print a one-line greeting.",
          nimGreetHandle,
          arguments = @[
            cliArg(
              "name",
              "Who to greet (optional; defaults to world).",
              optional = true,
            ),
          ],
          options = @[],
        ),
      ],
      description: "Example shebangsy/nim script: print a one-line greeting (argsbarg).",
      fallbackCommand: some("greet"),
      fallbackMode: cliFallbackWhenMissingOrUnknown,
      name: "greet-demo",
      options: @[],
    ),
    commandLineParams(),
  )
