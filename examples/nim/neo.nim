#!/usr/bin/env -S shebangsy nim
#!flags: --mm:refc
#!requires: neo

## Linear algebra with neo: prints vector sum, dot product, and a matrix–vector
## product for small fixed tensors. Neo is fetched via #!requires; Nim 2 needs
## ``--mm:refc`` because neo still uses ``shallowCopy`` internally (neo issue #50).
##
## Usage:
##   ./examples/nim/neo.nim
##
## Expected:
##   [ 5.0	7.0	9.0 ]
##   32.0
##   [ 1.0	3.0 ]

import neo

let
  u = vector(1.0, 2.0, 3.0)
  v = vector(4.0, 5.0, 6.0)

echo u + v      # element-wise add
echo u * v      # dot product (scalars)

let
  A = matrix(@[
    @[1.0, 2.0],
    @[3.0, 4.0],
  ])
  x = vector(1.0, 0.0)

echo A * x      # matrix–vector product
