"""Exercise Flask routing and authorization with a transactional SQLite test double.

This is not a substitute for deployment verification against MariaDB.
"""
import hashlib
import importlib.util
import sqlite3
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("keyport_app", ROOT / "server/app/app.py")
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)
TOKEN = "test-token"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}


class Connection:
    def __init__(self, path, fail_audit=False):
        self.raw = sqlite3.connect(path)
        self.raw.row_factory = sqlite3.Row
        self.fail_audit = fail_audit

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def execute(self, sql, params=()):
        if self.fail_audit and "INSERT INTO audit" in sql:
            raise RuntimeError("simulated audit failure")
        sql = sql.replace("%s", "?").replace("FOR UPDATE", "")
        sql = sql.replace("ON DUPLICATE KEY UPDATE", "ON CONFLICT(scope_id, keyname) DO UPDATE SET")
        sql = sql.replace("VALUES(keyvalue)", "excluded.keyvalue")
        self.result = self.raw.execute(sql, params)

    def fetchone(self):
        row = self.result.fetchone()
        return dict(row) if row is not None else None

    def fetchall(self):
        return [dict(row) for row in self.result.fetchall()]

    def commit(self):
        self.raw.commit()

    def rollback(self):
        self.raw.rollback()

    def close(self):
        self.raw.close()


@pytest.fixture
def service(tmp_path, monkeypatch):
    path = tmp_path / "db.sqlite"
    with sqlite3.connect(path) as db:
        db.executescript("""
            CREATE TABLE scopes (id INTEGER PRIMARY KEY, name TEXT, state TEXT, lock_on_source_mismatch INTEGER);
            CREATE TABLE credentials (scope_id INTEGER, api_key_hash BLOB);
            CREATE TABLE sources (scope_id INTEGER, source TEXT);
            CREATE TABLE keys (scope_id INTEGER, keyname TEXT, keyvalue TEXT, UNIQUE(scope_id, keyname));
            CREATE TABLE audit (scope_id INTEGER, source TEXT, method TEXT, keyname TEXT, result TEXT);
            INSERT INTO scopes VALUES (1, 'test', 'ACTIVE', 1);
            INSERT INTO sources VALUES (1, '127.0.0.1');
            INSERT INTO keys VALUES (1, 'secret', 'encrypted-value');
        """)
        db.execute("INSERT INTO credentials VALUES (1, ?)", (hashlib.sha256(TOKEN.encode()).digest(),))
    monkeypatch.setattr(api, "get_db", lambda: Connection(path))
    api.app.config.update(TESTING=True)
    return api.app.test_client(), path


def stored(path):
    with sqlite3.connect(path) as db:
        return db.execute("SELECT keyvalue FROM keys WHERE keyname='secret'").fetchone()


@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_read_preserves_key_and_commits_audit(service, method):
    client, path = service
    response = client.open("/key/test/secret", method=method, headers=HEADERS)
    assert response.status_code == 200
    assert stored(path) == ("encrypted-value",)
    if method == "HEAD":
        assert response.data == b""
    else:
        assert response.json == {"key": "encrypted-value"}
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT method, result FROM audit").fetchall() == [(method, "OK")]


@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_missing_key(service, method):
    client, path = service
    assert client.open("/key/test/missing", method=method, headers=HEADERS).status_code == 404
    assert stored(path)


@pytest.mark.parametrize("method", ["GET", "HEAD", "POST", "DELETE"])
def test_authentication_required(service, method):
    client, path = service
    assert client.open("/key/test/secret", method=method).status_code == 401
    assert stored(path)


@pytest.mark.parametrize("method", ["GET", "HEAD", "POST", "DELETE"])
def test_locked_scope_denied(service, method):
    client, path = service
    with sqlite3.connect(path) as db:
        db.execute("UPDATE scopes SET state='LOCKED'")
    assert client.open("/key/test/secret", method=method, headers=HEADERS).status_code == 403
    assert stored(path)


def test_head_source_mismatch_locks_scope_without_deleting_key(service):
    client, path = service
    assert client.head("/key/test/secret", headers=HEADERS, environ_overrides={"REMOTE_ADDR": "192.0.2.1"}).status_code == 403
    assert stored(path)
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT state FROM scopes").fetchone() == ("LOCKED",)


@pytest.mark.parametrize("method", ["OPTIONS", "PUT", "PATCH"])
def test_other_methods_do_not_delete(service, method):
    client, path = service
    response = client.open("/key/test/secret", method=method, headers=HEADERS)
    assert response.status_code == (200 if method == "OPTIONS" else 405)
    assert stored(path)


def test_post_and_explicit_delete(service):
    client, path = service
    assert client.post("/key/test/secret", headers=HEADERS, json={"key": "replacement"}).status_code == 204
    assert stored(path) == ("replacement",)
    assert client.delete("/key/test/secret", headers=HEADERS).status_code == 204
    assert stored(path) is None


@pytest.mark.parametrize("method", ["GET", "HEAD", "DELETE", "POST"])
def test_audit_failure_fails_closed(service, monkeypatch, method):
    client, path = service
    monkeypatch.setattr(api, "get_db", lambda: Connection(path, fail_audit=True))
    response = client.open("/key/test/secret", method=method, headers=HEADERS, json={"key": "replacement"})
    assert response.status_code == 503
    assert b"encrypted-value" not in response.data
    assert stored(path) == ("encrypted-value",)


def test_readiness_success(service):
    client, path = service
    assert client.get("/ready").json == {"status": "ready", **api.BUILD_INFO}
    assert stored(path)


@pytest.mark.parametrize("failure", ["connection", "schema"])
def test_readiness_failure_does_not_break_liveness(service, monkeypatch, failure):
    client, path = service
    if failure == "connection":
        def unavailable():
            raise RuntimeError("database unavailable")
        monkeypatch.setattr(api, "get_db", unavailable)
    else:
        with sqlite3.connect(path) as db:
            db.execute("DROP TABLE audit")
    assert client.get("/ready").status_code == 503
    assert client.get("/health").status_code == 200


@pytest.mark.parametrize("headers,remote", [({}, "192.0.2.1"), ({"X-Keyport-Source-IP": "127.0.0.1"}, "127.0.0.1")])
def test_readiness_is_local_only(service, headers, remote):
    client, _ = service
    assert client.get("/ready", headers=headers, environ_overrides={"REMOTE_ADDR": remote}).status_code == 404


def test_health_and_readiness_report_loaded_revision(service, monkeypatch):
    client, _ = service
    info = {"version": "1.2.0", "commit": "a" * 40}
    monkeypatch.setattr(api, "BUILD_INFO", info)
    assert client.get("/health").json == {"status": "ok", **info}
    assert client.get("/ready").json == {"status": "ready", **info}
