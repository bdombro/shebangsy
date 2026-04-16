#!/usr/bin/env -S shebangsy go
// requires: gonum.org/v1/gonum

/*
Gonum + shebangsy

Minimal linear algebra demo: element-wise vector add, dot product, and
matrix–vector multiply. Dependencies are fetched automatically.

Usage:
	chmod +x examples/go/gonum.go
	./examples/go/gonum.go
	# or: shebangsy go examples/go/gonum.go
*/

package main

import (
	"fmt"

	"gonum.org/v1/gonum/mat"
)

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
