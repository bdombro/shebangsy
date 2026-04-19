#!/usr/bin/env -S shebangsy python3
#!requires: requests

"""
Fetch a URL with the ``requests`` library and print the HTTP status plus the first
80 characters of the response body. Demonstrates ``#!requires:`` for Python deps.

Usage:
    ./examples/python/requests.py
    ./examples/python/requests.py https://example.com

Expected (status line is exact; HTML prefix may change if the site changes):
    200 https://example.com
    <!doctype html><html lang="en"><head><title>Example Domain</title><meta name="vi
"""

import sys

import requests


def fetch(url: str) -> None:
    """Fetch url and print the HTTP status code and first 80 characters of the response."""
    r = requests.get(url)
    print(f"{r.status_code} {url}")
    print(r.text[:80])


def main() -> None:
    """Parse argv and run fetch with the given URL or a default."""
    url = sys.argv[1] if len(sys.argv) > 1 else "https://example.com"
    fetch(url)


if __name__ == "__main__":
    main()
