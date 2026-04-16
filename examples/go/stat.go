#!/usr/bin/env -S shebangsy go
// requires: github.com/spf13/cobra

/*
shebangsy-stat (Go)

Seed for new shebangsy go-powered CLI tools.

Usage:
	shebangsy-stat -h
	shebangsy-stat stat [--ci] [paths...]
	shebangsy-stat process [files...]
*/

package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

const (
	appOutputSuffix    = "-out"
	appStatusFailed    = "failed"
	appStatusProcessed = "processed"
	appStatusSkipped   = "skipped"
	appTitle           = "Stat"
	appUse             = "stat"
	statStatusFailed   = "failed"
	statStatusOK       = "ok"
	statStatusSkipped  = "skipped"
)

type appOptions struct {
	dryRun       bool
	noInput      bool
	outputSuffix string
	replace      bool
	trash        bool
	yes          bool
}

type appResult struct {
	bytesAfter     int64
	bytesBefore    int64
	destination    string
	elapsedSeconds float64
	message        string
	source         string
	status         string
}

type appSummary struct {
	name    string
	results []appResult
}

type statRow struct {
	modTime   string
	message   string
	path      string
	sizeBytes int64
	status    string
}

func coreCommandAvailable(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func coreConfirmPrompt(message string, defaultValue bool) bool {
	defaultLabel := "y/N"
	if defaultValue {
		defaultLabel = "Y/n"
	}
	fmt.Fprintf(os.Stdout, "%s [%s]: ", message, defaultLabel)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return defaultValue
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true
	case "n", "no":
		return false
	default:
		return defaultValue
	}
}

func coreCopyFile(source, destination string) error {
	from, err := os.Open(source)
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := os.Create(destination)
	if err != nil {
		return err
	}
	if _, err := io.Copy(to, from); err != nil {
		_ = to.Close()
		return err
	}
	return to.Close()
}

func coreCopyTimestamp(source, destination string) error {
	stat, err := os.Stat(source)
	if err != nil {
		return err
	}
	return os.Chtimes(destination, stat.ModTime(), stat.ModTime())
}

func coreEnsureParentDir(path string) error {
	return os.MkdirAll(filepath.Dir(path), 0o755)
}

func coreExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func coreFileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

func coreIsTTY() bool {
	stdinInfo, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	stdoutInfo, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return stdinInfo.Mode()&os.ModeCharDevice != 0 && stdoutInfo.Mode()&os.ModeCharDevice != 0
}

func coreBytesToMiB(size int64) float64 {
	return float64(size) / 1024.0 / 1024.0
}

func coreCommandsMissing(commands []string) []string {
	missing := make([]string, 0, len(commands))
	for _, command := range commands {
		if !coreCommandAvailable(command) {
			missing = append(missing, command)
		}
	}
	return missing
}

func corePrintRows(out io.Writer, headers []string, rows [][]string) {
	widths := make([]int, len(headers))
	for i, header := range headers {
		widths[i] = len(header)
	}
	for _, row := range rows {
		for i, cell := range row {
			if len(cell) > widths[i] {
				widths[i] = len(cell)
			}
		}
	}
	for i, header := range headers {
		fmt.Fprintf(out, "%-*s  ", widths[i], header)
	}
	fmt.Fprintln(out)
	for _, row := range rows {
		for i, cell := range row {
			fmt.Fprintf(out, "%-*s  ", widths[i], cell)
		}
		fmt.Fprintln(out)
	}
}

func corePromptLine(message string) (string, error) {
	fmt.Fprintf(os.Stdout, "%s: ", message)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

func coreRunCommand(name string, args []string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s failed: %w", name, err)
	}
	return nil
}

func coreDoctorCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Show detected dependencies and their status",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Fprintln(cmd.OutOrStdout(), "App dependencies")
			corePrintRows(cmd.OutOrStdout(), []string{"Dependency", "Status", "Details"}, statDoctorRows())
			return nil
		},
	}
}

func coreFlagsNonDefault(opts *appOptions) bool {
	return opts.trash || opts.replace || opts.dryRun || opts.yes || opts.noInput || opts.outputSuffix != appOutputSuffix
}

