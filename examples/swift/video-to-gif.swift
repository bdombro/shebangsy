#!/usr/bin/env -S shebangsy swift
#!requires: bdombro/swift-argsbarg@0.2.0:ArgsBarg

/*
  Video to GIF — Swift port of nim-media-apps/video-to-gif.

  ffmpeg palette-optimized GIF conversion with optional replace (trash/delete source video).

  Dependencies: ffmpeg; with `--replace` and without `--skipTrash`, also `trash`.

  Default output: sibling `stem.gif` next to each source (source is not renamed unless `--replace`).

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

/// Whether a conversion succeeded, was skipped, or failed—drives the summary and final exit code.
enum GifStatus: Equatable {
    case processed
    case skipped(String)
    case failed(String)
}

nonisolated(unsafe) private var interruptRequested: Int32 = 0

// MARK: - GIF domain

/// Video → palette GIF: defaults, per-file results, and batch entry (`compress` mirrors `convert`).
enum Gif {
    struct Options {
        var ci: Bool
        var colors: Int
        var fps: Int
        var replace: Bool
        var skipTrash: Bool
        var widthMax: Int
    }

    struct Row {
        var source: String
        var destination: String
        var bytesBefore: Int64
        var bytesAfter: Int64
        var secondsElapsed: TimeInterval
        var status: GifStatus

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

    static let colorsDefault = 64
    static let fpsDefault = 4
    static let widthDefault = 800

    // MARK: - Recipes (ffmpeg)

    /// GIF is index-color; a generated palette beats naive color reduction for banding and file size.
    private enum Recipes {
        /// Caps resolution and frame rate first—palette quality depends on what actually enters `palettegen`.
        static func filterPaletteGif(fps: Int, widthMax: Int, colors: Int) -> String {
            "fps=\(fps),scale='min(iw,\(widthMax))':-2:flags=lanczos," +
                "crop=iw-mod(iw\\,2):ih-mod(ih\\,2),split[s0][s1];" +
                "[s0]palettegen=max_colors=\(colors):stats_mode=diff[p];" +
                "[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        }

        static func ffmpegGifArgs(source: String, destination: String, videoFilter: String) -> [String] {
            [
                "-nostdin",
                "-v", "error",
                "-hide_banner",
                "-loglevel", "quiet",
                "-i", source,
                "-vf", videoFilter,
                "-f", "gif",
                "-loop", "0",
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
    static func convertRun(_ files: [String], opts: Options) {
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

    /// Delivers a sidecar GIF; `--replace` means “discard the source clip after success,” not “rename GIF over the video.”
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
        if extLower(source) == "gif" {
            row.status = .skipped("source is already a GIF")
            return row
        }
        let destination = pathOutput(source)
        row.destination = destination
        if normalizedPath(source) == normalizedPath(destination) {
            row.status = .skipped("source and destination are the same path")
            return row
        }
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
        replaceApply(row: &row, opts: opts, source: source)
        return row
    }

    /// Same logical path should compare equal after shell-style normalization—avoids accidental overwrite surprises.
    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func parseColors(_ raw: String) -> Int {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return colorsDefault }
        guard let v = Int(t) else {
            FileHandle.standardError.write(Data("invalid colors: \(raw)\n".utf8))
            exit(1)
        }
        if v < 2 || v > 256 {
            FileHandle.standardError.write(Data("--colors must be between 2 and 256\n".utf8))
            exit(1)
        }
        return v
    }

    static func parseFps(_ raw: String) -> Int {
        let v = parseDim(raw: raw, name: "fps", dflt: fpsDefault)
        if v < 1 {
            FileHandle.standardError.write(Data("--fps must be at least 1\n".utf8))
            exit(1)
        }
        return v
    }

    static func parseDim(raw: String, name: String, dflt: Int) -> Int {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return dflt }
        guard let v = Int(t) else {
            FileHandle.standardError.write(Data("invalid \(name): \(raw)\n".utf8))
            exit(1)
        }
        return v
    }

    static func parseWidth(_ raw: String) -> Int {
        let v = parseDim(raw: raw, name: "maxWidth", dflt: widthDefault)
        if v < 1 {
            FileHandle.standardError.write(Data("--maxWidth must be at least 1\n".utf8))
            exit(1)
        }
        return v
    }

    /// Predictable sibling naming: one GIF per stem, next to the source clip.
    static func pathOutput(_ source: String) -> String {
        let url = URL(fileURLWithPath: source)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        return URL(fileURLWithPath: dir).appendingPathComponent(stem + ".gif").path
    }

    /// Optional cleanup of the heavy source once the GIF exists—keeps disk usage down without changing output location.
    static func replaceApply(row: inout Row, opts: Options, source: String) {
        guard opts.replace else { return }
        if opts.skipTrash {
            do {
                try FileManager.default.removeItem(atPath: source)
            } catch {
                row.status = .failed(error.localizedDescription)
            }
            return
        }
        do {
            try Core.runExternal("trash", [source])
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
        print(String(format: "  GIF MB: %.2f", Core.bytesMb(bytesAfterTotal)))
        print(
            String(
                format: "  Saved MB: %.2f\n",
                Core.bytesMb(bytesBeforeTotal - bytesAfterTotal)))
    }

    /// GIFs don’t inherit rich video metadata; matching mtime at least preserves sort order in typical folder views.
    static func timestampApply(source: String, destination: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: source)
        if let d = attrs[.modificationDate] as? Date {
            try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: destination)
        }
    }

    static func writePipeline(source: String, destination: String, opts: Options) throws {
        let vf = Recipes.filterPaletteGif(
            fps: opts.fps, widthMax: opts.widthMax, colors: opts.colors)
        try Core.runExternal(
            "ffmpeg", Recipes.ffmpegGifArgs(source: source, destination: destination, videoFilter: vf))
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

    /// Preflight: missing ffmpeg (or `trash` when replacing) should fail before spawning long encodes.
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

func convertHandle(_ ctx: CliContext) {
    let opts = Gif.Options(
        ci: ctx.flag("ci"),
        colors: Gif.parseColors(ctx.stringOpt("colors") ?? ""),
        fps: Gif.parseFps(ctx.stringOpt("fps") ?? ""),
        replace: ctx.flag("replace"),
        skipTrash: ctx.flag("skipTrash"),
        widthMax: Gif.parseWidth(ctx.stringOpt("maxWidth") ?? "")
    )
    Gif.convertRun(ctx.args, opts: opts)
}

cliRun(
    CliCommand(
        name: "video-to-gif",
        description:
            "CLI tool for converting video files to palette-optimized GIFs with ffmpeg.",
        children: [
            CliCommand(
                name: "compress",
                description: "Same behavior as convert (alternate name).",
                options: [
                    CliOption(
                        name: "ci", description: "CI mode: exit instead of prompting.",
                        kind: .presence),
                    CliOption(
                        name: "colors", description: "Palette size for palettegen (2–256).",
                        kind: .string),
                    CliOption(name: "fps", description: "Frames per second for the GIF.", kind: .string),
                    CliOption(
                        name: "maxWidth", description: "Max width in pixels (shrink-only).",
                        kind: .string),
                    CliOption(
                        name: "replace",
                        description:
                            "After success: remove the source video (trash or delete, not rename).",
                        kind: .presence),
                    CliOption(
                        name: "skipTrash",
                        description: "With --replace: remove original without trash.",
                        kind: .presence),
                ],
                positionals: [
                    CliOption(
                        name: "files", description: "Input video paths.",
                        kind: .string, positional: true, argMin: 0, argMax: 0),
                ],
                handler: convertHandle
            ),
            CliCommand(
                name: "convert",
                description:
                    "Convert video to palette-optimized GIF (writes stem.gif next to each source).",
                options: [
                    CliOption(
                        name: "ci", description: "CI mode: exit instead of prompting.",
                        kind: .presence),
                    CliOption(
                        name: "colors", description: "Palette size for palettegen (2–256).",
                        kind: .string),
                    CliOption(name: "fps", description: "Frames per second for the GIF.", kind: .string),
                    CliOption(
                        name: "maxWidth", description: "Max width in pixels (shrink-only).",
                        kind: .string),
                    CliOption(
                        name: "replace",
                        description:
                            "After success: remove the source video (trash or delete, not rename).",
                        kind: .presence),
                    CliOption(
                        name: "skipTrash",
                        description: "With --replace: remove original without trash.",
                        kind: .presence),
                ],
                positionals: [
                    CliOption(
                        name: "files", description: "Input video paths.",
                        kind: .string, positional: true, argMin: 0, argMax: 0),
                ],
                handler: convertHandle
            ),
        ],
        fallbackCommand: "convert",
        fallbackMode: .missingOrUnknown
    ))
