#!/usr/bin/env bash
# Exercise the generated storage allocator with real filesystem locks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$SCRIPT_DIR/sclaude" "$SCRIPT_DIR/scodex"; fi
python3 - "$SCRIPT_DIR" "$@" <<'PY'
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def extract(source, target):
    end = source.index('        > ' + target + ';')
    start = source.rfind("    printf '%s\\n' \\", 0, end)
    block = source[start:end].rstrip()
    assert start >= 0 and block.endswith('\\')
    return subprocess.check_output(['bash', '-c', block[:-1] + '\n']).decode()


script_dir = Path(sys.argv[1])
errors = []
with tempfile.TemporaryDirectory(prefix='sagent-storage-cold-test.') as tmp:
    path = Path(tmp)
    marker = path / 'storage-root'
    root = path / 'slot'
    source = (script_dir / 'test_nested.sh').read_text()
    start = source.rfind('\n', 0, source.index('podman info --format')) + 1
    end = source.index('# Consume the full output:', start)
    # The info call initializes the lease lazily. Delay it so the old
    # pipeline always reads the marker before the producer creates it.
    check = source[start:end].replace('/run/sagent/storage-root', str(marker))
    stub = """
set -euo pipefail
podman() {
    sleep 0.1
    printf '%s\\n' "$TEST_STORAGE_ROOT" > "$TEST_STORAGE_MARKER"
    printf '%s/storage-multiuser\\n' "$TEST_STORAGE_ROOT"
}
"""
    env = dict(os.environ, TEST_STORAGE_ROOT=str(root), TEST_STORAGE_MARKER=str(marker))
    result = subprocess.run(['bash', '-c', stub + check], env=env, capture_output=True, text=True)
    if result.returncode:
        errors.append('cold Podman initialization: ' + result.stderr.strip())

source = (script_dir / 'test_e2e.sh').read_text()
# These two lines sit in T27's escaped command body. Test both supported
# executable spellings with the actual lookup patterns, before killing it.
lookups = '\n'.join(line.replace('\\', '') for line in source.splitlines()
                    if 'api_pid=' in line or 'api_parent=' in line)
for executable in ('podman', '/usr/bin/podman'):
    stub = """
set -euo pipefail
fail() { echo "$*" >&2; exit 1; }
pgrep() {
    printf '%s\\n' "$TEST_API_COMMAND" | grep -E -- "$2" >/dev/null || return 1
    printf '123\\n'
}
"""
    env = dict(os.environ, TEST_API_COMMAND=executable + ' --log-level=error system service --time=0 unix:///run/podman/podman.sock')
    result = subprocess.run(['bash', '-c', stub + lookups + '\n[ "$api_pid" = 123 ] && [ "$api_parent" = 123 ]'], env=env, capture_output=True, text=True)
    if result.returncode:
        errors.append('API process lookup: ' + executable)
assert not errors, '\n'.join(errors)
print('Cold storage assertion and both API process spellings passed')

for wrapper in sys.argv[2:]:
    processes = []
    with tempfile.TemporaryDirectory(prefix='sagent-storage-test.') as tmp:
        path = Path(tmp)
        base = path / 'persistent storage'
        base.mkdir()
        (base / 'storage-multiuser').mkdir()
        legacy = base / 'storage-multiuser' / 'database'
        legacy.write_text('keep-data')
        (base / 'buildkit').mkdir()
        with (base / 'buildkit' / 'buildkitd.lock').open('a') as old_daemon:
            fcntl.flock(old_daemon, fcntl.LOCK_EX | fcntl.LOCK_NB)
            source = Path(wrapper).read_text()
            guard = extract(source, '/usr/local/lib/sagent/container-storage.py')
            helper = extract(source, '/usr/local/bin/sagent-container-storage')

            def start(name, scope):
                runtime = path / name
                runtime.mkdir()
                code = guard.replace("Path.home() / '.local/share/containers'", 'Path(' + repr(str(base)) + ')')
                code = code.replace("Path('/run/sagent')", 'Path(' + repr(str(runtime)) + ')')
                script = runtime / 'guard.py'
                script.write_text(code)
                env = dict(os.environ, SAGENT_STORAGE_WORKSPACE=scope)
                process = subprocess.Popen([sys.executable, str(script)], env=env)
                processes.append(process)
                for _ in range(200):
                    if (runtime / 'storage-root').exists():
                        root = Path((runtime / 'storage-root').read_text())
                        assert (runtime / 'storage.pid').read_text() == str(process.pid)
                        conf = (runtime / 'storage.conf').read_text().split('graphroot = ', 1)[1]
                        assert json.loads(conf) == str(root / 'storage-multiuser')
                        return process, root, runtime
                    assert process.poll() is None, 'lease guard exited during allocation'
                    time.sleep(0.01)
                raise AssertionError('allocation did not complete')

            try:
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    a = pool.submit(start, 'first', '/same/workspace')
                    b = pool.submit(start, 'second', '/same/workspace')
                    first, second = a.result(), b.result()
                assert first[1] != second[1], 'concurrent sandboxes shared storage'
                assert {first[1].name, second[1].name} == {'0', '1'}
                other = start('other', '/different/workspace')
                assert other[1].parent != first[1].parent
                for _, root, _ in (first, second, other):
                    with (root / '.lease').open('a') as probe:
                        try:
                            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            pass
                        else:
                            raise AssertionError('lease was not held after readiness')
                (first[1] / 'cached-data').write_text('reuse-cache')
                first[0].terminate()
                first[0].wait(timeout=5)
                again = start('restart', '/same/workspace')
                assert again[1] == first[1], 'released slot was not reused'
                assert (again[1] / 'cached-data').read_text() == 'reuse-cache'
                assert legacy.read_text() == 'keep-data'
                assert second[0].poll() is None
                # A lost lease must fail closed, even when its marker survives.
                relocated = helper.replace('/run/sagent', str(first[2]))
                script = first[2] / 'helper.sh'
                script.write_text(relocated)
                result = subprocess.run(['sh', str(script)], capture_output=True, text=True)
                assert result.returncode == 1
                assert 'lease exited' in result.stderr
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
    print(Path(wrapper).name + ': concurrent leases, project isolation, reuse and legacy preservation passed')
PY
