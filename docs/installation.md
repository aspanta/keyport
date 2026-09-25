# Server Installation and Updating

This document describes the reference Keyport server layout. Review paths,
hostname, TLS configuration, database credentials, and operating-system policy
before using it on another host.

## Reference paths

Application installation:

```text
/opt/keyport
```

Persistent service home/state:

```text
/var/lib/keyport
```

The service should run from a deployed installation tree, not directly from a
Git working copy.

## Required components

The reference deployment uses Python 3, Flask, Gunicorn, PyMySQL, MariaDB,
nginx, systemd, and Fail2ban.

The server updater additionally requires `curl`, `tar`, and `sha256sum`.

## Service account

Use a dedicated `keyport` system account with `/var/lib/keyport` as its home
and `/usr/sbin/nologin` as its shell.

The application installation under `/opt/keyport` should not be writable by
the service account.

## Python environment

Create a virtual environment at `/opt/keyport/venv` and install Flask,
Gunicorn, and PyMySQL.

## Application files

Deploy the server application under:

```text
/opt/keyport/app
```

and the administration tools under:

```text
/opt/keyport/bin
```

The administration command may be exposed with:

```text
/usr/local/sbin/keyport -> /opt/keyport/bin/keyport
```

Application files should be owned by an administrative account such as `root`,
not by the `keyport` service account.

## Configuration

Copy `server/config/keyport.conf.example` to:

```text
/opt/keyport/keyport.conf
```

Configure:

```text
DB_SOCKET
DB_NAME
DB_USER
DB_PASSWORD
```

The configuration contains a database password and must not be committed to
Git. Restrict its permissions so that only the administrator and Keyport
service account can read it.

## Database

Create a MariaDB database and account for Keyport and import:

```text
server/sql/schema.sql
```

The reference application connects through the local MariaDB Unix socket.

A new database created from `schema.sql` also contains the
`schema_migrations` table used by the server updater.

## systemd

Install:

```text
server/config/keyport.service
```

as:

```text
/etc/systemd/system/keyport.service
```

The reference unit runs as the dedicated `keyport` user, starts Gunicorn on
`127.0.0.1:8000`, disables the Gunicorn control socket, applies a restrictive
systemd sandbox, and allows application writes only under `/var/lib/keyport`.

## nginx

`server/config/nginx-rate-limit.conf` defines the shared rate-limit zone and
belongs in the nginx `http` context, for example under `/etc/nginx/conf.d/`.

`server/config/nginx-site.conf` defines the Keyport HTTP/HTTPS virtual host.
The reference hostname is `keyport.asp.app`; change it for another deployment.

The HTTPS site requires an existing TLS certificate and private key. Always
validate nginx configuration before reloading it.

## Fail2ban

Install `server/config/fail2ban/filter.conf` under:

```text
/etc/fail2ban/filter.d/
```

and `server/config/fail2ban/jail.conf` under:

```text
/etc/fail2ban/jail.d/
```

The reference jail watches nginx access logs for repeated 401 and 429
responses on Keyport key endpoints. Validate Fail2ban configuration before
restarting or reloading it.

## Initial configuration

```bash
keyport scope add example
keyport source add example 203.0.113.10
keyport credential add example
```

Save the displayed API key securely on the client.

## Verification

Verify the local application health endpoint and then the same endpoint through
nginx/TLS.

Use a temporary scope and credential to test missing and invalid credentials,
an allowed source, an unexpected source, a missing key, POST/GET/DELETE, and
scope lock/unlock behavior.

Do not deliberately trigger security bans from an administrative address
unless recovery access has been planned.

## Server updater

`server/update.sh` updates an existing Keyport installation from the current
`main` branch of the Keyport repository.

It is intended for an already configured server. It is not a general-purpose
server installer.

The updater manages:

```text
/opt/keyport/app
/opt/keyport/bin
/opt/keyport/update.sh
```

and database migrations under:

```text
server/sql/migrations/
```

It does not automatically modify:

```text
/opt/keyport/keyport.conf
/opt/keyport/venv
/etc/systemd/system/keyport.service
nginx configuration
Fail2ban configuration
TLS certificates or configuration
```

Reference configuration files in `server/config/` therefore remain
administrator-managed.

## Installing the updater

On an existing Keyport server, the updater can initially be run directly from
the `main` branch:

```bash
curl -fsSL https://raw.githubusercontent.com/aspanta/keyport/main/server/update.sh | sudo bash
```

After a successful update, the updater installs itself as:

```text
/opt/keyport/update.sh
```

and creates:

```text
/usr/local/sbin/keyport-update -> /opt/keyport/update.sh
```

Subsequent updates can therefore be run with:

```bash
sudo keyport-update
```

## Update process

The updater:

1. downloads a snapshot of the current `main` branch;
2. validates the downloaded application, administration CLI, and updater;
3. connects to the configured Keyport database;
4. bootstraps migration tracking if necessary;
5. verifies checksums of previously applied migrations;
6. applies pending migrations in lexical order;
7. stages complete replacement `app/` and `bin/` trees;
8. switches the deployed application trees;
9. restarts `keyport.service`;
10. verifies the local `/health` endpoint;
11. installs the new updater after the application has passed its health check.

Because complete `app/` and `bin/` trees are replaced, files added to the
repository are deployed automatically and files removed from the repository
are removed from the deployed trees.

## Application rollback

Before switching application files, the updater preserves the previous
`app/` and `bin/` trees.

If the new service fails to restart or fails the health check, the updater
restores the previous application trees and attempts to start the previous
application.

Database migrations are not automatically rolled back.

## Database migrations

Changes to an existing database schema belong in:

```text
server/sql/migrations/
```

Migration filenames use the form:

```text
NNN-description.sql
```

For example:

```text
001-add-example-column.sql
002-create-example-table.sql
```

Migration filenames must match:

```text
^[0-9]{3}-[a-z0-9][a-z0-9-]*\.sql$
```

Applied migrations are recorded in the `schema_migrations` table together with
their SHA-256 checksum.

An applied migration file must never be modified. If the checksum of an
already applied migration differs from the repository version, the updater
stops.

Migrations must be designed to remain compatible with the previously deployed
application. MariaDB DDL can perform implicit commits, so arbitrary schema
changes cannot be treated as transactionally rollbackable by the updater.

Prefer additive changes first, such as creating a new table, adding a new
column, or adding an index. Destructive changes such as removing or renaming
objects should be performed only in a later migration after deployed
application versions no longer depend on them.

`server/sql/schema.sql` remains the complete schema for a new installation.
Existing installations are changed through migrations rather than by
re-importing `schema.sql`.
