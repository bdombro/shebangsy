#!/usr/bin/env -S shebangsy nim
#!requires: arraymancer

## Uses Arraymancer to build a small float tensor, print its sum, then print an
## element-wise square (``*.``). Shows pulling a Nim ML stack dependency with shebangsy.
##
## Usage:
##   ./examples/nim/arraymancer.nim
##
## Expected:
##   6.0
##   Tensor[system.float] of shape "[3]" on backend "Cpu"
##       1     4     9

import arraymancer

let x = toTensor([1.0, 2.0, 3.0])
echo x.sum
echo x *. x  # element-wise multiply; ``*`` alone is matrix multiply
