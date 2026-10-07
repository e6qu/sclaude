#!/usr/bin/env bash
# Test the CI DNS setup and container probe without a VM or network access.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='sagent-rancher-dns-') as directory:
    root = Path(directory)
    binary = root / 'bin'
    binary.mkdir()
    stubs = {
        'rdctl': '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['DNS_TEST_ROOT'])
mode = os.environ['DNS_TEST_MODE']
args = sys.argv[1:]
if args == ['shell', 'sudo', 'cat', '/etc/docker/daemon.json']:
    print('{' if mode == 'invalid' else (root / 'original.json').read_text())
elif args == ['shell', 'sudo', 'tee', '/etc/docker/daemon.json']:
    if mode == 'write-failure': sys.exit(71)
    (root / 'configured.json').write_text(sys.stdin.read())
elif args == ['shell', 'sudo', 'rc-service', 'docker', 'restart']:
    assert (root / 'configured.json').exists()
    (root / 'restart').touch()
    if mode == 'restart-failure': sys.exit(72)
else:
    raise AssertionError(args)
''',
        'docker': '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
root = Path(os.environ['DNS_TEST_ROOT'])
mode = os.environ['DNS_TEST_MODE']
args = sys.argv[1:]
if mode.startswith('probe'):
    assert args[:5] == ['run', '--rm', 'fixture-image', 'bash', '-ec']
    assert args[6] == '_'
    body = args[5].replace('/etc/resolv.conf', str(root / 'resolv.conf'))
    os.execvp('bash', ['bash', '-ec', body, '_', args[7]])
assert args == ['info']
assert (root / 'restart').exists()
count_file = root / 'count'
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
count_file.write_text(str(count))
sys.exit(1 if mode == 'down' or (mode == 'delayed' and count < 3) else 0)
''',
        'sleep': '#!/bin/sh\nexit 0\n',
        'timeout': '#!/bin/sh\nshift\nexec "$@"\n',
        'getent': '''#!/bin/sh
[ "$DNS_TEST_MODE" != probe-failure ] || exit 44
printf '1.2.3.4 STREAM fixture\\n'
''',
    }
    for name, contents in stubs.items():
        target = binary / name
        target.write_text(contents)
        target.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
               RDCTL=str(binary / 'rdctl'), DNS_TEST_ROOT=str(root))
    original = {'features': {'containerd-snapshotter': True},
                'registry-mirrors': ['https://fixture.invalid'], 'dns': ['192.168.5.2']}
    (root / 'original.json').write_text(json.dumps(original))
    for mode, expected in [('healthy', 0), ('delayed', 0), ('invalid', 1),
                           ('write-failure', 71), ('restart-failure', 72), ('down', 1)]:
        for name in ('configured.json', 'restart', 'count'):
            (root / name).unlink(missing_ok=True)
        result = subprocess.run(['bash', str(source / '.github/configure-rancher-dns.sh')],
                                env=dict(env, DNS_TEST_MODE=mode), capture_output=True, text=True)
        assert result.returncode == expected, (mode, result.returncode, result.stderr)
        if mode in ('invalid', 'write-failure'):
            assert not (root / 'configured.json').exists() and not (root / 'restart').exists()
        else:
            configured = json.loads((root / 'configured.json').read_text())
            assert configured == dict(original, dns=['1.1.1.1', '8.8.8.8']), configured
        if mode == 'delayed': assert (root / 'count').read_text() == '3'
        if mode == 'down': assert (root / 'count').read_text() == '24'
        print(f'{mode}: Rancher DNS setup regression passed')
    for mode, resolvers, expected_arg, expected in [
        ('probe-healthy', ['1.1.1.1', '8.8.8.8'], '1.1.1.1 8.8.8.8', 0),
        ('probe-forwarder', ['192.168.5.2'], '1.1.1.1 8.8.8.8', 1),
        ('probe-default', ['192.168.5.2'], '', 0),
        ('probe-failure', ['1.1.1.1', '8.8.8.8'], '1.1.1.1 8.8.8.8', 44),
    ]:
        (root / 'resolv.conf').write_text(''.join(f'nameserver {r}\n' for r in resolvers))
        result = subprocess.run(['bash', str(source / 'test_dns.sh'), str(binary / 'docker'),
                                 'fixture-image', expected_arg],
                                env=dict(env, DNS_TEST_MODE=mode), capture_output=True, text=True)
        assert result.returncode == expected, (mode, result.returncode, result.stderr)
        if mode == 'probe-forwarder': assert 'Expected container DNS resolver' in result.stderr
        print(f'{mode}: container DNS probe regression passed')
PY
