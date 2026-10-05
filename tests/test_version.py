import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROGRAMS = [
    ('server/bin/keyport', 'app', False),
    ('server/bin/keyport-update', 'app', True),
    ('clients/linux/bin/keyport-client', '.', False),
    ('clients/linux/bin/keyport-client-update', '.', True),
]


@pytest.mark.parametrize('source,metadata_dir,shell', PROGRAMS)
@pytest.mark.parametrize('option', ['-v', '--version'])
@pytest.mark.parametrize('metadata', ['valid', 'missing', 'invalid'])
def test_version_is_local_and_does_not_require_config(tmp_path, source, metadata_dir, shell, option, metadata):
    install = tmp_path / 'installation'
    target = install / 'bin' / Path(source).name
    target.parent.mkdir(parents=True)
    text = (ROOT / source).read_text().replace('/opt/keyport-client', str(install)).replace('/opt/keyport', str(install))
    target.write_text(text)
    info = install / metadata_dir / 'build-info.json'
    info.parent.mkdir(exist_ok=True)
    if metadata == 'valid':
        info.write_text(json.dumps({'version': '1.2.0', 'commit': 'a' * 40}))
    elif metadata == 'invalid':
        info.write_text('{bad-json')
    result = subprocess.run(['bash' if shell else sys.executable, str(target), option], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    expected = '1.2.0 (aaaaaaaaaaaa)' if metadata == 'valid' else 'unknown (unknown)'
    assert result.stdout.strip() == f'{target.name} {expected}'
    assert not (install / '.update.lock').exists()


@pytest.mark.parametrize('source,metadata_dir,shell', PROGRAMS)
@pytest.mark.parametrize('option', ['-h', '--help', '--bad-option', '-v extra'])
def test_informational_and_invalid_options_never_update(tmp_path, source, metadata_dir, shell, option):
    target = tmp_path / Path(source).name
    target.write_text((ROOT / source).read_text().replace('/opt/keyport-client', str(tmp_path / 'missing')).replace('/opt/keyport', str(tmp_path / 'missing')))
    result = subprocess.run(['bash' if shell else sys.executable, str(target), *option.split()], capture_output=True, text=True, timeout=10)
    # argparse version actions exit as soon as -v is parsed; updaters reject
    # extra arguments before doing anything. Neither may begin an update.
    if option in ('-h', '--help'):
        assert result.returncode == 0
        assert '-v, --version' in result.stdout
    elif option == '--bad-option' or shell:
        assert result.returncode == 2
    assert not (tmp_path / 'missing').exists()
