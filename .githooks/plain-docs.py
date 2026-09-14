#!/usr/bin/env python3
"""Docs are plain ASCII apart from accented letters: no em dashes, emoji,
arrows, box-drawing or curly quotes. Prints each offending line."""
import sys

ALLOWED = range(0x00C0, 0x0250)  # Latin-1 Supplement and Latin Extended letters, for names
bad = 0
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            chars = sorted({c for c in line if ord(c) > 0x7F and ord(c) not in ALLOWED})
            if chars:
                bad += 1
                print(f"{path}:{n}: {' '.join(f'U+{ord(c):04X} ({c})' for c in chars)}")
sys.exit(1 if bad else 0)
