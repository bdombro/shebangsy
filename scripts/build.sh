#!/bin/bash
nimble build
# nim c -d:release --hints:off --verbosity:0 -o:dist/shebangsy src/shebangsy.nim
echo "build.sh: shebangsy built to dist/shebangsy"