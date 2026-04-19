#!/usr/bin/env -S shebangsy mojo
#!requires: numpy

# Loads NumPy through Mojo’s Python interop and prints a small 1-D array.
#
# Usage:
#   ./examples/mojo/numpy.mojo
#
# Expected (exact formatting depends on your NumPy build):
#   [1 2 3]

from std.python import Python

def main() raises:
    # This is equivalent to Python's `import numpy as np`
    np = Python.import_module("numpy")

    # Now use numpy as if writing in Python
    array = np.array(Python.list(1, 2, 3))
    print(array)
