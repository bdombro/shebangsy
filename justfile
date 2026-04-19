_:
    just --list

# Benchmark warm-run times; appends benches.jsonl and regenerates benches-report.md
bench:
    ./scripts/bench.py

# Regenerate benches-report.md and README Results chart from benches.jsonl (no hyperfine)
bench-report:
    ./scripts/bench.py --regenerate-report

# Build shebangsy binary to ./dist/shebangsy
build:
    ./scripts/build.sh

# Build release zips for macOS and Linux
build-cross version="dev":
    ./scripts/build-cross.sh "{{version}}"

# Install Nim dependencies (required once before first build)
deps:
    nimble install

# Build and install shebangsy to ~/.nimble/bin
install:
    ./scripts/install.sh

# Create a release: bump version, build cross-platform zips, push tag and release
release VERSION:
    #!/bin/bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [[ "{{VERSION}}" =~ ^(patch|minor|major)$ ]]; then
      VER="$(./scripts/release.py --print-version "{{VERSION}}")"
      ./scripts/build-cross.sh "$VER"
      ./scripts/release.py "$VER"
    else
      ./scripts/build-cross.sh "{{VERSION}}"
      ./scripts/release.py "{{VERSION}}"
    fi

# Run smoke tests for Nim and Go (Mojo skipped if unavailable)
test:
    ./scripts/test.sh
