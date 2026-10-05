"""Exercise the installer's actual detection block against isolated OS metadata."""
import subprocess
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
    ('ID=ubuntu\n', None, None),
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
