#!/usr/bin/env -S shebangsy swift
#!requires: bdombro/swift-argsbarg@0.2.0:ArgsBarg

/*
  Image compress / resize — Swift port of nim-media-apps/image-compress-resize.

  Shrink-only resize and compression for PNG/JPEG via magick, pngquant, and exiftool,
  with optional in-place replace (trash or delete). Uses ArgsBarg for the CLI and
  namespace enums for grouping helpers.

  Dependencies: ImageMagick (`magick`), pngquant, ExifTool (`exiftool`); with
  `--replace` and without `--skipTrash`, also `trash`.

  Default output: sibling `stem-c.png` or `stem-c.jpg` next to each source (not
  in-place unless `--replace`).

  Exit codes: 0 success; 1 validation error, missing tools, no inputs, or any row
  failed; 130 SIGINT / interrupted batch.
*/

import ArgsBarg
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Errors & status

/// External tool failure or user cancel surfaced to the pipeline (distinct from Swift I/O errors).
enum CompressError: Error {
    /// User asked to stop; the batch can exit 130 after printing what completed so far.
    case interrupted
    case commandFailed(String)
}

/// Whether a file was transformed, intentionally skipped, or failed—drives the summary and final exit code.
enum ImageStatus: Equatable {
    case processed
    case skipped(String)
    case failed(String)
}

// MARK: - Interrupt flag (signal handler writes; polling loop reads)

nonisolated(unsafe) private var interruptRequested: Int32 = 0

// MARK: - Image domain

/// Shrink-only PNG/JPEG compression and resize: defaults, per-file results, and the batch entrypoint.
enum Image {
    struct Options {
        var ci: Bool
        var heightMax: Int
        var quality: Int
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
        var status: ImageStatus

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

    static let heightDefault = 1080
    static let pngQualityHalfBand = 8
    static let qualityDefault = 80
    static let widthDefault = 1920

    // MARK: - Recipes (external commands)

    /// Keeps tool-specific flags in one place so quality and metadata policy are easy to audit.
    private enum Recipes {
        static func exiftoolCopyMetadata(source: String, destination: String) -> [String] {
            ["-overwrite_original", "-TagsFromFile", source, "-all:all", destination]
        }

        static func magickJpegWrite(
            source: String, destination: String, resizeGeometry: String, quality: Int
        ) -> [String] {
            [source, "-resize", resizeGeometry, "-quality", "\(quality)", destination]
        }

        static func magickPngResizeTemp(source: String, tempPath: String, resizeGeometry: String)
            -> [String]
        {
            [source, "-resize", resizeGeometry, tempPath]
        }

        static func pngquantWrite(
            qualityRange: String, destination: String, tempPath: String
        ) -> [String] {
            ["--quality", qualityRange, "--output", destination, "--force", tempPath]
        }
    }

    static func baseFile(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        if ext.isEmpty { return name }
        return name + "." + ext
    }

    /// End-to-end batch: fail fast if tools are missing, honor `--ci` vs interactive path entry,
    /// stop cleanly on interrupt, and exit non-zero if any file failed.
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
                "Enter one or more image files, separated by spaces or commas: ")
        if resolved.isEmpty {
            FileHandle.standardError.write(Data("provide one or more image files\n".utf8))
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
        let e = URL(fileURLWithPath: path).pathExtension
        return e.lowercased()
    }

    static func failuresPresent(_ results: [Row]) -> Bool {
        results.contains { if case .failed = $0.status { return true }; return false }
    }

