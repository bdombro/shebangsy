#!/usr/bin/env -S shebangsy nim
# Neo still uses ``shallowCopy`` internally; Nim 2 defaults need refc for that (see neo issue #50).
#!flags: --mm:refc
#!requires: neo

# Demonstrate importing an external library and using a compiler flag

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