func coreProcessCommand(opts *appOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "process [files...]",
		Short: "Process one or more files",
		Args:  cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return coreRunProcess(cmd, args, opts)
		},
	}
}

func coreRootCommand() *cobra.Command {
	opts := &appOptions{outputSuffix: appOutputSuffix}
	cmd := &cobra.Command{
		Use:           appUse,
		Short:         "Seed for new go-powered CLI tools",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 && !coreFlagsNonDefault(opts) {
				return cmd.Help()
			}
			return coreRunProcess(cmd, args, opts)
		},
	}
	cmd.SetOut(os.Stdout)
	cmd.SetErr(os.Stderr)
	cmd.PersistentFlags().BoolVar(&opts.trash, "trash", false, "Move originals to the Trash after processing")
	cmd.PersistentFlags().BoolVar(&opts.replace, "replace", false, "Replace originals after processing")
	cmd.PersistentFlags().BoolVar(&opts.dryRun, "dry-run", false, "Show what would happen without writing files")
	cmd.PersistentFlags().BoolVar(&opts.yes, "yes", false, "Skip interactive confirmations")
	cmd.PersistentFlags().BoolVar(&opts.noInput, "no-input", false, "Do not prompt for missing files or confirmations")
	cmd.PersistentFlags().StringVar(&opts.outputSuffix, "suffix", appOutputSuffix, "Suffix to add before the output file extension")
	cmd.AddCommand(coreDoctorCommand())
	cmd.AddCommand(coreProcessCommand(opts))
	cmd.AddCommand(statCommand())
	return cmd
}

func (s appSummary) coreSummaryHasFailures() bool {
	for _, result := range s.results {
		if result.status == appStatusFailed {
			return true
		}
	}
	return false
}

func corePrintProcessRow(out io.Writer, result appResult) {
	switch result.status {
	case appStatusProcessed:
		message := ""
		if result.message != "" {
			message = " " + result.message
		}
		delta := coreBytesToMiB(result.bytesAfter - result.bytesBefore)
		fmt.Fprintf(out, "ok %s -> %s (%.2f MB -> %.2f MB, delta %.2f MB)%s\n",
			result.source, result.destination,
			coreBytesToMiB(result.bytesBefore), coreBytesToMiB(result.bytesAfter),
			delta, message)
	case appStatusSkipped:
		fmt.Fprintf(out, "skip %s: %s\n", result.source, result.message)
	default:
		fmt.Fprintf(out, "fail %s: %s\n", result.source, result.message)
	}
}

func corePrintProcessSummary(out io.Writer, summary appSummary) {
	processed, skipped, failed := 0, 0, 0
	var totalBytesBefore, totalBytesAfter int64
	for _, result := range summary.results {
		totalBytesBefore += result.bytesBefore
		totalBytesAfter += result.bytesAfter
		switch result.status {
		case appStatusProcessed:
			processed++
		case appStatusSkipped:
			skipped++
		case appStatusFailed:
			failed++
		}
	}
	fmt.Fprintln(out, "Summary")
	fmt.Fprintf(out, "  Processed: %d\n", processed)
	fmt.Fprintf(out, "  Skipped: %d\n", skipped)
	fmt.Fprintf(out, "  Failed: %d\n", failed)
	fmt.Fprintf(out, "  Original MB: %.2f\n", coreBytesToMiB(totalBytesBefore))
	fmt.Fprintf(out, "  Output MB: %.2f\n", coreBytesToMiB(totalBytesAfter))
	fmt.Fprintf(out, "  Delta MB: %.2f\n", coreBytesToMiB(totalBytesAfter-totalBytesBefore))
}

