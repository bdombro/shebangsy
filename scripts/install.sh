#!/bin/bash

set -euo pipefail

nimble install
echo "install.sh: shebangsy installed to Nim's bin directory ~/.nimble/bin"
rm -rf ~/.cache/shebangsy/* 2>/dev/null || true
echo "install.sh: shebangsy cache cleared"
