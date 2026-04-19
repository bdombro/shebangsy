# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog][keep-a-changelog],
and this project adheres to [Semantic Versioning][semver].

## [Unreleased]

## [1.0.1] - 2026-04-19

### Added

- GitHub Actions workflow (`.github/workflows/ci.yml`) running `./scripts/test.sh` on push and PR to `main`, with Nim, Go, and Swift toolchains installed (Mojo skipped in CI).
- CI workflow: concurrency cancel-in-progress, named steps, Nimble package cache (`actions/cache`), and Go module cache when a `go.sum` is present (`actions/setup-go`).
- Everything!

[Unreleased]: https://github.com/bdombro/shebangsy/compare/1.0.1...HEAD
[1.0.1]: https://github.com/bdombro/shebangsy/compare/1.0.0...1.0.1
[keep-a-changelog]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html
