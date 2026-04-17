#!/usr/bin/env -S shebangsy swift
#!requires: apple/swift-argument-parser@1.3.0

import ArgumentParser

@main
struct Greet: ParsableCommand {
    @Argument(help: "Who to greet")
    var name: String = "world"

    /// Prints a greeting line for the configured name.
    mutating func run() throws {
        print("Hello, \(name)!")
    }
}