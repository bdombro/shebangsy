# shebangsy

Single-file app runner for Nim, Go, and Mojo scripts.

## Shebang examples

```bash
#!/usr/bin/env -S shebangsy go
#!/usr/bin/env -S shebangsy mojo
#!/usr/bin/env -S shebangsy nim
```

The language is selected by the first argument after shebangsy.

## Usage

```bash
shebangsy <language> <script> [args...]
shebangsy cache-clear [language]
shebangsy completion zsh
```

## Build

```bash
just build
```

## Install

```bash
just install
```

## Test

```bash
just test
```

## Add a language backend

1. Add a module under `languages` with name `*_backend.nim`.
2. Export a constructor proc that returns `LanguageRunner`.
3. Update constructor mapping in `scripts/gen-registry.sh`.
4. Run `just build`.
