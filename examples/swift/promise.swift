#!/usr/bin/env -S shebangsy swift

/*
Minimal ``@main`` entry point: prints one line showing that Swift scripts using
``@main`` are built with ``-parse-as-library`` automatically.

Usage:
	./examples/swift/promise.swift

Expected:
	Hello from @main (swiftc uses -parse-as-library automatically).
*/

/// Minimal ``@main`` example: shebangsy adds ``-parse-as-library`` when the source contains ``@main``.

@main
enum LibDemo {
    /// Entry point for this script (required by ``@main``); body runs like an executable, not top-level script code.
    static func main() {
        print("Hello from @main (swiftc uses -parse-as-library automatically).")
    }
}
