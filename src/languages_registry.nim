#[
languages_registry – maps language tokens to LanguageRunner values

Goal: be the single file an author edits to register a new language backend; shebangsy.nim
  never imports individual language modules directly.

Why: decoupling the entry point from language modules means adding a language is a
  one-line change here (add createRunner() to registryAll), with no edits needed to
  the hot path or binary argv handling in shebangsy.nim.

How: registryAll() calls createRunner() on each language module in priority order.
  registryByToken() builds the token lookup table from that list.
]#

import std/[strutils, tables]
import ./languages_common
import ./languages/[nim, go, mojo, cpp, rust, swift, python3]


## Ordered runners (one per language) plus helpers for token dispatch.
proc registryAll*(): seq[LanguageRunner] =
  @[
    nim.createRunner(),
    go.createRunner(),
    mojo.createRunner(),
    cpp.createRunner(),
    rust.createRunner(),
    swift.createRunner(),
    python3.createRunner(),
  ]


## Token -> runner table (key + all aliases, lower-cased).
proc registryByToken*(): Table[string, LanguageRunner] =
  result = initTable[string, LanguageRunner]()
  for r in registryAll():
    result[r.key.toLowerAscii] = r
    for a in r.aliases:
      result[a.toLowerAscii] = r