func coreProcessFile(source string, opts *appOptions) appResult {
	info, err := os.Stat(source)
	if err != nil || info.IsDir() {
		return appResult{source: source, status: appStatusSkipped, message: "not found"}
	}
	if err := coreValidateSource(source); err != nil {
		return appResult{source: source, status: appStatusSkipped, message: err.Error()}
	}
	destination := statOutputPath(source, opts.outputSuffix)
	if coreExists(destination) {
		return appResult{source: source, destination: destination, status: appStatusSkipped, message: filepath.Base(destination) + " already exists"}
	}
	bytesBefore := coreFileSize(source)
	if opts.dryRun {
		return appResult{
			source: source, destination: destination, status: appStatusProcessed,
			bytesBefore: bytesBefore, bytesAfter: bytesBefore, message: "dry-run: no file written",
		}
	}
	if err := coreEnsureParentDir(destination); err != nil {
		return appResult{source: source, destination: destination, status: appStatusFailed, bytesBefore: bytesBefore, message: err.Error()}
	}
	if err := coreProcessPayload(source, destination, opts); err != nil {
		return appResult{source: source, destination: destination, status: appStatusFailed, bytesBefore: bytesBefore, message: err.Error()}
	}
	if !coreExists(destination) {
		return appResult{source: source, destination: destination, status: appStatusFailed, bytesBefore: bytesBefore, message: "processor did not write the destination file"}
	}
	if err := coreCopyTimestamp(source, destination); err != nil {
		return appResult{source: source, destination: destination, status: appStatusFailed, bytesBefore: bytesBefore, message: err.Error()}
	}
	bytesAfter := coreFileSize(destination)
	result := appResult{source: source, destination: destination, status: appStatusProcessed, bytesBefore: bytesBefore, bytesAfter: bytesAfter}
	if opts.replace {
		if err := os.Remove(source); err != nil {
			result.status = appStatusFailed
			result.message = err.Error()
			return result
		}
		if err := os.Rename(destination, source); err != nil {
			result.status = appStatusFailed
			result.message = err.Error()
			return result
		}
		result.destination = source
	} else if opts.trash {
		if err := coreRunCommand("trash", []string{source}); err != nil {
			result.status = appStatusFailed
			result.message = err.Error()
			return result
		}
	}
	return result
}

func coreProcessPayload(source, destination string, opts *appOptions) error {
	_ = opts
	return coreCopyFile(source, destination)
}

func coreResolveInputs(args []string, opts *appOptions) ([]string, error) {
	if len(args) > 0 {
		return args, nil
	}
	if opts.noInput || !coreIsTTY() {
		return nil, nil
	}
	answer, err := corePromptLine("Enter one or more files, separated by spaces or commas")
	if err != nil {
		return nil, err
	}
	if answer == "" {
		return nil, nil
	}
	fields := strings.FieldsFunc(answer, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t'
	})
	resolved := make([]string, 0, len(fields))
	for _, field := range fields {
		if trimmed := strings.TrimSpace(field); trimmed != "" {
			resolved = append(resolved, trimmed)
		}
	}
	return resolved, nil
}

func coreRunProcess(cmd *cobra.Command, args []string, opts *appOptions) error {
	if err := coreValidateRuntime(opts); err != nil {
		return err
	}
	files, err := coreResolveInputs(args, opts)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return errors.New("provide one or more files")
	}
	if opts.replace && !opts.yes && coreIsTTY() {
		if !coreConfirmPrompt("Replace the original files after processing?", false) {
			return errors.New("no usable files were provided")
		}
	}
	fmt.Fprintln(cmd.OutOrStdout(), appTitle)
	summary := coreRunProcessBatch(cmd.OutOrStdout(), files, opts)
	corePrintProcessSummary(cmd.OutOrStdout(), summary)
	if summary.coreSummaryHasFailures() {
		return errors.New("one or more files failed")
	}
	return nil
}

func coreRunProcessBatch(out io.Writer, files []string, opts *appOptions) appSummary {
	summary := appSummary{name: appTitle}
	for _, source := range files {
		started := time.Now()
		result := coreProcessFile(source, opts)
		result.elapsedSeconds = time.Since(started).Seconds()
		summary.results = append(summary.results, result)
		corePrintProcessRow(out, result)
	}
	return summary
}

func coreValidateRuntime(opts *appOptions) error {
	missing := coreCommandsMissing(statRequiredCommands())
	if len(missing) > 0 {
		return fmt.Errorf("missing required commands: %s", strings.Join(missing, ", "))
	}
	if opts.outputSuffix == "" {
		return errors.New("suffix must not be empty")
	}
	if opts.trash || opts.replace {
		if !coreCommandAvailable("trash") {
			return errors.New("trash command is required when using --trash or --replace")
		}
	}
	return nil
}

