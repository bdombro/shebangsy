#!/usr/bin/env -S shebangsy rust
#!requires: clap@4@features=[derive]

/*
Tiny CLI with Clap: prints "Hello, world!" by default, or greets the optional
positional name (mirrors examples/go/cobra.go).

Usage:
	./examples/rust/clap.rs
	./examples/rust/clap.rs World

Expected (matches the usage lines above in order):
	Hello, world!
	Hello, World!
*/

use clap::Parser;

/// CLI wiring for the minimal greeting example (mirrors `examples/go/cobra.go`).
#[derive(Parser, Debug)]
#[command(
    name = "clap",
    version,
    about = "Print a one-line greeting",
    long_about = "Print a one-line greeting for an optional name (default: world).\n\nUsage:\n  clap [NAME]\n  clap World"
)]
struct Cli {
    /// Who to greet
    #[arg(default_value = "world")]
    name: String,
}

/// Parses CLI args and prints the greeting line to stdout.
fn main() {
    let cli = Cli::parse();
    println!("Hello, {}!", cli.name);
}
