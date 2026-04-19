#!/usr/bin/env -S shebangsy swift
#!requires: bdombro/swift-argsbarg@0.2.0:ArgsBarg

/*
  PDF compress — Swift port of nim-media-apps/pdf-compress.

  Ghostscript-based PDF compression with optional in-place replace (trash or delete),
  larger-than-source handling, and SIGINT-safe subprocess runs.

  Dependencies: Ghostscript (`gs`); with `--replace` and without `--skipTrash`, also `trash`.

  Default output: sibling `stem-c.pdf` next to each source (not in-place unless `--replace`).
  If the compressed file is larger than the source and `--replace` is off, the tool copies the
  original to the `-c` path instead.

  Exit codes: 0 success; 1 validation error, missing tools, no inputs, or any row failed;
  130 SIGINT / interrupted batch.
*/

import ArgsBarg
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Errors & status

/// Ghostscript failure or user cancel surfaced to the pipeline (distinct from Swift I/O errors).
enum CompressError: Error {
    /// User asked to stop; the batch can exit 130 after printing what completed so far.
    case interrupted
    case commandFailed(String)
}

/// Whether a PDF was compressed, skipped, or failed—drives the summary and final exit code.
enum PdfStatus: Equatable {
    case processed
    case skipped(String)
    case failed(String)
}

// MARK: - Interrupt flag

nonisolated(unsafe) private var interruptRequested: Int32 = 0

// MARK: - PDF domain

/// Ghostscript PDF recompression: presets, larger-than-source behavior, optional in-place replace.
enum Pdf {
    struct Options {
        var ci: Bool
        var quality: Int
        var replace: Bool
        var skipTrash: Bool
    }

    struct Row {
        var source: String
        var destination: String
        var bytesBefore: Int64
        var bytesAfter: Int64
        var secondsElapsed: TimeInterval
        var status: PdfStatus
        /// Optional suffix for successful rows (e.g. Ghostscript larger-than-source warnings).
        var note: String

        func printStatus() {
            switch status {
            case .processed:
                let mbBefore = Core.bytesMb(bytesBefore)
                let mbAfter = Core.bytesMb(bytesAfter)
                let saved = Core.bytesMb(bytesBefore - bytesAfter)
                let b = String(format: "%.2f", mbBefore)
                let a = String(format: "%.2f", mbAfter)
                let s = String(format: "%.2f", saved)
                let extra = note.isEmpty ? "" : " \(note)"
                print("ok \(source) -> \(destination) (\(b) MB -> \(a) MB, saved \(s) MB)\(extra)")
            case .skipped(let msg):
                print("skip \(source): \(msg)")
            case .failed(let msg):
                print("fail \(source): \(msg)")
            }
        }
    }

    static let qualityDefault = 2

    // MARK: - Recipes (Ghostscript)

    /// Ghostscript invocation shape lives here so PDFSETTINGS policy is obvious next to the CLI preset mapping.
    private enum Recipes {
        static func ghostscriptPdfwrite(
            destination: String, pdfSettings: String, source: String
        ) -> [String] {
            [
                "-sDEVICE=pdfwrite",
                "-dCompatibilityLevel=1.4",
                "-dPDFSETTINGS=\(pdfSettings)",
                "-dNOPAUSE",
                "-dQUIET",
                "-dBATCH",
                "-sOutputFile=\(destination)",
                source,
            ]
        }
    }

    static func baseFile(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        if ext.isEmpty { return name }
        return name + "." + ext
    }

