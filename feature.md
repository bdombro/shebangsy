Make an app in this dir, "shebangsy", which is a single-file app runner.

shebangnsy: allows nim, golang, mojo apps to be ran directly without the writer knowing or messing with bundling and compiling.

Ex.
```
#!/usr/bin/env -S shebangsy go <-- golang
#!/usr/bin/env -S shebangsy mojo <-- mojo
#!/usr/bin/env -S shebangsy nim <-- nim
```

The language is determined by the second argument

Shebangsy is written in nim, and is almost identical to ../nimr, ../gor, ../mojor, but instead of supporting only one language, it supports all three.

Each language is supported by a separate module, and the main shebangsy module will determine which one to use based on the second argument.

File structure:

- Almost identical to ../nimr, ../gor, ../mojor, except there should be a dir for "languages" which contains the language-specific modules.

Features:

- Almost identical to ../nimr, ../gor, ../mojor, with scripts, justfile, examples, smoke tests, benchmarks, etc. for each language.


Language specific modules:

- Should share/extend a common interface, so that the main shebangsy module can call them without knowing which one is being used.
- Should be auto-discoverable by the main shebangsy module, so that adding a new language is as simple as adding a new module to the "languages" dir.
- Should be compiled to a single file, so that the shebangsy app can be a single file.


