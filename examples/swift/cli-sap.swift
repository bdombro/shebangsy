#!/usr/bin/env -S shebangsy swift
#!requires: apple/swift-argument-parser@1.3.0:ArgumentParser

/*
Greeting CLI using Apple’s ArgumentParser: says "Hello, world!" by default, or
greets the single optional positional name you pass.

Usage:
	./examples/swift/cli-sap.swift
	./examples/swift/cli-sap.swift Ada

Expected (matches the usage lines above in order):
	Hello, world!
	Hello, Ada!
*/
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