version = "0.1.0"
author = "Brian Dombroski"
description = "POSIX single-file multi-language script runner for Nim, Go, Mojo, cpp, Rust, Swift, and Python3"
license = "MIT"

srcDir = "src"
binDir = "dist"
bin = @["shebangsy"]

requires "nim >= 2.0.0"
requires "argsbarg >= 2.0.0"
