_:
    just --list

bench:
    ./scripts/bench.sh

build:
    ./scripts/build.sh

build-cross version="dev":
    ./scripts/build-cross.sh "{{version}}"

deps:
    @echo "Use nimble install -y argsbarg if argsbarg is missing from your Nim paths."

install:
    ./scripts/install.sh

release VERSION:
    #!/usr/bin/env bash
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

test:
    ./scripts/test.sh