    static func fileSizeSafe(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Produces a `*-c*` sibling (or in-place swap with `--replace`) while preserving tags and mod time.
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
        let ext = extLower(source)
        guard ["png", "jpg", "jpeg"].contains(ext) else {
            row.status = .skipped("unsupported extension: \(ext)")
            return row
        }
        let pathExtensionSuffixOut = ext == "png" ? ".png" : ".jpg"
        let destination = pathCompressed(source, pathExtensionSuffixOut: pathExtensionSuffixOut)
        row.destination = destination
        if FileManager.default.fileExists(atPath: destination) {
            row.status = .skipped("\(baseFile(destination)) already exists")
            return row
        }
        let bytesBefore = fileSizeSafe(source)
        row.bytesBefore = bytesBefore
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
        var tempPath: String?
        defer {
            if let t = tempPath {
                try? FileManager.default.removeItem(atPath: t)
            }
        }
        do {
            if ext == "png" {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("image-compress-\(UUID().uuidString).png")
                tempPath = tmp.path
                try writePngPipeline(
                    source: source, destination: destination, tempPath: tmp.path,
                    widthMax: opts.widthMax, heightMax: opts.heightMax, quality: opts.quality)
                if !FileManager.default.fileExists(atPath: destination) {
                    row.status = .failed("pngquant did not write the destination file")
                    return row
                }
            } else {
                try writeJpegPipeline(
                    source: source, destination: destination,
                    widthMax: opts.widthMax, heightMax: opts.heightMax, quality: opts.quality)
            }
            try metadataApply(source: source, destination: destination)
            let bytesAfter = fileSizeSafe(destination)
            row.bytesAfter = bytesAfter
            row.status = .processed
            replaceApply(row: &row, opts: opts, source: source, destination: destination)
        } catch CompressError.interrupted {
            row.status = .skipped("interrupted")
        } catch CompressError.commandFailed(let msg) {
            row.status = .failed(msg)
        } catch {
            row.status = .failed(error.localizedDescription)
        }
        return row
    }

