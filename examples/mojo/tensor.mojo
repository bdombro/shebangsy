#!/usr/bin/env -S shebangsy mojo

# Baseline Mojo demo: prints a 2x3 matrix built from nested lists and the sum
# of one corner element plus the opposite corner.
#
# Usage:
#   ./examples/mojo/tensor.mojo
#
# Expected:
#   Matrix:
#   1.0 2.0 3.0
#   4.0 5.0 6.0
#
#   First element + last element = 7.0
def main():
    matrix = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]

    print("Matrix:")
    for row in matrix:
        for value in row:
            print(value, end=" ")
        print()

    sum_value = matrix[0][0] + matrix[1][2]
    print("\nFirst element + last element =", sum_value)
