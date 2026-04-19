#!/usr/bin/env -S shebangsy go
#!requires: github.com/spf13/cobra

/*
Tiny CLI built with Cobra: prints "Hello, world!" by default, or greets the first
positional name you pass (same idea as examples/rust/clap.rs).

Usage:
	./examples/go/cobra.go
	./examples/go/cobra.go Alice

Expected (matches the usage lines above in order):
	Hello, world!
	Hello, Alice!
*/

package main

import (
	"fmt"
	"os"
	"github.com/spf13/cobra"
)

// newRootCmd returns a single-command root that greets an optional positional name (default "world").
func newRootCmd() *cobra.Command {
	return &cobra.Command{
		Use:          "cobra [name]",
		Short:        "Print a one-line greeting",
		Args:         cobra.MaximumNArgs(1),
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return greetRun(cmd, args)
		},
	}
}

// greetRun prints "Hello, <name>!" using the first positional argument or "world" when omitted.
func greetRun(cmd *cobra.Command, args []string) error {
	name := "world"
	if len(args) > 0 {
		name = args[0]
	}
	_, err := fmt.Fprintf(cmd.OutOrStdout(), "Hello, %s!\n", name)
	return err
}

// main executes the Cobra root command and exits non-zero on failure.
func main() {
	cmd := newRootCmd()
	cmd.SetOut(os.Stdout)
	cmd.SetErr(os.Stderr)
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
