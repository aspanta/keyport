# HTTP API

## Resource

Key operations use:

```text
/key/{scope}/{keyname}
```

Both `scope` and `keyname` must match:

```text
^[a-z0-9][a-z0-9_-]{0,63}$
```

## Authentication

Requests use Bearer authentication:

```http
Authorization: Bearer <API_KEY>
```

Credentials belong to a single scope. The database stores only the SHA-256 digest of the API key.

## Source authorization

In the reference deployment nginx sets `X-Keyport-Source-IP` from `$remote_addr`. Clients must not be allowed to control this trusted header. The resulting address must match a source address or CIDR configured for the scope.

## GET

```http
GET /key/example/diskkey
Authorization: Bearer <API_KEY>
```

A successful request returns `200 OK` with JSON containing the stored opaque value:

```json
{"key":"<opaque value>"}
```

A missing key returns `404 Not Found`.

## POST

```http
POST /key/example/diskkey
Authorization: Bearer <API_KEY>
Content-Type: application/json

{"key":"<opaque value>"}
```

The reference nginx configuration limits request bodies to 8 KiB. The application limits the opaque value to 4096 ASCII characters. A successful write returns `204 No Content`. Writing an existing `(scope, keyname)` replaces its current value; Keyport does not maintain value history.

## DELETE

```http
DELETE /key/example/diskkey
Authorization: Bearer <API_KEY>
```

Deletion is idempotent and returns `204 No Content`, including when the key is already absent.

## Health

The reference deployment exposes `/health` through nginx to the local application. It is intended for service health checks and does not perform key authorization.

## Scope states

Key operations require an `ACTIVE` scope. Requests against `LOCKED` or `DISABLED` scopes are rejected.

## Source mismatch locking

When `lock-on-source-mismatch` is enabled, presentation of a valid credential from outside the scope allow-list can lock the scope. Random or unknown API credentials do not cause scope locking.

## Rate limiting

The reference nginx configuration defines a `keyport_api` zone at 1 request/second per remote address and applies a burst of 5 to `/key/`, returning HTTP 429 when the limit is exceeded.

## Audit

Audit records contain operational metadata such as timestamp, scope reference when known, source address, HTTP method, key name when applicable, and result. They do not contain API keys or stored key values.