    /// Keeps EXIF/IPTC (etc.) and Finder-style dates aligned with the original so workflows don’t break.
    static func metadataApply(source: String, destination: String) throws {
        try Core.runExternal(
            "exiftool", Recipes.exiftoolCopyMetadata(source: source, destination: destination))
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

    static func parsePositiveInt(
        name: String, raw: String, minVal: Int, maxVal: Int, dflt: Int
    ) -> Int {
        if raw.isEmpty { return dflt }
        guard let v = Int(raw) else {
            FileHandle.standardError.write(Data("invalid \(name): \(raw)\n".utf8))
            exit(1)
        }
        if v < minVal || v > maxVal {
            let msg =
                "\(name) must be between \(minVal) and \(maxVal) (got \(raw))\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(1)
        }
        return v
    }

    /// Default naming: `stem-c.png` / `stem-c.jpg` next to the input (safe until user opts into `--replace`).
    static func pathCompressed(_ source: String, pathExtensionSuffixOut: String) -> String {
        let url = URL(fileURLWithPath: source)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        let name = stem + "-c" + pathExtensionSuffixOut
        return URL(fileURLWithPath: dir).appendingPathComponent(name).path
    }

    /// pngquant expects a band, not a single number; narrowing around the user’s quality keeps PNG tuning predictable.
    static func pngQualityRangeStr(_ center: Int) -> String {
        let lo = max(0, center - pngQualityHalfBand)
        let hi = min(100, center + pngQualityHalfBand)
        return "\(lo)-\(hi)"
    }

    /// In-place swap: compressed bytes end up at the original path. Extensions must match so we never mislabel format.
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

    /// Policy is shrink-only—never upscale pixels or invent detail the user didn’t ask for.
    static func resizeGeometry(widthMax: Int, heightMax: Int) -> String {
        "\(widthMax)x\(heightMax)>"
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

    static func writeJpegPipeline(
        source: String, destination: String, widthMax: Int, heightMax: Int, quality: Int
    ) throws {
        let geom = resizeGeometry(widthMax: widthMax, heightMax: heightMax)
        try Core.runExternal(
            "magick",
            Recipes.magickJpegWrite(
                source: source, destination: destination, resizeGeometry: geom, quality: quality))
    }

    static func writePngPipeline(
        source: String, destination: String, tempPath: String, widthMax: Int, heightMax: Int,
        quality: Int
    ) throws {
        let geom = resizeGeometry(widthMax: widthMax, heightMax: heightMax)
        try Core.runExternal(
            "magick", Recipes.magickPngResizeTemp(source: source, tempPath: tempPath, resizeGeometry: geom))
        try Core.runExternal(
            "pngquant",
            Recipes.pngquantWrite(
                qualityRange: pngQualityRangeStr(quality), destination: destination,
                tempPath: tempPath))
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

    /// Final path list for the batch: argv in automation, typed paths at the terminal, empty when unsafe to prompt.
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
            case "magick": return "brew install imagemagick"
            case "pngquant": return "brew install pngquant"
            case "exiftool": return "brew install exiftool"
            case "trash": return "brew install trash"
            default: return "brew install <name> or see upstream docs"
            }
        #elseif os(Linux)
            switch cmd {
            case "magick": return "sudo apt install imagemagick  # or: sudo dnf install ImageMagick"
            case "pngquant": return "sudo apt install pngquant  # or: sudo dnf install pngquant"
            case "exiftool":
                return
                    "sudo apt install libimage-exiftool-perl  # or: sudo dnf install perl-Image-ExifTool"
            case "trash": return "sudo apt install trash-cli  # or: sudo dnf install trash-cli"
            default: return "install with your distro package manager"
            }
        #else
            return
                "install from your OS vendor or project homepages (ImageMagick, pngquant, ExifTool, trash)"
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

    /// Invokes a dependency (magick, pngquant, …); user cancel becomes `CompressError.interrupted` instead of a wedged run.
    static func runExternal(_ cmd: String, _ args: [String]) throws {
        let resolved = resolvedExecutable(cmd) ?? cmd
        var shLine = "trap '' INT; exec " + shellQuote(resolved)
        for a in args {
            shLine += " " + shellQuote(a)
        }
        let script = shLine
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
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

    /// Preflight: missing tools and impossible `--replace` combos should error before touching files.
    static func runtimeValidate(replace: Bool, skipTrash: Bool) -> String {
        var parts: [String] = []
        let required = ["magick", "pngquant", "exiftool"]
        let missing = required.filter { !commandAvailableOnPath($0) }
        if !missing.isEmpty {
            parts.append("missing required commands: \(missing.joined(separator: ", "))")
            parts.append("Install hints:")
            for m in missing {
                parts.append("  \(m):  \(installHint(m))")
            }
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
    let widthMax = Image.parsePositiveInt(
        name: "widthMax",
        raw: ctx.stringOpt("widthMax") ?? "",
        minVal: 1,
        maxVal: 1_000_000,
        dflt: Image.widthDefault
    )
    let heightMax = Image.parsePositiveInt(
        name: "heightMax",
        raw: ctx.stringOpt("heightMax") ?? "",
        minVal: 1,
        maxVal: 1_000_000,
        dflt: Image.heightDefault
    )
    let quality = Image.parsePositiveInt(
        name: "quality",
        raw: ctx.stringOpt("quality") ?? "",
        minVal: 1,
        maxVal: 100,
        dflt: Image.qualityDefault
    )
    let opts = Image.Options(
        ci: ctx.flag("ci"),
        heightMax: heightMax,
        quality: quality,
        replace: ctx.flag("replace"),
        skipTrash: ctx.flag("skipTrash"),
        widthMax: widthMax
    )
    Image.compressRun(ctx.args, opts: opts)
}

cliRun(
    CliCommand(
        name: "image-compress-resize",
        description: "CLI tool for compressing and resizing image files (JPEG and PNG).",
        children: [
            CliCommand(
                name: "compress",
                description:
                    "Compress and resize PNG/JPEG images (writes *-c* sibling unless --replace).",
                options: [
                    CliOption(
                        name: "ci", description: "CI mode: exit instead of prompting.",
                        kind: .presence),
                    CliOption(
                        name: "heightMax", description: "Max height in pixels (shrink-only).",
                        kind: .string, shortName: "H"),
                    CliOption(
                        name: "quality",
                        description: "JPEG: magick -quality. PNG: pngquant band center.",
                        kind: .string, shortName: "q"),
                    CliOption(
                        name: "replace",
                        description: "Move compressed output onto original path.",
                        kind: .presence, shortName: "r"),
                    CliOption(
                        name: "skipTrash",
                        description: "With --replace: remove original without trash.",
                        kind: .presence),
                    CliOption(
                        name: "widthMax", description: "Max width in pixels (shrink-only).",
                        kind: .string, shortName: "w"),
                ],
                positionals: [
                    CliOption(
                        name: "files", description: "Input PNG/JPEG paths.",
                        kind: .string, positional: true, argMin: 0, argMax: 0),
                ],
                handler: compressHandle
            ),
        ],
        fallbackCommand: "compress",
        fallbackMode: .missingOrUnknown
    ))