    /// End-to-end batch: preflight tools, honor `--ci` vs interactive paths, stop on interrupt, fail if any row failed.
    static func compressRun(_ files: [String], opts: Options) {
        Core.interruptHandlerInstall()
        defer { Core.interruptHandlerRestore() }
        let err = Core.runtimeValidate(replace: opts.replace, skipTrash: opts.skipTrash)
        if !err.isEmpty {
            FileHandle.standardError.write(Data((err + "\n").utf8))
            exit(1)
        }
        if opts.quality < 1 || opts.quality > 3 {
            FileHandle.standardError.write(
                Data("quality must be 1, 2, or 3 (Ghostscript presets)\n".utf8))
            exit(1)
        }
        let resolved = Core.inputsResolve(
            files, ci: opts.ci,
            interactivePrompt:
                "Enter one or more PDF files, separated by spaces or commas: ")
        if resolved.isEmpty {
            FileHandle.standardError.write(Data("provide one or more PDF files\n".utf8))
            exit(1)
        }
        var results: [Row] = []
        for source in resolved {
            if Core.pendingInterrupt() {
                FileHandle.standardError.write(Data("\nInterrupted.\n".utf8))
                summaryPrint(results)
                exit(130)
            }
            let t0 = Date().timeIntervalSinceReferenceDate
            var row = fileProcess(source, opts: opts)
            row.secondsElapsed = Date().timeIntervalSinceReferenceDate - t0
            results.append(row)
            row.printStatus()
            if case .skipped("interrupted") = row.status {
                FileHandle.standardError.write(Data("\nInterrupted.\n".utf8))
                summaryPrint(results)
                exit(130)
            }
        }
        summaryPrint(results)
        if failuresPresent(results) {
            exit(1)
        }
    }

    static func extLower(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    static func failuresPresent(_ results: [Row]) -> Bool {
        results.contains { if case .failed = $0.status { return true }; return false }
    }

    static func fileSizeSafe(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Writes a `-c` sibling by default; if Ghostscript inflates the file, policy decides warn-only vs copy-original fallback.
    static func fileProcess(_ source: String, opts: Options) -> Row {
        var row = Row(
            source: source, destination: "", bytesBefore: 0, bytesAfter: 0, secondsElapsed: 0,
            status: .skipped(""), note: "")
        if !FileManager.default.fileExists(atPath: source) {
            row.status = .skipped("no such file")
            return row
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue {
            row.status = .skipped("path is a directory, not a file")
            return row
        }
        if extLower(source) != "pdf" {
            row.status = .skipped("unsupported extension: \(extLower(source))")
            return row
        }
        let destination = pathCompressed(source)
        row.destination = destination
        if FileManager.default.fileExists(atPath: destination) {
            row.status = .skipped("\(baseFile(destination)) already exists")
            return row
        }
        row.bytesBefore = fileSizeSafe(source)
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        if !parent.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    atPath: parent, withIntermediateDirectories: true)
            } catch {
                row.status = .failed(error.localizedDescription)
                return row
            }
        }
        do {
            try writeGsPipeline(source: source, destination: destination, quality: opts.quality)
        } catch CompressError.interrupted {
            row.status = .skipped("interrupted")
            return row
        } catch CompressError.commandFailed(let msg) {
            row.status = .failed(msg)
            return row
        } catch {
            row.status = .failed(error.localizedDescription)
            return row
        }
        if !FileManager.default.fileExists(atPath: destination) {
            row.status = .failed("Ghostscript did not write the destination file")
            return row
        }
        row.bytesAfter = fileSizeSafe(destination)
        row.status = .processed
        if largerOutputHandle(row: &row, opts: opts, source: source, destination: destination) {
            return row
        }
        replaceApply(row: &row, opts: opts, source: source, destination: destination)
        return row
    }

    /// Compression isn’t always smaller—we must not trash the original for a worse `--replace`, yet still leave a sane `-c` path when not replacing.
    /// Returns true when `row` is finished (warning path or copy-original path).
    static func largerOutputHandle(
        row: inout Row, opts: Options, source: String, destination: String
    ) -> Bool {
        if row.bytesAfter <= row.bytesBefore { return false }
        if opts.replace {
            row.note = "warning: compressed file is larger than source; skipping replace"
            return true
        }
        do {
            try FileManager.default.removeItem(atPath: destination)
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        } catch {
            row.status = .failed(error.localizedDescription)
            return true
        }
        row.bytesAfter = row.bytesBefore
        row.note = "warning: compressed file is larger than source; copied original to destination"
        return true
    }

