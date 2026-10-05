"""Exercise the installer's actual detection block against isolated OS metadata."""
import subprocess
import os
import sys
from pathlib import Path

import pytest

INSTALLER = Path(__file__).resolve().parents[1] / 'clients/linux/keyport-client-install'


@pytest.mark.parametrize('release,version,expected', [
    ('ID=debian\n', None, 'debian'),
    ('ID="debian"\n', 'os_name="other"\n', 'debian'),
    (None, 'os_name="DSM"\n', 'dsm'),
    ('ID=synology\n', 'os_name="DSM"\n', 'dsm'),
    ('ID=debian\n', 'os_name="DSM"\n', 'dsm'),
    ('ID=other\n', 'os_name="DSM"\n', 'dsm'),
    ('', 'os_name="DSM"\n', 'dsm'),
    ('ID=ubuntu\n', None, 'debian'),
    ('ID=linuxmint\nID_LIKE="ubuntu debian"\n', None, 'debian'),
    ('ID=pop\nID_LIKE=ubuntu\n', None, 'debian'),
    ('ID=custom\nID_LIKE="custom debian"\n', None, 'debian'),
    ('ID=custom\nID_LIKE="notdebian ubuntuish"\n', None, None),
    ('ID=fedora\nID_LIKE=rhel\n', None, None),
    ('ID=ubuntu\n', 'os_name="DSM"\n', 'dsm'),
    (None, None, None),
    (None, 'os_name="other"\n', None),
    ('ID=synology\n', 'os_name="other"\n', None),
    ('', None, None),
])
def test_platform_detection(tmp_path, release, version, expected):
    # Run only detection, before any package install, lock, download or mutation.
    source = INSTALLER.read_text()
    start = source.index('PLATFORM=""')
    end = source.index('if [[ "${PLATFORM}" == "debian" ]]; then', start)
    script = source[start:end]
    for name, content in [('os-release', release), ('VERSION', version)]:
        path = tmp_path / name
        if content is not None:
            path.write_text(content)
        script = script.replace('/etc/' + name, str(path))
    result = subprocess.run(
        ['bash', '-c', 'set -euo pipefail\nunset ID\ndie() { echo "$*" >&2; exit 1; }\n' + script + '\nprintf "%s" "$PLATFORM"'],
        capture_output=True, text=True, timeout=5,
    )
    if expected is None:
        assert result.returncode == 1
        assert 'unsupported operating system' in result.stderr
    else:
        assert result.returncode == 0, result.stderr
        assert result.stdout == expected


@pytest.mark.parametrize('platform,ready,apt,mode,expected,installed', [
    ('debian', True, False, '', 0, False),
    ('ubuntu', True, True, '', 0, False),
    ('derivative', False, True, '', 0, True),
    ('debian', False, False, '', 1, False),
    ('debian', False, True, 'update-fails', 1, False),
    ('debian', False, True, 'install-fails', 1, True),
    ('debian', False, True, 'still-broken', 1, True),
    ('dsm', True, False, '', 0, False),
    ('dsm', False, True, '', 1, False),
])
def test_dependency_handling(tmp_path, platform, ready, apt, mode, expected, installed):
    source = INSTALLER.read_text()
    start = source.index('dependencies_ready()')
    end = source.index('\nacquire_update_lock\n', start)
    code = source[start:end]
    release = tmp_path / 'os-release'
    release.write_text('ID=custom\nID_LIKE=debian\n' if platform == 'derivative' else f'ID={platform}\n')
    version = tmp_path / 'VERSION'
    if platform == 'dsm':
        version.write_text('os_name="DSM"\n')
    code = code.replace('/etc/os-release', str(release)).replace('/etc/VERSION', str(version))
    # Isolate package operations; readiness changes only after successful apt install.
    setup = f'READY={int(ready)}\nAPT={int(apt)}\nMODE={mode!r}\n' + r"""
set -euo pipefail
die() { echo "$*" >&2; exit 1; }
info() { echo "$*"; }
command() {
    if [[ "$1" == -v ]]; then
        if [[ "$2" == apt-get ]]; then [[ "$APT" == 1 ]]; return; fi
        if [[ "$2" == curl && "$READY" == 0 ]]; then return 1; fi
        return 0
    fi
    builtin command "$@"
}
python3() { [[ "$READY" == 1 ]]; }
apt-get() {
    echo "APT:$1"
    [[ "$MODE" != "$1-fails" ]] || return 1
    if [[ "$1" == install && "$MODE" != still-broken ]]; then READY=1; fi
}
"""
    result = subprocess.run(['bash', '-c', setup + code], capture_output=True, text=True, timeout=5)
    assert result.returncode == expected, result.stdout + result.stderr
    assert ('APT:install' in result.stdout) == installed
    if ready or platform == 'dsm':
        assert 'APT:' not in result.stdout


def test_dependency_checker_validates_crypto_and_tls():
    source = INSTALLER.read_text()
    code = source[source.index('dependencies_ready()'):source.index('PLATFORM=""')]
    result = subprocess.run(['bash', '-c', code + '\ndependencies_ready'], env=dict(os.environ, PATH=str(Path(sys.executable).parent) + ':' + os.environ['PATH']), capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stderr
