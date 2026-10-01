import getpass
import io
import runpy
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def client():
    return runpy.run_path(str(ROOT / 'clients/debian/bin/keyport-client'))


class Terminal(io.StringIO):
    def isatty(self):
        return True


@pytest.mark.parametrize('name', ['example', None])
def test_interactive_push(client, monkeypatch, name):
    monkeypatch.setattr('sys.stdin', Terminal('example\n'))
    monkeypatch.setattr(getpass, 'getpass', lambda prompt: ' paßword ')
    assert client['read_push_input'](name) == ('example', ' paßword '.encode())


@pytest.mark.parametrize('data', [b'\x00\xff\r\n', b'', b'x' * 3041])
def test_pipe_preserves_bytes(client, monkeypatch, data):
    monkeypatch.setattr('sys.stdin', io.TextIOWrapper(io.BytesIO(data)))
    monkeypatch.setattr(getpass, 'getpass', lambda _: pytest.fail('prompt in pipeline'))
    assert client['read_push_input']('example') == ('example', data)


def test_pipe_without_name_does_not_read(client, monkeypatch):
    stream = io.TextIOWrapper(io.BytesIO(b'secret'))
    monkeypatch.setattr('sys.stdin', stream)
    with pytest.raises(client['KeyportError'], match='keyname is required'):
        client['read_push_input'](None)
    assert stream.buffer.tell() == 0


@pytest.mark.parametrize('password', ['', 'é' * 1521])
def test_invalid_password(client, monkeypatch, password):
    monkeypatch.setattr('sys.stdin', Terminal())
    monkeypatch.setattr(getpass, 'getpass', lambda _: password)
    with pytest.raises(client['KeyportError']):
        client['read_push_input']('example')


@pytest.mark.parametrize('error', [EOFError(), getpass.GetPassWarning(), KeyboardInterrupt()])
def test_cancelled_or_insecure_prompt(client, monkeypatch, error):
    monkeypatch.setattr('sys.stdin', Terminal())
    def prompt(_):
        raise error
    monkeypatch.setattr(getpass, 'getpass', prompt)
    expected = KeyboardInterrupt if isinstance(error, KeyboardInterrupt) else client['KeyportError']
    with pytest.raises(expected):
        client['read_push_input']('example')


def test_push_limit(client, monkeypatch):
    monkeypatch.setattr('sys.stdin', io.TextIOWrapper(io.BytesIO(b'x' * 3042)))
    with pytest.raises(client['KeyportError'], match='maximum size'):
        client['read_push_input']('example')


def test_invalid_name_before_prompt(client, monkeypatch):
    monkeypatch.setattr('sys.stdin', Terminal())
    monkeypatch.setattr(getpass, 'getpass', lambda _: pytest.fail('prompt before validation'))
    with pytest.raises(client['KeyportError']):
        client['read_push_input']('-bad')


def test_push_optional_name(client):
    parser = client['build_parser']()
    assert parser.parse_args(['push']).keyname is None
    assert parser.parse_args(['push', 'example']).keyname == 'example'


@pytest.fixture
def admin():
    return runpy.run_path(str(ROOT / 'server/bin/keyport'))


def test_audit_scoped_bounded_read_only(admin, monkeypatch, capsys):
    command = admin['cmd_audit']
    db = MagicMock()
    db.__enter__.return_value = db
    cursor = db.cursor.return_value.__enter__.return_value
    cursor.fetchone.return_value = {'id': 42}
    cursor.fetchall.return_value = [dict(id=9, created_at='2026-10-01 12:00:00', source='10.0.0.1', method='GET', keyname=None, result='OK')]
    monkeypatch.setitem(command.__globals__, 'get_db', lambda: db)
    args = admin['build_parser']().parse_args(['audit', 'example'])
    args.func(args)
    calls = cursor.execute.call_args_list
    assert calls[0].args[1] == ('example',)
    sql, params = calls[1].args
    assert params == (42,)
    assert 'WHERE scope_id = %s' in sql
    assert 'ORDER BY created_at DESC, id DESC' in sql
    assert 'LIMIT 1000' in sql
    assert 'keyvalue' not in sql
    assert len(calls) == 2
    db.commit.assert_not_called()
    output = capsys.readouterr().out
    assert '10.0.0.1' in output and 'OK' in output


def test_missing_scope_never_queries_audit(admin, monkeypatch):
    command = admin['cmd_audit']
    db = MagicMock()
    db.__enter__.return_value = db
    cursor = db.cursor.return_value.__enter__.return_value
    cursor.fetchone.return_value = None
    monkeypatch.setitem(command.__globals__, 'get_db', lambda: db)
    with pytest.raises(SystemExit):
        command(SimpleNamespace(scope='absent'))
    assert cursor.execute.call_count == 1


def test_invalid_scope_never_connects(admin, monkeypatch):
    command = admin['cmd_audit']
    monkeypatch.setitem(command.__globals__, 'get_db', lambda: pytest.fail('connected'))
    with pytest.raises(SystemExit):
        command(SimpleNamespace(scope="bad'"))
