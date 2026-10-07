#!/usr/bin/env bash
# Run the actual CI image save/load blocks against small byte fixtures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

repo = Path(sys.argv[1])
workflow = (repo / '.github/workflows/ci.yml').read_text()
loads = re.findall(r'      - name: Load the prebuilt image\n.*?        run: \|\n(.*?)(?=      -)', workflow, re.S)
assert len(loads) == 2
save = re.search(r'          (?:set [-+]o pipefail\n          )?docker save .*?          ls -l sagent-macos-image.tar.zst\n', workflow, re.S)
assert save
with tempfile.TemporaryDirectory(prefix='sagent-image-archive.') as temporary:
    root = Path(temporary)
    (root / '.github').mkdir()
    shutil.copy(repo / '.github/verify-image-archive.py', root / '.github')
    binary = root / 'bin'
    binary.mkdir()
    stubs = {
        'brew': '#!/bin/sh\nexit 0\n',
        'docker': '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if sys.argv[1] == 'save':
    sys.stdout.buffer.write(b'partial saved image')
    sys.exit(37)
assert sys.argv[1] == 'load', sys.argv
sys.stdin.buffer.read()
Path(os.environ['ARCHIVE_TEST_LOAD_MARKER']).write_text('loaded')
sys.exit(73)
''',
        # Accept any bytes: the real checksum guard must stop bad archives
        # before they reach the loader. No zstd installation is needed here.
        'zstd': '''#!/usr/bin/env python3
from pathlib import Path
import sys
if '-o' in sys.argv:
    Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(sys.stdin.buffer.read())
else:
    assert sys.argv[1] == '-dc', sys.argv
    sys.stdout.buffer.write(Path(sys.argv[2]).read_bytes())
''',
    }
    for name, content in stubs.items():
        path = binary / name
        path.write_text(content)
        path.chmod(0o755)
    marker = root / 'loaded'
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
               ARCHIVE_TEST_LOAD_MARKER=str(marker))
    archive = root / 'sagent-macos-image.tar.zst'
    manifest = root / 'sagent-macos-image.tar.zst.sha256'
    data = b'sandbox archive fixture with a complete final block'
    expected = hashlib.sha256(data).hexdigest() + '\n'
    for index, block in enumerate(loads, 1):
        for mode in ('healthy', 'truncated', 'corrupt', 'missing-archive', 'missing-manifest', 'invalid-manifest'):
            archive.write_bytes(data)
            manifest.write_text(expected)
            marker.unlink(missing_ok=True)
            if mode == 'truncated': archive.write_bytes(data[:-10])
            if mode == 'corrupt': archive.write_bytes(b'X' + data[1:])
            if mode == 'missing-archive': archive.unlink()
            if mode == 'missing-manifest': manifest.unlink()
            if mode == 'invalid-manifest': manifest.write_text('not a digest\n')
            result = subprocess.run(['bash', '-e', '-c', textwrap.dedent(block)],
                                    cwd=root, env=env, capture_output=True, text=True)
            if mode == 'healthy':
                assert result.returncode == 73 and marker.exists(), result.stdout + result.stderr
            else:
                assert result.returncode != 0 and not marker.exists(), (mode, result.stdout, result.stderr)
                assert 'Image archive validation failed' in result.stderr
            print(f'load block {index}, {mode}: archive regression passed')
    archive.unlink(missing_ok=True)
    manifest.unlink(missing_ok=True)
    result = subprocess.run(['bash', '-e', '-c', textwrap.dedent(save.group())],
                            cwd=root, env=dict(env, tag='fixture'), capture_output=True, text=True)
    assert result.returncode == 37, result.stdout + result.stderr
    assert not manifest.exists(), 'A failed docker save must not publish a checksum'
    print('Failed docker save stops archive publication')
PY