    static func parseQualityPreset(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return qualityDefault }
        guard let v = Int(trimmed) else {
            FileHandle.standardError.write(Data("invalid quality: \(raw)\n".utf8))
            exit(1)
        }
        if v < 1 || v > 3 {
            FileHandle.standardError.write(
                Data("quality must be 1, 2, or 3 (Ghostscript presets)\n".utf8))
            exit(1)
        }
        return v
    }

    /// Default output beside the input so originals stay untouched until the user opts into `--replace`.
    static func pathCompressed(_ source: String) -> String {
        let url = URL(fileURLWithPath: source)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        let name = stem + "-c.pdf"
        return URL(fileURLWithPath: dir).appendingPathComponent(name).path
    }

    /// In-place swap: compressed PDF ends up at the original path after the original is trashed or deleted.
    static func replaceApply(
        row: inout Row, opts: Options, source: String, destination: String
    ) {
        guard opts.replace else { return }
        let srcExt = URL(fileURLWithPath: source).pathExtension.lowercased()
        let dstExt = URL(fileURLWithPath: destination).pathExtension.lowercased()
        guard srcExt == dstExt else {
            row.status = .skipped("skipping replace because extensions do not match")
            return
        }
        do {
            if opts.skipTrash {
                try FileManager.default.removeItem(atPath: source)
            } else {
                try Core.runExternal("trash", [source])
            }
            try FileManager.default.moveItem(atPath: destination, toPath: source)
            row.destination = source
        } catch CompressError.commandFailed(let msg) {
            row.status = .failed(msg)
        } catch {
            row.status = .failed(error.localizedDescription)
        }
    }

    /// User-facing 1…3 maps to Ghostscript’s screen/ebook/default quality tradeoffs.
    static func settingStr(_ quality: Int) -> String {
        switch quality {
        case 1: return "/screen"
        case 3: return "/default"
        default: return "/ebook"
        }
    }

    static func summaryPrint(_ results: [Row]) {
        var processed = 0
        var skipped = 0
        var failed = 0
        var bytesBeforeTotal: Int64 = 0
        var bytesAfterTotal: Int64 = 0
        for r in results {
            bytesBeforeTotal += r.bytesBefore
            bytesAfterTotal += r.bytesAfter
            switch r.status {
            case .processed: processed += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            }
        }
        print("")
        print("Summary")
        print("  Processed: \(processed)")
        print("  Skipped: \(skipped)")
        print("  Failed: \(failed)")
        print(String(format: "  Original MB: %.2f", Core.bytesMb(bytesBeforeTotal)))
        print(String(format: "  Compressed MB: %.2f", Core.bytesMb(bytesAfterTotal)))
        print(
            String(
                format: "  Saved MB: %.2f\n",
                Core.bytesMb(bytesBeforeTotal - bytesAfterTotal)))
    }

    /// Produces the compressed bytes and keeps the file’s timestamp aligned with the source for sorting and backups.
    static func writeGsPipeline(source: String, destination: String, quality: Int) throws {
        let settings = settingStr(quality)
        try Core.runExternal(
            "gs",
            Recipes.ghostscriptPdfwrite(
                destination: destination, pdfSettings: settings, source: source))
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: source)
            if let d = attrs[.modificationDate] as? Date {
                try FileManager.default.setAttributes(
                    [.modificationDate: d], ofItemAtPath: destination)
            }
        } catch {
            throw CompressError.commandFailed(error.localizedDescription)
        }
    }
}

// MARK: - Core utilities

/// Cross-cutting concerns duplicated in each shebang script because there is no shared Swift module here.
enum Core {
    static func bytesMb(_ size: Int64) -> Double {
        Double(size) / 1024.0 / 1024.0
    }

    static func commandAvailableOnPath(_ cmd: String) -> Bool {
        resolvedExecutable(cmd) != nil
    }

