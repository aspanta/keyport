"""Run the actual updater in a temporary installation with command fault injection."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tarfile

import pytest

ROOT = Path(__file__).resolve().parents[1]
SHIM = r'''
import os, pathlib, shutil, signal, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['UPDATE_TEST_ROOT'])
mode = os.environ.get('UPDATE_TEST_MODE', '')
with (root / 'commands').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\n')
if name == 'curl':
    if '--output' in args:
        shutil.copyfile(root / 'source.tar.gz', args[args.index('--output') + 1])
    elif (mode == 'readiness' and args[-1].endswith('/ready')) or mode == 'rollback_health':
        sys.exit(22)
elif name == 'mariadb':
    if not any(a.startswith('--execute=') for a in args):
        sys.stdin.read()
elif name == 'systemctl':
    if args[0] == 'restart' and mode == 'restart':
        sys.exit(1)
    if args[0] == 'start' and mode == 'rollback_start':
        sys.exit(1)
    if args[0] == 'restart' and mode == 'rollback_start':
        sys.exit(1)
elif name == 'mv':
    counter = root / 'move_count'
    n = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(n))
    if mode in ('move' + str(n), 'restore' + str(n)):
        sys.exit(1)
    result = subprocess.run(['/bin/mv', *args]).returncode
    if mode == 'signal' + str(n):
        os.kill(os.getppid(), signal.SIGTERM)
    if mode == 'interrupt' + str(n):
        os.kill(os.getppid(), signal.SIGINT)
    sys.exit(result)
elif name == 'cp':
    if mode.startswith('restore') and any(a.endswith('.app.old') for a in args):
        sys.exit(1)
    sys.exit(subprocess.run(['/bin/cp', *args]).returncode)
# chown and sleep are intentionally harmless no-ops.
'''


@pytest.fixture
def installation(tmp_path):
    install = tmp_path / 'install'
    for name in ('app', 'bin'):
        (install / name).mkdir(parents=True)
        (install / name / 'original').write_text(name)
    (install / 'keyport.conf').write_text('DB_SOCKET=/fake.sock\nDB_NAME=keyport\nDB_USER=test\nDB_PASSWORD=test\n')
    with tarfile.open(tmp_path / 'source.tar.gz', 'w:gz') as archive:
        archive.add(ROOT / 'server', arcname='keyport/server')
    shims = tmp_path / 'shims'
    shims.mkdir()
    for name in ('curl', 'mariadb', 'systemctl', 'mv', 'cp', 'chown', 'sleep'):
        target = shims / name
        target.write_text(f'#!{sys.executable}\n' + SHIM)
        target.chmod(0o755)
    links = tmp_path / 'links'
    links.mkdir()
    # Only relocate paths and the root precondition; exercise the production
    # updater's control flow, traps, locking, copies, and filesystem renames.
    script = (ROOT / 'server/bin/keyport-update').read_text()
    script = script.replace('/opt/keyport', str(install)).replace('/usr/local/sbin', str(links))
    script = script.replace('if [[ "${EUID}" -ne 0 ]]; then', 'if false; then')
    runner = tmp_path / 'updater'
    runner.write_text(script)
    env = dict(os.environ, UPDATE_TEST_ROOT=str(tmp_path), PATH=f'{shims}:{os.environ["PATH"]}')
    return tmp_path, install, runner, env


def run(installation, mode=''):
    root, install, runner, env = installation
    return subprocess.run(['bash', str(runner)], env=dict(env, UPDATE_TEST_MODE=mode), capture_output=True, text=True, timeout=30)


def assert_original(install):
    for name in ('app', 'bin'):
        assert (install / name / 'original').read_text() == name
        assert not (install / f'.{name}.old').exists()


def test_success(installation):
    root, install, _, _ = installation
    result = run(installation)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (install / 'app/app.py').is_file()
    assert (install / 'bin/keyport').is_file()
    assert not (install / '.app.old').exists()
    assert '/ready' in (root / 'commands').read_text()


@pytest.mark.parametrize('mode', ['move1', 'move2', 'move3', 'move4', 'restart', 'readiness', 'signal1', 'signal2', 'signal3', 'signal4', 'interrupt3'])
def test_failure_restores_original(installation, mode):
    result = run(installation, mode)
    assert result.returncode != 0
    assert_original(installation[1])


@pytest.mark.parametrize('mode', ['restore4', 'rollback_start', 'rollback_health'])
def test_failed_recovery_keeps_backups_and_blocks_next_update(installation, mode):
    _, install, _, _ = installation
    result = run(installation, mode)
    assert result.returncode != 0
    assert (install / '.app.old/original').read_text() == 'app'
    assert (install / '.bin.old/original').read_text() == 'bin'
    retry = run(installation)
    assert retry.returncode != 0
    assert 'recovery required' in retry.stderr
    assert (install / '.app.old/original').read_text() == 'app'


def test_parallel_update_rejected(installation):
    _, install, _, _ = installation
    with (install / '.update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run(installation)
    assert result.returncode != 0
    assert 'another update is already running' in result.stderr
    assert_original(install)
