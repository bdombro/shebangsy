#!/usr/bin/env -S shebangsy mojo
#!requires: numpy

from std.python import Python

# Imports NumPy via Python interop and prints a small array.
def main() raises:
    # This is equivalent to Python's `import numpy as np`
    np = Python.import_module("numpy")

    # Now use numpy as if writing in Python
    array = np.array(Python.list(1, 2, 3))
    print(array)