func coreValidateSource(source string) error {
	_ = source
	return nil
}

func statCommand() *cobra.Command {
	var ci bool
	cmd := &cobra.Command{
		Use:   "stat [paths...]",
		Short: "Print size and last-write time for each regular file",
		Args:  cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return statRun(cmd, args, ci)
		},
	}
	cmd.Flags().BoolVar(&ci, "ci", false, "CI mode: if argv has no paths, exit instead of prompting on a TTY")
	return cmd
}

func statDoctorRows() [][]string {
	rows := [][]string{}
	commands := statRequiredCommands()
	if len(commands) == 0 {
		rows = append(rows, []string{"(none)", "ok", "default app implementation only uses Go stdlib file copy"})
	} else {
		for _, command := range commands {
			if coreCommandAvailable(command) {
				rows = append(rows, []string{command, "ok", "available"})
			} else {
				rows = append(rows, []string{command, "missing", "install before running this tool"})
			}
		}
	}
	if coreCommandAvailable("trash") {
		rows = append(rows, []string{"trash", "ok", "available for --trash / --replace"})
	} else {
		rows = append(rows, []string{"trash", "optional", "only needed for trash or replace flows"})
	}
	return rows
}

func statRowFromPath(path string) statRow {
	row := statRow{path: path}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			row.status = statStatusSkipped
			row.message = "no such file"
			return row
		}
		row.status = statStatusFailed
		row.message = err.Error()
		return row
	}
	if info.IsDir() {
		row.status = statStatusSkipped
		row.message = "path is a directory, not a regular file"
		return row
	}
	row.status = statStatusOK
	row.sizeBytes = info.Size()
	row.modTime = info.ModTime().Format("2006-01-02 15:04:05 -07:00")
	return row
}

func statResolveInputs(args []string, ci bool) ([]string, error) {
	if len(args) > 0 {
		return args, nil
	}
	if ci || !coreIsTTY() {
		return nil, nil
	}
	answer, err := corePromptLine("Enter one or more file paths, separated by spaces or commas")
	if err != nil {
		return nil, err
	}
	if answer == "" {
		return nil, nil
	}
	fields := strings.FieldsFunc(answer, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t'
	})
	resolved := make([]string, 0, len(fields))
	for _, field := range fields {
		if trimmed := strings.TrimSpace(field); trimmed != "" {
			resolved = append(resolved, trimmed)
		}
	}
	return resolved, nil
}

func statOutputPath(path, suffix string) string {
	base := filepath.Base(path)
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	return filepath.Join(filepath.Dir(path), stem+suffix+ext)
}

func statRequiredCommands() []string {
	return nil
}

func statPrintRow(out io.Writer, r statRow) {
	switch r.status {
	case statStatusOK:
		mib := coreBytesToMiB(r.sizeBytes)
		fmt.Fprintf(out, "%s  %d bytes  (%.2f MiB)  mtime %s\n", r.path, r.sizeBytes, mib, r.modTime)
	case statStatusSkipped:
		fmt.Fprintf(out, "skip %s: %s\n", r.path, r.message)
	default:
		fmt.Fprintf(out, "fail %s: %s\n", r.path, r.message)
	}
}

func statRun(cmd *cobra.Command, args []string, ci bool) error {
	interruptCh := make(chan os.Signal, 1)
	signal.Notify(interruptCh, os.Interrupt)
	defer signal.Stop(interruptCh)

	paths, err := statResolveInputs(args, ci)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		return errors.New("provide one or more paths")
	}
	out := cmd.OutOrStdout()
	anyFailed := false
	for _, p := range paths {
		select {
		case <-interruptCh:
			fmt.Fprintln(cmd.ErrOrStderr(), "")
			fmt.Fprintln(cmd.ErrOrStderr(), "Interrupted.")
			os.Exit(130)
		default:
		}
		row := statRowFromPath(p)
		statPrintRow(out, row)
		if row.status == statStatusFailed {
			anyFailed = true
		}
	}
	if anyFailed {
		return errors.New("one or more paths failed")
	}
	return nil
}

func main() {
	if err := coreRootCommand().Execute(); err != nil {
		os.Exit(1)
	}
}
