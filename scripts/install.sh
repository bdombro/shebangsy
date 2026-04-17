#!/bin/bash

set -euo pipefail

nimble install
echo "install.sh: shebangsy installed to Nim's bin directory ~/.nimble/bin"

mkdir -p "${HOME}/.zsh/completions"
shebangsy completion zsh > "${HOME}/.zsh/completions/_shebangsy"
echo "install.sh: zsh completion installed to ${HOME}/.zsh/completions/_shebangsy"
rm -rf ~/.cache/shebangsy/* 2>/dev/null || true
echo "install.sh: shebangsy cache cleared"
