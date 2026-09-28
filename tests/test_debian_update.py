"""Exercise pinned client downloads and metadata rollback in a temporary install."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
SHIM = r'''
import json, os, pathlib, shutil, signal, subprocess, sys, time
root = pathlib.Path(os.environ['CLIENT_TEST_ROOT'])
repo = pathlib.Path(os.environ['CLIENT_TEST_REPO'])
mode = os.environ.get('CLIENT_TEST_MODE', '')
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def pause():
    (root / 'paused').touch()
    deadline = time.monotonic() + 15
    while not (root / 'release').exists():
        if time.monotonic() > deadline: raise RuntimeError('test release timeout')
        time.sleep(0.02)

if name == 'rm':
    code = subprocess.run(['/bin/rm', *args]).returncode
    if mode == 'pause_cleanup' and any(a.endswith('/.update.lock') for a in args):
        pause()
    sys.exit(code)
if name == 'curl':
    if mode == 'pause':
        pause()
    url = next(a for a in args if a.startswith('https://'))
    with (root / 'urls').open('a') as out: out.write(url + '\n')
    if url.endswith('/commits/main'):
        print(json.dumps({'sha': 'a' * 40}))
    else:
        assert '/'+ 'a' * 40 + '/' in url, url
        path = url.split('/' + 'a' * 40 + '/')[1]
        if mode == 'download': sys.exit(22)
        shutil.copyfile(repo / path, args[args.index('-o')+1])
elif name == 'install':
    cleaned=[]
    while args:
        arg=args.pop(0)
        if arg in ('-o','-g'): args.pop(0)
        else: cleaned.append(arg)
    sys.exit(subprocess.run(['/usr/bin/install', *cleaned]).returncode)
elif name == 'mv':
    counter = root / 'move_count'
    n = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(n))
    if mode == 'before' + str(n): sys.exit(1)
    result = subprocess.run(['/bin/mv', *args]).returncode
    if mode == 'signal2' and n == 2: os.kill(os.getppid(), signal.SIGTERM)
    if mode == 'after' + str(n) or (mode == 'recovery' and n == 3): sys.exit(1)
    sys.exit(result)
elif name == 'cp':
    if mode == 'recovery' and '.update-backup' in args[1]: sys.exit(1)
    sys.exit(subprocess.run(['/bin/cp', *args]).returncode)
# apt-get is a no-op: no package or system changes in these tests.
'''


@pytest.fixture
def installation(tmp_path):
    install = tmp_path / 'install'
    (install / 'bin').mkdir(parents=True)
    for name in ('keyport-client', 'keyport-client-update'):
        (install / 'bin' / name).write_text('original-' + name)
    (install / 'build-info.json').write_text(json.dumps({'version': '1.0.0', 'commit': 'b' * 40}))
    (install / 'keyport-client.conf').write_text('preserve-config')
    (tmp_path / 'links').mkdir()
    (tmp_path / 'os-release').write_text('ID=debian\n')
    shims = tmp_path / 'shims'
    shims.mkdir()
    for name in ('curl', 'install', 'mv', 'cp', 'apt-get', 'rm'):
        path = shims / name
        path.write_text(f'#!{sys.executable}\n' + SHIM)
        path.chmod(0o755)
    env = dict(os.environ, CLIENT_TEST_ROOT=str(tmp_path), CLIENT_TEST_REPO=str(ROOT), PATH=f'{shims}:{os.environ["PATH"]}')
    return tmp_path, install, env


def prepare_runner(installation, installer=False):
    root, install, env = installation
    path = 'clients/debian/keyport-client-install' if installer else 'clients/debian/bin/keyport-client-update'
    code = (ROOT / path).read_text().replace('/opt/keyport-client', str(install)).replace('/usr/local/sbin', str(root / 'links'))
    code = code.replace('/etc/os-release', str(root / 'os-release')).replace('if [[ "${EUID}" -ne 0 ]]; then', 'if false; then')
    runner = root / 'runner'
    runner.write_text(code)
    return runner


def run(installation, mode='', installer=False):
    runner = prepare_runner(installation, installer)
    env = installation[2]
    return subprocess.run(['bash', str(runner)], env=dict(env, CLIENT_TEST_MODE=mode), capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize('installer', [False, True])
def test_pinned_downloads_and_installed_metadata(installation, installer):
    root, install, _ = installation
    (install / '.update.lock').write_text('stale file from previous updater')
    result = run(installation, installer=installer)
    assert not (install / '.update.lock').exists()
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((install / 'build-info.json').read_text()) == {'version': (ROOT / 'VERSION').read_text().strip(), 'commit': 'a' * 40}
    assert (install / 'keyport-client.conf').read_text() == 'preserve-config'
    assert not (install / 'bin/build-info.json').exists()
    urls = (root / 'urls').read_text().splitlines()
    assert sum(u.endswith('/commits/main') for u in urls) == 1
    assert all('/' + 'a' * 40 + '/' in u for u in urls if not u.endswith('/commits/main'))


@pytest.mark.parametrize('mode', ['download','before1','before2','before3','after1','after2','after3','signal2'])
@pytest.mark.parametrize('legacy', [False, True])
def test_code_and_metadata_rollback(installation, mode, legacy):
    _, install, _ = installation
    meta = install / 'build-info.json'
    if legacy: meta.unlink()
    result = run(installation, mode)
    assert result.returncode != 0
    for name in ('keyport-client', 'keyport-client-update'):
        assert (install / 'bin' / name).read_text() == 'original-' + name
    if legacy: assert not meta.exists()
    else: assert json.loads(meta.read_text())['version'] == '1.0.0'
    assert not (install / '.update-backup').exists()
    assert not (install / '.update.lock').exists()


def test_failed_recovery_preserves_metadata_backup(installation):
    _, install, _ = installation
    result = run(installation, 'recovery')
    assert result.returncode != 0
    assert json.loads((install / '.update-backup/build-info.json').read_text())['version'] == '1.0.0'
    assert run(installation).returncode != 0


def test_fresh_install(installation):
    _, install, _ = installation
    for path in (install / 'bin').iterdir(): path.unlink()
    (install / 'build-info.json').unlink()
    (install / 'keyport-client.conf').unlink()
    result = run(installation, installer=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((install / 'build-info.json').read_text())['commit'] == 'a' * 40
    assert (install / 'keyport-client.conf').stat().st_mode & 0o777 == 0o600


def test_parallel_update_rejected(installation):
    _, install, _ = installation
    with (install / '.update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run(installation)
    assert result.returncode != 0
    assert 'another client install/update is running' in result.stderr
    assert (install / '.update.lock').exists(), 'must not unlink the legacy owner lock'


@pytest.mark.parametrize('mode', ['pause', 'pause_cleanup'])
@pytest.mark.parametrize('installer', [False, True])
def test_parallel_operations_during_work_and_lock_removal(installation, mode, installer):
    root, install, env = installation
    runner = prepare_runner(installation, installer)
    first = subprocess.Popen(['bash', str(runner)], env=dict(env, CLIENT_TEST_MODE=mode), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 15
        while not (root / 'paused').exists():
            assert first.poll() is None, 'first operation exited before synchronization point'
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert (install / '.update.lock').exists() == (mode == 'pause')
        second = subprocess.run(['bash', str(runner)], env=env, capture_output=True, text=True, timeout=10)
        assert second.returncode != 0
        assert 'another client install/update is running' in second.stderr
        assert (install / '.update.lock').exists() == (mode == 'pause')
    finally:
        (root / 'release').touch()
        output, errors = first.communicate(timeout=30)
    assert first.returncode == 0, output + errors
    assert not (install / '.update.lock').exists()
