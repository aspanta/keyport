# Keyport

Keyport is a small key-release service for unattended systems that need to
retrieve encrypted key material from a remote server.

Keyport stores opaque values. It does not know what a stored value represents
and does not perform client-side decryption. In the reference client,
automation key material is encrypted locally before upload. The Key Encryption
Key (KEK) remains on the client and is never sent to Keyport.

## Design goals

- Small and auditable server-side implementation
- No plaintext automation keys on the Keyport server
- No client KEK on the Keyport server
- Independent security scopes
- Per-scope API credentials
- Per-scope IPv4/IPv6 source allow-lists
- Optional automatic scope locking on source mismatch
- Fail-closed audit logging for key operations
- Minimal externally exposed attack surface
- Simple local administration CLI
- Client-side authenticated encryption

## Reference architecture

```text
Client
  |
  | AES-256-GCM encryption/decryption
  | KEK remains local
  |
  +---- HTTPS ----> nginx :443
                       |
                       +---- loopback ----> Gunicorn/Flask :8000
                                                |
                                                +---- Unix socket ----> MariaDB
```

The reference server deployment also uses Fail2ban and a hardened systemd
service.

## Repository layout

```text
server/
├── app/
│   └── app.py
├── bin/
│   └── keyport
├── config/
│   ├── fail2ban/
│   │   ├── filter.conf
│   │   └── jail.conf
│   ├── keyport.conf.example
│   ├── keyport.service
│   ├── nginx-rate-limit.conf
│   └── nginx-site.conf
├── sql/
│   ├── migrations/
│   └── schema.sql
└── update.sh

clients/
└── debian/
    ├── README.md
    ├── install.sh
    ├── keyport-client
    ├── keyport-client.conf.example
    └── update.sh

docs/
├── api.md
├── architecture.md
├── cli.md
├── installation.md
└── security.md
```

## Server

The Keyport server provides authenticated storage of opaque values organized
into security scopes.

Key operations use:

```text
/key/{scope}/{keyname}
```

with Bearer authentication.

- `GET` retrieves an opaque value.
- `POST` creates or replaces an opaque value.
- `DELETE` removes an opaque value.

See [HTTP API](docs/api.md).

## Server updates

An existing Keyport server can be updated from the `main` branch with the
server updater.

After the updater has been installed:

```bash
sudo keyport-update
```

The updater downloads the current repository snapshot, validates it, applies
pending database migrations, replaces the deployed `app/` and `bin/` trees,
restarts Keyport, and verifies the local health endpoint.

Application files are rolled back if the updated service fails to start or
fails its health check. Database migrations are not automatically rolled back.

Local infrastructure configuration such as `keyport.conf`, systemd, nginx,
Fail2ban, and TLS configuration is not modified by the updater.

See [Server installation and updating](docs/installation.md).

## Debian client

The reference Debian client encrypts and decrypts key material locally using
AES-256-GCM.

The client provides:

```text
keyport-client
├── get <keyname>
├── push <keyname>
├── create <keyname> [--length N] [--push]
├── delete <keyname>
└── kek
    └── generate
```

`push` and `get` are binary-safe. The client never sends its KEK to the
Keyport server.

See [Debian client](clients/debian/README.md).

## Administration

Server administration is performed locally with the `keyport` CLI.

```bash
keyport scope list
keyport scope show example
keyport source list example
keyport source add example 203.0.113.10
keyport credential list example
keyport credential add example
```

See [Administration CLI](docs/cli.md).

## Security model

The design separates:

- the plaintext automation key
- the encrypted value stored by Keyport
- the API credential
- the client-side KEK
- an independent offline recovery credential

The API credential authorizes access to a scope but is not sufficient to
decrypt correctly client-encrypted values. The KEK remains on the client.

Compromise of the Keyport database alone should therefore not reveal plaintext
automation key material when client-side encryption and the KEK remain secure.

Keyport is not intended to replace an independent recovery mechanism for
encrypted data.

See [Security](docs/security.md).

## Documentation

- [Architecture](docs/architecture.md)
- [HTTP API](docs/api.md)
- [Administration CLI](docs/cli.md)
- [Server installation and updating](docs/installation.md)
- [Security](docs/security.md)
- [Debian client](clients/debian/README.md)

## License

Copyright 2026 Aspanta Limited.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for
details.