    /// Final path list: argv in automation, typed paths at the terminal, empty when unsafe to prompt.
    static func inputsResolve(_ args: [String], ci: Bool, interactivePrompt: String) -> [String] {
        if !args.isEmpty { return args }
        if ci || !ttyIs() { return [] }
        print(interactivePrompt, terminator: "")
        fflush(stdout)
        guard let line = readLine(strippingNewline: true) else {
            return []
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return trimmed.split { $0 == " " || $0 == "\t" || $0 == "," }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func installHint(_ cmd: String) -> String {
        #if os(macOS)
            switch cmd {
            case "gs", "ghostscript": return "brew install ghostscript"
            case "trash": return "brew install trash"
            default: return "brew install <name> or see upstream docs"
            }
        #elseif os(Linux)
            switch cmd {
            case "gs", "ghostscript":
                return "sudo apt install ghostscript  # or: sudo dnf install ghostscript"
            case "trash": return "sudo apt install trash-cli  # or: sudo dnf install trash-cli"
            default: return "install with your distro package manager"
            }
        #else
            return "install from your OS vendor or project homepages (Ghostscript, trash)"
        #endif
    }

    static func interruptHandlerInstall() {
        interruptRequested = 0
        _ = signal(SIGINT) { _ in
            interruptRequested = 1
        }
    }

    static func interruptHandlerRestore() {
        _ = signal(SIGINT, SIG_DFL)
    }

    static func pendingInterrupt() -> Bool {
        interruptRequested != 0
    }

    static func resolvedExecutable(_ cmd: String) -> String? {
        if cmd.contains("/") {
            return FileManager.default.isExecutableFile(atPath: cmd) ? cmd : nil
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let full = URL(fileURLWithPath: String(dir)).appendingPathComponent(cmd).path
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// Runs Ghostscript or `trash`; user cancel becomes `CompressError.interrupted` with a defined batch outcome.
    static func runExternal(_ cmd: String, _ args: [String]) throws {
        let resolved = resolvedExecutable(cmd) ?? cmd
        var shLine = "trap '' INT; exec " + shellQuote(resolved)
        for a in args {
            shLine += " " + shellQuote(a)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", shLine]
        p.standardInput = FileHandle.standardInput
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        do {
            try p.run()
        } catch {
            throw CompressError.commandFailed("\(cmd): \(error.localizedDescription)")
        }
        while p.isRunning {
            if pendingInterrupt() {
                p.terminate()
                p.waitUntilExit()
                throw CompressError.interrupted
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        let code = p.terminationStatus
        if code != 0 {
            throw CompressError.commandFailed("\(cmd) failed (exit \(code))")
        }
    }

    /// Preflight: missing `gs` / `trash` should surface install hints before any PDF is touched.
    static func runtimeValidate(replace: Bool, skipTrash: Bool) -> String {
        var parts: [String] = []
        if !commandAvailableOnPath("gs") {
            parts.append("missing required commands: gs")
            parts.append("Install hints:")
            parts.append("  gs:  \(installHint("gs"))")
        }
        if replace && !skipTrash && !commandAvailableOnPath("trash") {
            parts.append("trash command is required for --replace unless --skipTrash is set")
            parts.append("  trash:  \(installHint("trash"))")
        }
        return parts.joined(separator: "\n")
    }

    static func ttyIs() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - CLI

func compressHandle(_ ctx: CliContext) {
    let quality = Pdf.parseQualityPreset(ctx.stringOpt("quality") ?? "")
    let opts = Pdf.Options(
        ci: ctx.flag("ci"),
        quality: quality,
        replace: ctx.flag("replace"),
        skipTrash: ctx.flag("skipTrash")
    )
    Pdf.compressRun(ctx.args, opts: opts)
}

cliRun(
    CliCommand(
        name: "pdf-compress",
        description: "CLI tool for compressing PDF files with Ghostscript.",
        children: [
            CliCommand(
                name: "compress",
                description:
                    "Compress PDFs with Ghostscript (writes *-c.pdf* sibling unless --replace).",
                options: [
                    CliOption(
                        name: "ci", description: "CI mode: exit instead of prompting.",
                        kind: .presence),
                    CliOption(
                        name: "replace",
                        description: "Move compressed output onto original path.",
                        kind: .presence, shortName: "r"),
                    CliOption(
                        name: "skipTrash",
                        description: "With --replace: remove original without trash.",
                        kind: .presence),
                    CliOption(
                        name: "quality",
                        description:
                            "Ghostscript preset: 1 screen, 2 ebook (default), 3 default.",
                        kind: .string, shortName: "q"),
                ],
                positionals: [
                    CliOption(
                        name: "files", description: "Input PDF paths.",
                        kind: .string, positional: true, argMin: 0, argMax: 0),
                ],
                handler: compressHandle
            ),
        ],
        fallbackCommand: "compress",
        fallbackMode: .missingOrUnknown
    ))
