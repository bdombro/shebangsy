#!/usr/bin/env -S shebangsy swift
#!requires: bdombro/swift-argsbarg@0.2.0:ArgsBarg

/*
Small CLI with swift-argsbarg: the ``hello`` subcommand greets ``world`` by default,
supports ``--name`` / ``-n`` and ``--verbose`` / ``-v``, and falls back to ``hello``
when the command is missing or unknown.

Usage:
	./examples/swift/cli-argsbarg.swift hello
	./examples/swift/cli-argsbarg.swift hello --name Ada
	./examples/swift/cli-argsbarg.swift hello -n Ada -v

Expected (one block per usage line above, in order):
	hello world

	hello Ada

	verbose mode
	hello Ada
*/
import ArgsBarg

cliRun(
    CliCommand(
        name: "cli-argsbarg.swift",
        description: "Tiny demo.",
        children: [
            CliCommand(
                name: "hello",
                description: "Say hello.",
                options: [
                    CliOption(
                        name: "name",
                        description: "Who to greet.",
                        kind: .string,
                        shortName: "n"
                    ),
                    CliOption(
                        name: "verbose",
                        description: "Enable extra logging.",
                        shortName: "v"
                    ),
                ],
                handler: { ctx in
                    let name = ctx.stringOpt("name") ?? "world"
                    if ctx.flag("verbose") { print("verbose mode") }
                    print("hello \(name)")
                }
            )
        ],
        fallbackCommand: "hello",
        fallbackMode: .missingOrUnknown
    ))
