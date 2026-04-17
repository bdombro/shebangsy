#!/usr/bin/env -S shebangsy mojo
# Simple matrix-style example that runs on baseline Mojo syntax.

# Prints a nested list as a matrix and a simple sum of corner elements.
def main():
    matrix = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]

    print("Matrix:")
    for row in matrix:
        for value in row:
            print(value, end=" ")
        print()

    sum_value = matrix[0][0] + matrix[1][2]
    print("\nFirst element + last element =", sum_value)
