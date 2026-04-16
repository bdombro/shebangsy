#!/usr/bin/env -S shebangsy nim
# requires: arraymancer

# Demonstrate importing an external library

import arraymancer

let x = toTensor([1.0, 2.0, 3.0])
echo x.sum
echo x *. x  # element-wise multiply; ``*`` alone is matrix multiply
