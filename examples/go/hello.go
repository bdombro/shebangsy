#!/usr/bin/env -S shebangsy go

/*
Minimal Go hello-world: prints a fixed one-line greeting to stdout.

Usage:
	./examples/go/hello.go

Expected:
	hello from go
*/

package main

import "fmt"

// main prints a one-line hello from the Go shebangsy example.
func main() {
	fmt.Println("hello from go")
}
