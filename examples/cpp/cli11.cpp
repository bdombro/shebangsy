#!/usr/bin/env -S shebangsy cpp
#!requires: github:CLIUtils/CLI11@v2.4.1:CLI11::CLI11

// CLI11 demo: requires the ``hello`` subcommand and a positional ``name``; prints
// ``hello, <name>`` when you run that subcommand.
//
// Usage:
//   ./examples/cpp/cli11.cpp hello Ada
//
// Expected:
//   hello, Ada

#include <iostream>
#include <string>
#include <CLI/CLI.hpp>

using namespace std;

// Parses CLI11 subcommands and prints a hello line for the given name.
int main(int argc, char** argv) {
    auto app = CLI::App{"A modern C++ CLI application"};
    app.require_subcommand(1);
    auto* hello_sub = app.add_subcommand("hello", "Prints a greeting");
    auto name = string{};
    hello_sub->add_option("name", name, "The name you want to greet")->required();
    CLI11_PARSE(app, argc, argv);

    if (app.got_subcommand(hello_sub)) {
        cout << "hello, " << name << "\n";
    }

    return 0;
}
