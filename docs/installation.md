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

The server updater additionally requires `curl`, `tar`, `sha256sum`, and `flock` (from `util-linux`).

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

Install the filter and jail with these exact names (`filter = keyport`
requires `filter.d/keyport.conf`):

```bash
sudo install -m 0644 server/config/fail2ban/filter.conf /etc/fail2ban/filter.d/keyport.conf
sudo install -m 0644 server/config/fail2ban/jail.conf /etc/fail2ban/jail.d/keyport.conf
sudo fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/keyport.conf
sudo fail2ban-client -t
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
nginx/TLS. `/health` checks process liveness only. The local updater uses
`http://127.0.0.1:8000/ready` to check database connectivity and the columns
required by the API. `/ready` rejects non-loopback or proxied requests and is
not exposed by the reference nginx configuration. It does not read key values
or prove write permissions, audit durability, or full API correctness.

Use a temporary scope and credential to test missing and invalid credentials,
an allowed source, an unexpected source, a missing key, key listing,
POST/GET/DELETE, the 1000-key scope limit, and scope lock/unlock behavior.

Do not deliberately trigger security bans from an administrative address
unless recovery access has been planned.

## Server updater

`server/bin/keyport-update` updates an existing Keyport installation from the current
`main` branch of the Keyport repository.

It is intended for an already configured server. It is not a general-purpose
server installer.

The updater manages:

```text
/opt/keyport/app
/opt/keyport/bin
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
curl -fsSL https://raw.githubusercontent.com/aspanta/keyport/main/server/bin/keyport-update | sudo bash
```

An already installed older updater runs its own existing logic during its first
upgrade. To use the new recovery and readiness checks for that upgrade itself,
run the current updater using the bootstrap command above.

After a successful update, the updater installs itself as:

```text
/opt/keyport/bin/keyport-update
```

and creates:

```text
/usr/local/sbin/keyport-update -> /opt/keyport/bin/keyport-update
```

Subsequent updates can therefore be run with:

```bash
sudo keyport-update
```

## Update process

The updater:

1. resolves `main` to a full commit SHA and downloads that immutable snapshot;
2. validates the downloaded application, administration CLI, and updater;
3. connects to the configured Keyport database;
4. bootstraps migration tracking if necessary;
5. verifies checksums of previously applied migrations;
6. applies pending migrations in lexical order;
7. stages complete replacement `app/` and `bin/` trees;
8. stops the service and switches the deployed application trees;
9. restarts `keyport.service`;
10. verifies local `/ready` and checks that its version and SHA match the downloaded build;
11. keeps the updater as part of the managed `bin/` tree; rollback restores the previous updater together with that tree.

Because complete `app/` and `bin/` trees are replaced, files added to the
repository are deployed automatically and files removed from the repository
are removed from the deployed trees.

## Application rollback

Before switching application files, the updater preserves the previous
`app/` and `bin/` trees.

The updater holds an exclusive lock for the entire update, including migrations.
After deployment starts, errors and handled `INT`/`TERM` signals trigger an
attempt to restore the previous application and start it. Each original tree
is restored only if its backup exists, including failures between renames.
Readiness failure also triggers this recovery.

If restoration or startup fails, `.app.old` and `.bin.old` are retained under
`/opt/keyport`. A subsequent update refuses to proceed while either backup
exists. `SIGKILL`, power loss, and filesystem failures may require manual
recovery; shell traps cannot guarantee recovery in these cases.

For manual recovery, stop the service and ensure no updater is running. Preserve
the remaining backup directories before changing files. Restore each available
backup to its corresponding `app` or `bin` directory, keeping an intact copy
until the restored service and API have been verified. Remove the `.old`
directories only after successful recovery. Do not delete `.update.lock` to
bypass a running update; an unused lock file can remain in place.

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

## Installed version metadata

The release number comes from the root `VERSION` file in the same commit as
the downloaded code. The updater writes `/opt/keyport/app/build-info.json`
with `version` and the full 40-character `commit`. It is generated metadata,
not a source file, and is restored with the `app/` tree during rollback.
`keyport -v`, `keyport-update -v`, `/health`, and `/ready` read this metadata.
CLI output abbreviates the commit to 12 characters; the API returns the full SHA.

For a manual initial deployment from a clean Git checkout, generate metadata
before copying `server/app/` into place:

```bash
python3 - <<'PY_BUILD'
import json, subprocess
from pathlib import Path
if subprocess.check_output(["git", "status", "--porcelain"], text=True).strip():
    raise SystemExit("use a clean checkout to generate deployment metadata")
info = {"version": Path("VERSION").read_text().strip(),
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()}
Path("server/app/build-info.json").write_text(json.dumps(info) + "\n")
PY_BUILD
```

Deploy the generated file with the same read permissions as the other application
files. Without it, legacy/manual installs report `unknown`; no runtime request to
GitHub is made to guess their version. The first run of an older installed updater
uses its existing logic, so run the current updater directly for an upgrade that
must include metadata immediately.
