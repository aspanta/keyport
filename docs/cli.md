# Administration CLI

The `keyport` command is the local administration interface.

```text
keyport
├── scope
│   ├── list
│   ├── show
│   ├── add
│   ├── delete
│   ├── lock
│   ├── unlock
│   ├── disable
│   ├── enable
│   └── set
├── source
│   ├── list
│   ├── add
│   └── delete
└── credential
    ├── list
    ├── add
    └── delete
```

Use `keyport --help`, `keyport scope --help`, `keyport source --help`, and `keyport credential --help` for command-specific help.

## Help and version

All installed commands provide `-h` / `--help` and `-v` / `--version`:

```bash
keyport -v
keyport-update -v
keyport-client -v
keyport-client-update -v
```

The client commands also support these options on Windows. Example output:

```text
keyport 1.2.0 (aaaaaaaaaaaa)
```

The short commit above is illustrative. Version output describes the local
installation and requires no network, database connection, or secret
configuration. Missing/invalid metadata prints `unknown (unknown)`.
Informational options are handled before update privilege checks and locking;
existing filesystem permissions still apply. Updaters reject unknown arguments
instead of starting an update. Running an updater without arguments performs
its normal update.

## Scopes

```bash
keyport scope list
keyport scope show example
keyport scope add example
keyport scope delete example
keyport scope delete example --yes
keyport scope lock example
keyport scope unlock example
keyport scope disable example
keyport scope enable example
keyport scope set example lock-on-source-mismatch on
keyport scope set example lock-on-source-mismatch off
```

`scope show` displays metadata, sources, credential IDs, and key names, but not API keys, API-key hashes, or stored key values.

## Sources

```bash
keyport source list example
keyport source add example 203.0.113.10
keyport source add example 203.0.113.10 10.0.0.0/8 2001:db8::/48
keyport source delete example 203.0.113.10
```

Addresses and networks are canonicalized before storage. Multiple values may be added or deleted in one invocation.

## Credentials

```bash
keyport credential list example
keyport credential add example
keyport credential delete example 3
keyport credential delete example 3 4 5
```

`credential add` generates a cryptographically random API key and prints it once. The database stores only its SHA-256 digest. Save the displayed API key immediately; it cannot be retrieved later from Keyport.

## Configuration

The CLI reads `/opt/keyport/keyport.conf` and connects directly to MariaDB using the configured Unix socket. It is intended to be run locally by an administrator rather than exposed remotely.
