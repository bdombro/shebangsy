#!/usr/bin/env -S shebangsy cpp

// Minimal C++ hello-world: prints a fixed greeting to stdout.
//
// Usage:
//   ./examples/cpp/hello.cpp
//
// Expected:
//   Hello, C++!

#include <iostream>

using namespace std;

// Prints a short hello message to stdout.
int main() {
  auto message = "Hello, C++!";
  cout << message << endl;
  return 0;
}
