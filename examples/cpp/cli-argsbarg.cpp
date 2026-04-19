#!/usr/bin/env -S shebangsy cpp
#!requires: github:bdombro/cpp-argsbarg@v0.5.0:argsbarg::argsbarg

// Small CLI with cpp-argsbarg: ``hello`` greets ``world`` by default; optional
// ``--name`` / ``-n`` and ``--verbose`` / ``-v``; falls back to ``hello`` when the
// command is missing or unknown.
//
// Usage:
//   ./examples/cpp/cli-argsbarg.cpp hello
//   ./examples/cpp/cli-argsbarg.cpp hello --name Ada
//   ./examples/cpp/cli-argsbarg.cpp hello -n Ada -v
//
// Expected (one block per usage line above, in order):
//   hello world
//
//   hello Ada
//
//   verbose mode
//   hello Ada

#include <argsbarg/argsbarg.hpp>
#include <iostream>

using namespace argsbarg;

int main(int argc, const char* argv[]) {
    auto greet = [](Context& ctx) {
        const auto name = ctx.string_opt("name").value_or("world");
        if (ctx.flag("verbose")) {
            std::cout << "verbose mode\n";
        }
        std::cout << "hello " << name << '\n';
    };

    Application{"minimaldemo"}
        .description("Tiny demo.")
        .fallback("hello", FallbackMode::MissingOrUnknown)
        .command(Leaf{"hello", "Say hello."}
                     .handler(greet)
                     .option(Opt{"name", "Who to greet."}.string().short_alias('n'))
                     .option(Opt{"verbose", "Enable extra logging."}.short_alias('v')))
        .run(argc, argv);
}
