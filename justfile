_:
    just --list

# Benchmark warm-run times; appends benches.jsonl and regenerates benches-report.md
bench:
    ./scripts/bench.py

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
      VER="$(./scripts/release.sh --print-version "{{VERSION}}")"
      ./scripts/build-cross.sh "$VER"
      ./scripts/release.sh "$VER"
    else
      ./scripts/build-cross.sh "{{VERSION}}"
      ./scripts/release.sh "{{VERSION}}"
    fi

# Run smoke tests for Nim and Go (Mojo skipped if unavailable)
test:
    ./scripts/test.sh
