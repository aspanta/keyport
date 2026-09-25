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
