#!/usr/bin/env -S shebangsy go
#!requires: gonum.org/v1/gonum

/*
Gonum + shebangsy: minimal linear algebra demo.

Prints element-wise vector addition, the dot product of two 3-vectors, and a
small matrix–vector multiply. Gonum is pulled in via #!requires.

Usage:
	./examples/go/gonum.go

Expected:
	u + v = ⎡5⎤
	         ⎢7⎥
	         ⎣9⎦
	u · v = 32
	A * x = ⎡1⎤
	         ⎣3⎦
*/

package main

import (
	"fmt"
	"gonum.org/v1/gonum/mat"
)

// main demonstrates vector add, dot product, and matrix–vector multiply with Gonum.
func main() {
	u := mat.NewVecDense(3, []float64{1, 2, 3})
	v := mat.NewVecDense(3, []float64{4, 5, 6})

	var sum mat.VecDense
	sum.AddVec(u, v)
	fmt.Println("u + v =", mat.Formatted(&sum, mat.Prefix("         ")))

	dot := mat.Dot(u, v)
	fmt.Println("u · v =", dot)

	A := mat.NewDense(2, 2, []float64{
		1, 2,
		3, 4,
	})
	x := mat.NewVecDense(2, []float64{1, 0})

	var y mat.VecDense
	y.MulVec(A, x)
	fmt.Println("A * x =", mat.Formatted(&y, mat.Prefix("         ")))
}
