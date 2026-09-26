import hashlib
import ipaddress
import os
import re

import pymysql
from flask import Flask, jsonify, request


app = Flask(__name__)

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
MAX_KEY_LENGTH = 4096
MAX_KEYS_PER_SCOPE = 1000


def get_db():
    return pymysql.connect(
        unix_socket=os.environ["DB_SOCKET"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        charset="ascii",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
    )


def error(name, status):
    return jsonify(error=name), status


def audit(db, scope_id, source, method, keyname, result):
    with db.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO audit
                (scope_id, source, method, keyname, result)
            VALUES
                (%s, %s, %s, %s, %s)
            """,
            (scope_id, source, method, keyname, result),
        )


def get_source_ip():
    value = request.headers.get("X-Keyport-Source-IP")

    if value is None:
        # Used for direct local testing. In production Gunicorn will only
        # listen on loopback and nginx will always overwrite this header.
        value = request.remote_addr

    try:
        return str(ipaddress.ip_address(value))
    except (ValueError, TypeError):
        return None


def get_bearer_token():
    value = request.headers.get("Authorization")

    if not value:
        return None

    parts = value.split()

    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None

    return parts[1]


def source_allowed(db, scope_id, source_ip):
    ip = ipaddress.ip_address(source_ip)

    with db.cursor() as cursor:
        cursor.execute(
            """
            SELECT source
            FROM sources
            WHERE scope_id = %s
            """,
            (scope_id,),
        )
        rows = cursor.fetchall()

    for row in rows:
        try:
            network = ipaddress.ip_network(row["source"], strict=False)
        except ValueError:
            app.logger.error(
                "Invalid source entry in database: scope_id=%s",
                scope_id,
            )
            continue

        if ip in network:
            return True

    return False


def authorize(db, scope_name, keyname, source_ip):
    token = get_bearer_token()

    if token is None:
        audit(
            db,
            None,
            source_ip,
            request.method,
            keyname,
            "UNAUTHORIZED",
        )
        return None, error("unauthorized", 401)

    try:
        token_bytes = token.encode("ascii")
    except UnicodeEncodeError:
        audit(
            db,
            None,
            source_ip,
            request.method,
            keyname,
            "UNAUTHORIZED",
        )
        return None, error("unauthorized", 401)

    api_key_hash = hashlib.sha256(token_bytes).digest()

    with db.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                s.id,
                s.name,
                s.state,
                s.lock_on_source_mismatch
            FROM credentials AS c
            JOIN scopes AS s
              ON s.id = c.scope_id
            WHERE c.api_key_hash = %s
            """,
            (api_key_hash,),
        )
        scope = cursor.fetchone()

    if scope is None:
        audit(
            db,
            None,
            source_ip,
            request.method,
            keyname,
            "UNAUTHORIZED",
        )
        return None, error("unauthorized", 401)

    if scope["name"] != scope_name:
        audit(
            db,
            scope["id"],
            source_ip,
            request.method,
            keyname,
            "SCOPE_MISMATCH",
        )
        return None, error("forbidden", 403)

    if scope["state"] != "ACTIVE":
        audit(
            db,
            scope["id"],
            source_ip,
            request.method,
            keyname,
            scope["state"],
        )
        return None, error("forbidden", 403)

    if not source_allowed(db, scope["id"], source_ip):
        if scope["lock_on_source_mismatch"]:
            with db.cursor() as cursor:
                cursor.execute(
                    """
                    UPDATE scopes
                    SET state = 'LOCKED'
                    WHERE id = %s
                      AND state = 'ACTIVE'
                    """,
                    (scope["id"],),
                )

            audit(
                db,
                scope["id"],
                source_ip,
                request.method,
                keyname,
                "SOURCE_MISMATCH_LOCKED",
            )
        else:
            audit(
                db,
                scope["id"],
                source_ip,
                request.method,
                keyname,
                "SOURCE_MISMATCH",
            )

        return None, error("forbidden", 403)

    return scope, None


@app.get("/health")
def health():
    return jsonify(status="ok"), 200


@app.get("/key/<scope_name>")
def key_list(scope_name):
    if not NAME_RE.fullmatch(scope_name):
        return error("bad_request", 400)

    source_ip = get_source_ip()

    if source_ip is None:
        return error("bad_request", 400)

    db = None

    try:
        db = get_db()

        scope, auth_error = authorize(
            db,
            scope_name,
            None,
            source_ip,
        )

        if auth_error is not None:
            db.commit()
            return auth_error

        with db.cursor() as cursor:
            cursor.execute(
                """
                SELECT keyname
                FROM `keys`
                WHERE scope_id = %s
                ORDER BY keyname
                """,
                (scope["id"],),
            )
            rows = cursor.fetchall()

        audit(
            db,
            scope["id"],
            source_ip,
            request.method,
            None,
            "OK",
        )

        db.commit()
        return jsonify(keys=[row["keyname"] for row in rows]), 200

    except Exception:
        if db is not None:
            try:
                db.rollback()
            except Exception:
                pass

        app.logger.exception("Request failed")
        return error("service_unavailable", 503)

    finally:
        if db is not None:
            try:
                db.close()
            except Exception:
                pass


