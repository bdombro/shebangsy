#!/usr/bin/env -S shebangsy swift
#!requires: apple/swift-argument-parser@1.3.0

import ArgumentParser
import Foundation

@main
struct FileCLI: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "file-cli",
        abstract: "Demo: file operations, positional args, and options (defaults + required).",
        subcommands: [Copy.self, Info.self, List.self, Read.self, Remove.self, Write.self]
    )
}

// MARK: - list (positional with default, optional with default)

struct List: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List file names in a directory."
    )

    /// Shown in help as optional when omitted: directory defaults to the current path.
    @Argument(help: "Directory to list; defaults to the working directory if omitted")
    var directory: String = "."

    @Option(
        name: .long,
        help: "Maximum number of names to print (0 means unlimited)"
    )
    var max: Int = 20

    mutating func run() throws {
        let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(
            atPath: url.path
        ) else {
            throw CleanExit.message("Cannot read directory: \(url.path)")
        }
        var sorted = names.sorted()
        if max > 0 {
            sorted = Array(sorted.prefix(max))
        }
        for name in sorted {
            print(name)
        }
    }
}

// MARK: - read (one positional, optional with default, optional with default)

struct Read: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Print file contents to stdout."
    )

    @Argument(help: "File path to read")
    var path: String

    @Option(
        name: .long,
        help: "Maximum number of lines to print; 0 = entire file"
    )
    var maxLines: Int = 0

    @Option(help: "String printed before every line; empty by default")
    var prefix: String = ""

    mutating func run() throws {
        let p = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            throw CleanExit.message("Cannot read: \(p)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CleanExit.message("File is not valid UTF-8: \(p)")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if maxLines > 0 {
            lines = Array(lines.prefix(maxLines))
        }
        for line in lines {
            print("\(prefix)\(line)")
        }
    }
}

// MARK: - write (one positional, required option, flag with default)

struct Write: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write a string to a file (overwrites or appends)."
    )

    @Argument(help: "File path to create or update")
    var path: String

    /// A required long option: user must pass `--string '...'`.
    @Option(name: .long, help: "The exact text to write; required")
    var string: String

    @Flag(help: "If set, add to the end of the file instead of replacing it")
    var append: Bool = false

    mutating func run() throws {
        let p = (path as NSString).expandingTildeInPath
        let data = Data(string.utf8)
        let url = URL(fileURLWithPath: p)
        if append, FileManager.default.fileExists(atPath: p) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - copy (two positionals, flag with default)

struct Copy: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy a file to a new path."
    )

    @Argument(help: "Source file")
    var source: String

    @Argument(help: "Destination path (file will be created or replaced when forced)")
    var destination: String

    @Flag(name: .shortAndLong, help: "Overwrite the destination if it already exists")
    var force: Bool = false

    mutating func run() throws {
        let src = (source as NSString).expandingTildeInPath
        let dst = (destination as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: dst) && !force {
            throw CleanExit.message("Destination exists (use -f to overwrite): \(dst)")
        }
        if FileManager.default.fileExists(atPath: dst) {
            try FileManager.default.removeItem(atPath: dst)
        }
        do {
            try FileManager.default.copyItem(atPath: src, toPath: dst)
        } catch {
            throw CleanExit.message("Copy failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - info (one positional, optional with default for display)

struct Info: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show path, type, and size of a file or directory."
    )

    @Argument(help: "Path to describe")
    var path: String

    @Option(help: "How to show file size: bytes, kb, or mb")
    var sizeUnit: SizeUnit = .bytes

    enum SizeUnit: String, ExpressibleByArgument, CaseIterable {
        case bytes
        case kb
        case mb
    }

    mutating func run() throws {
        let p = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
        if !exists {
            throw CleanExit.message("Path does not exist: \(p)")
        }
        let type = isDir.boolValue ? "directory" : "file"
        print("path:  \(p)")
        print("type:  \(type)")
        if !isDir.boolValue, let attr = try? FileManager.default.attributesOfItem(
            atPath: p
        ) {
            if let n = attr[.size] as? NSNumber {
                let b = n.uint64Value
                let shown: String
                switch sizeUnit {
                case .bytes:
                    shown = "\(b) bytes"
                case .kb:
                    shown = String(format: "%.2f kb", Double(b) / 1024.0)
                case .mb:
                    shown = String(format: "%.2f mb", Double(b) / (1024.0 * 1024.0))
                }
                print("size:  \(shown)")
            }
        }
    }
}

// MARK: - remove (positional + flag default)

struct Remove: ParsableCommand {
    nonisolated(unsafe) static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a file or an empty directory."
    )

    @Argument(help: "Path to delete")
    var path: String

    @Flag(help: "If set, delete recursively (dangerous; demo only)")
    var recursive: Bool = false

    mutating func run() throws {
        let p = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
            throw CleanExit.message("Path does not exist: \(p)")
        }
        if isDir.boolValue {
            if !recursive {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
                if !entries.isEmpty {
                    throw CleanExit.message("Directory is not empty (use --recursive)")
                }
            }
            try FileManager.default.removeItem(atPath: p)
        } else {
            try FileManager.default.removeItem(atPath: p)
        }
    }
}
