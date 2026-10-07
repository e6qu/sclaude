#!/usr/bin/env python3
"""Check the image archive against the builder's SHA-256 before loading it."""
import hashlib
from pathlib import Path
import re
import sys


archive = Path(sys.argv[1])
try:
    expected = Path(str(archive) + '.sha256').read_text(encoding='ascii').strip()
    if not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('invalid SHA-256 manifest')
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError('SHA-256 mismatch: image archive is incomplete or corrupt')
except (OSError, UnicodeError, ValueError) as error:
    sys.exit(f'Image archive validation failed: {error}')
print(f'Image archive SHA-256 verified: {archive}')