@app.route("/key/<scope_name>/<keyname>", methods=["GET", "POST", "DELETE"])
def key(scope_name, keyname):
    if not NAME_RE.fullmatch(scope_name) or not NAME_RE.fullmatch(keyname):
        return error("bad_request", 400)

    source_ip = get_source_ip()

    if source_ip is None:
        return error("bad_request", 400)

    db = None

    try:
        db = get_db()

        scope, auth_error = authorize(
            db,
            scope_name,
            keyname,
            source_ip,
        )

        if auth_error is not None:
            db.commit()
            return auth_error

        if request.method == "GET":
            with db.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT keyvalue
                    FROM `keys`
                    WHERE scope_id = %s
                      AND keyname = %s
                    """,
                    (scope["id"], keyname),
                )
                row = cursor.fetchone()

            if row is None:
                audit(
                    db,
                    scope["id"],
                    source_ip,
                    request.method,
                    keyname,
                    "NOT_FOUND",
                )
                db.commit()
                return error("not_found", 404)

            audit(
                db,
                scope["id"],
                source_ip,
                request.method,
                keyname,
                "OK",
            )

            # Audit must be durable before key material is released.
            db.commit()

            return jsonify(key=row["keyvalue"]), 200

        if request.method == "POST":
            if not request.is_json:
                db.rollback()
                return error("bad_request", 400)

            body = request.get_json(silent=True)

            if not isinstance(body, dict):
                db.rollback()
                return error("bad_request", 400)

            if set(body.keys()) != {"key"}:
                db.rollback()
                return error("bad_request", 400)

            keyvalue = body["key"]

            if not isinstance(keyvalue, str) or not keyvalue:
                db.rollback()
                return error("bad_request", 400)

            if len(keyvalue) > MAX_KEY_LENGTH:
                db.rollback()
                return error("too_large", 413)

            try:
                keyvalue.encode("ascii")
            except UnicodeEncodeError:
                db.rollback()
                return error("bad_request", 400)

            with db.cursor() as cursor:
                # Serialize key creation within a scope so concurrent requests
                # cannot exceed MAX_KEYS_PER_SCOPE.
                cursor.execute(
                    """
                    SELECT id
                    FROM scopes
                    WHERE id = %s
                    FOR UPDATE
                    """,
                    (scope["id"],),
                )

                cursor.execute(
                    """
                    SELECT 1
                    FROM `keys`
                    WHERE scope_id = %s
                      AND keyname = %s
                    """,
                    (scope["id"], keyname),
                )
                key_exists = cursor.fetchone() is not None

                if not key_exists:
                    cursor.execute(
                        """
                        SELECT COUNT(*) AS key_count
                        FROM `keys`
                        WHERE scope_id = %s
                        """,
                        (scope["id"],),
                    )
                    row = cursor.fetchone()

                    if row["key_count"] >= MAX_KEYS_PER_SCOPE:
                        audit(
                            db,
                            scope["id"],
                            source_ip,
                            request.method,
                            keyname,
                            "KEY_LIMIT_REACHED",
                        )
                        db.commit()
                        return error("key_limit_reached", 409)

                cursor.execute(
                    """
                    INSERT INTO `keys`
                        (scope_id, keyname, keyvalue)
                    VALUES
                        (%s, %s, %s)
                    ON DUPLICATE KEY UPDATE
                        keyvalue = VALUES(keyvalue)
                    """,
                    (scope["id"], keyname, keyvalue),
                )

            audit(
                db,
                scope["id"],
                source_ip,
                request.method,
                keyname,
                "OK",
            )

            db.commit()
            return "", 204

        with db.cursor() as cursor:
            cursor.execute(
                """
                DELETE FROM `keys`
                WHERE scope_id = %s
                  AND keyname = %s
                """,
                (scope["id"], keyname),
            )

        audit(
            db,
            scope["id"],
            source_ip,
            request.method,
            keyname,
            "OK",
        )

        db.commit()
        return "", 204

    except Exception:
        if db is not None:
            try:
                db.rollback()
            except Exception:
                pass

        app.logger.exception("Request failed")
        return error("service_unavailable", 503)

    finally:
        if db is not None:
            try:
                db.close()
            except Exception:
                pass
