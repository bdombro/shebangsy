#!/usr/bin/env -S shebangsy swift
#!requires: bdombro/swift-argsbarg@0.2.0:ArgsBarg

/*
  Video compress — Swift port of nim-media-apps/video-compress.

  ffmpeg libx265 HEVC compression with shrink-only scaling, optional in-place replace.

  Dependencies: ffmpeg (libx265); with `--replace` and without `--skipTrash`, also `trash`.

  Default output: sibling `stem-c.mp4` next to each source. `--replace` only applies when the
  source extension matches the output (typically `.mp4`).

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

/// ffmpeg failure or user cancel surfaced to the pipeline (distinct from Swift I/O errors).
enum CompressError: Error {
    /// User asked to stop; the batch can exit 130 after printing what completed so far.
    case interrupted
    case commandFailed(String)
}

/// Whether a transcode succeeded, was skipped, or failed—drives the summary and final exit code.
enum VideoStatus: Equatable {
    case processed
    case skipped(String)
    case failed(String)
}

nonisolated(unsafe) private var interruptRequested: Int32 = 0

// MARK: - Video domain

/// HEVC re-encode with shrink-only geometry, Apple-friendly tagging, optional in-place replace for `.mp4`.
enum Video {
    struct Options {
        var ci: Bool
        var crf: Int
        var heightMax: Int
        var replace: Bool
        var skipTrash: Bool
        var speed: String
        var widthMax: Int
    }

    struct Row {
        var source: String
        var destination: String
        var bytesBefore: Int64
        var bytesAfter: Int64
        var secondsElapsed: TimeInterval
        var status: VideoStatus

        func printStatus() {
            switch status {
            case .processed:
                let mbBefore = Core.bytesMb(bytesBefore)
                let mbAfter = Core.bytesMb(bytesAfter)
                let saved = Core.bytesMb(bytesBefore - bytesAfter)
                let b = String(format: "%.2f", mbBefore)
                let a = String(format: "%.2f", mbAfter)
                let s = String(format: "%.2f", saved)
                print("ok \(source) -> \(destination) (\(b) MB -> \(a) MB, saved \(s) MB)")
            case .skipped(let msg):
                print("skip \(source): \(msg)")
            case .failed(let msg):
                print("fail \(source): \(msg)")
            }
        }
    }

    static let crfDefault = 28
    static let heightDefault = 1080
    static let outputCodecTag = "hvc1"
    static let speedDefault = "ultrafast"
    static let widthDefault = 1920

    // MARK: - Recipes (ffmpeg / libx265)

    /// Keeps quality/size policy and the corresponding ffmpeg knobs in one place for review and parity with Nim.
    private enum Recipes {
        /// Never upscale—only reduce pixels when the cap is below the source, matching the Nim tool’s contract.
        static func vfScaleCropEven(widthMax: Int, heightMax: Int) -> String {
            "scale=\(widthMax):\(heightMax):force_original_aspect_ratio=decrease," +
                "crop=iw-mod(iw\\,2):ih-mod(ih\\,2)"
        }

        /// HEVC in MP4 with a tag QuickTime recognizes; metadata carryover keeps dates/orientation useful in Finder.
        static func ffmpegHevcArgs(
            source: String, destination: String, videoFilter: String, preset: String, crf: Int,
            codecTag: String
        ) -> [String] {
            [
                "-v", "error",
                "-i", source,
                "-loglevel", "quiet",
                "-x265-params", "log-level=quiet",
                "-vf", videoFilter,
                "-preset", preset,
                "-c:v", "libx265",
                "-tag:v", codecTag,
                "-crf", String(crf),
                "-map_metadata", "0",
                "-movflags", "+faststart",
                destination,
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
        let resolved = Core.inputsResolve(
            files, ci: opts.ci,
            interactivePrompt:
                "Enter one or more video files, separated by spaces or commas: ")
        if resolved.isEmpty {
            FileHandle.standardError.write(Data("provide one or more video files\n".utf8))
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

    /// Avoids wasting time and stacking generations when the input is already a `*-c.mp4` from this workflow.
    static func compressedSuffixPresent(_ path: String) -> Bool {
        guard extLower(path) == "mp4" else { return false }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return stem.hasSuffix("-c")
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

    /// Smaller HEVC alongside the original by default; optional replace for same-extension swaps; no junk files on failure.
    static func fileProcess(_ source: String, opts: Options) -> Row {
        var row = Row(
            source: source, destination: "", bytesBefore: 0, bytesAfter: 0, secondsElapsed: 0,
            status: .skipped(""))
        if !FileManager.default.fileExists(atPath: source) {
            row.status = .skipped("no such file")
            return row
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue {
            row.status = .skipped("path is a directory, not a file")
            return row
        }
        if compressedSuffixPresent(source) {
            row.status = .skipped("already compressed (filename ends with -c.mp4)")
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
            try writePipeline(source: source, destination: destination, opts: opts)
        } catch CompressError.interrupted {
            row.status = .skipped("interrupted")
            return row
        } catch CompressError.commandFailed(let msg) {
            row.status = .failed(msg)
            if FileManager.default.fileExists(atPath: destination) {
                try? FileManager.default.removeItem(atPath: destination)
            }
            return row
        } catch {
            row.status = .failed(error.localizedDescription)
            if FileManager.default.fileExists(atPath: destination) {
                try? FileManager.default.removeItem(atPath: destination)
            }
            return row
        }
        if !FileManager.default.fileExists(atPath: destination) {
            row.status = .failed("ffmpeg did not write the destination file")
            return row
        }
        do {
            try timestampApply(source: source, destination: destination)
        } catch {
            row.status = .failed(error.localizedDescription)
            return row
        }
        row.bytesAfter = fileSizeSafe(destination)
        row.status = .processed
        replaceApply(row: &row, opts: opts, source: source, destination: destination)
        return row
    }

    static func parseCrf(_ raw: String) -> Int {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return crfDefault }
        guard let v = Int(t) else {
            FileHandle.standardError.write(Data("invalid crf: \(raw)\n".utf8))
            exit(1)
        }
        return v
    }

    static func parseDim(name: String, raw: String, dflt: Int) -> Int {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return dflt }
        guard let v = Int(t) else {
            FileHandle.standardError.write(Data("invalid \(name): \(raw)\n".utf8))
            exit(1)
        }
        if v < 1 {
            FileHandle.standardError.write(Data("\(name) must be at least 1\n".utf8))
            exit(1)
        }
        return v
    }

    /// Default naming keeps the original playable until the user explicitly replaces it.
    static func pathCompressed(_ source: String) -> String {
        let url = URL(fileURLWithPath: source)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        return URL(fileURLWithPath: dir).appendingPathComponent(stem + "-c.mp4").path
    }

    /// In-place swap only when extensions already match—typical use is `.mp4` → smaller `.mp4` at the same path.
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

    /// Preserves “when was this clip touched” semantics for sorting and incremental backup tools.
    static func timestampApply(source: String, destination: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: source)
        if let d = attrs[.modificationDate] as? Date {
            try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: destination)
        }
    }

    /// One encode step: geometry policy, quality/speed tradeoff (CRF + preset), streaming-friendly MP4 layout.
    static func writePipeline(source: String, destination: String, opts: Options) throws {
        let vf = Recipes.vfScaleCropEven(widthMax: opts.widthMax, heightMax: opts.heightMax)
        try Core.runExternal(
            "ffmpeg",
            Recipes.ffmpegHevcArgs(
                source: source, destination: destination, videoFilter: vf, preset: opts.speed,
                crf: opts.crf, codecTag: outputCodecTag))
    }
}

// MARK: - Core

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
            case "ffmpeg": return "brew install ffmpeg"
            case "trash": return "brew install trash"
            default: return "brew install <name> or see upstream docs"
            }
        #elseif os(Linux)
            switch cmd {
            case "ffmpeg": return "sudo apt install ffmpeg  # or: sudo dnf install ffmpeg"
            case "trash": return "sudo apt install trash-cli  # or: sudo dnf install trash-cli"
            default: return "install with your distro package manager"
            }
        #else
            return "install from your OS vendor or project homepages (ffmpeg, trash)"
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

    /// Invokes ffmpeg or `trash`; user cancel becomes `CompressError.interrupted` with a defined batch outcome.
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

    /// Preflight: missing ffmpeg (or `trash` when replacing) should fail before long transcodes start.
    static func runtimeValidate(replace: Bool, skipTrash: Bool) -> String {
        var parts: [String] = []
        if !commandAvailableOnPath("ffmpeg") {
            parts.append("missing required commands: ffmpeg")
            parts.append("Install hints:")
            parts.append("  ffmpeg:  \(installHint("ffmpeg"))")
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
    let w = Video.parseDim(
        name: "maxWidth", raw: ctx.stringOpt("maxWidth") ?? "", dflt: Video.widthDefault)
    let h = Video.parseDim(
        name: "maxHeight", raw: ctx.stringOpt("maxHeight") ?? "", dflt: Video.heightDefault)
    let crf = Video.parseCrf(ctx.stringOpt("crf") ?? "")
    let speedRaw = (ctx.stringOpt("speed") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let speed = speedRaw.isEmpty ? Video.speedDefault : speedRaw
    let opts = Video.Options(
        ci: ctx.flag("ci"),
        crf: crf,
        heightMax: h,
        replace: ctx.flag("replace"),
        skipTrash: ctx.flag("skipTrash"),
        speed: speed,
        widthMax: w
    )
    Video.compressRun(ctx.args, opts: opts)
}

cliRun(
    CliCommand(
        name: "video-compress",
        description:
            "CLI tool for compressing video files with ffmpeg and shrink-only resizing.",
        children: [
            CliCommand(
                name: "compress",
                description:
                    "Compress video with libx265 (writes *-c.mp4* sibling unless --replace).",
                options: [
                    CliOption(
                        name: "ci", description: "CI mode: exit instead of prompting.",
                        kind: .presence),
                    CliOption(
                        name: "crf",
                        description: "libx265 constant rate factor (lower is higher quality).",
                        kind: .string),
                    CliOption(
                        name: "maxHeight", description: "Max height in pixels (shrink-only).",
                        kind: .string),
                    CliOption(
                        name: "maxWidth", description: "Max width in pixels (shrink-only).",
                        kind: .string),
                    CliOption(
                        name: "replace",
                        description:
                            "Move compressed output onto the original path when the source is already .mp4.",
                        kind: .presence),
                    CliOption(
                        name: "skipTrash",
                        description: "With --replace: remove original without trash.",
                        kind: .presence),
                    CliOption(
                        name: "speed",
                        description: "ffmpeg -preset name (e.g. ultrafast, medium).",
                        kind: .string),
                ],
                positionals: [
                    CliOption(
                        name: "files", description: "Input video paths.",
                        kind: .string, positional: true, argMin: 0, argMax: 0),
                ],
                handler: compressHandle
            ),
        ],
        fallbackCommand: "compress",
        fallbackMode: .missingOrUnknown
    ))
