import std/[tables, strutils]
import ./common

import ./go_backend
import ./mojo_backend
import ./nim_backend

proc registryLoad*(): Table[string, LanguageRunner] =
  result = initTable[string, LanguageRunner]()
  block:
    let runner = go_backend.createRunner()
    result[runner.key.toLowerAscii] = runner
    for alias in runner.aliases:
      result[alias.toLowerAscii] = runner
  block:
    let runner = mojo_backend.createRunner()
    result[runner.key.toLowerAscii] = runner
    for alias in runner.aliases:
      result[alias.toLowerAscii] = runner
  block:
    let runner = nim_backend.createRunner()
    result[runner.key.toLowerAscii] = runner
    for alias in runner.aliases:
      result[alias.toLowerAscii] = runner
