# Keyport Client for Windows

The Keyport Windows client provides the same Keyport operations and encrypted
value format as the Debian client. Encryption and decryption are performed
locally and the KEK is never sent to the server.

## Requirements

- Windows with Windows PowerShell 5.1 or later
- Administrator privileges for installation and updating
- A configured Keyport scope and API credential

No Python installation or third-party cryptography package is required. The
client uses Windows CNG for AES-256-GCM.

## Installation

Run `clients/windows/keyport-client-install.ps1` from an elevated PowerShell
session. The installer downloads the current client from `main` and installs:

```text
C:\ProgramData\Keyport\
├── bin\
│   ├── keyport-client.cmd
│   ├── keyport-client.ps1
│   ├── keyport-client-update.cmd
│   └── keyport-client-update.ps1
└── keyport-client.conf
```

`C:\ProgramData\Keyport\bin\` is added to the machine `PATH`. A newly opened
elevated shell can therefore use `keyport-client` and
`keyport-client-update` directly.

The installer restricts the Keyport directory ACL to `SYSTEM` and the local
`Administrators` group. An existing configuration is preserved.

### Administrative access

The Windows client is intended for administrative use.

`C:\ProgramData\Keyport` is restricted to `SYSTEM` and the local
`Administrators` group because it contains the API credential and KEK.

Run `keyport-client` and `keyport-client-update` from an elevated Command
Prompt or PowerShell session. They are not intended to be accessible to
standard users.

## Updating

From an elevated shell:

```powershell
keyport-client-update
```

The updater replaces only files under `bin` and never modifies
`keyport-client.conf`.

## Configuration

The client reads:

```text
C:\ProgramData\Keyport\keyport-client.conf
```

The format is the same as on Debian:

```ini
KEYPORT_URL=https://keyport.example.com
KEYPORT_SCOPE=example
KEYPORT_API_KEY=CHANGE_ME
KEYPORT_KEK_BASE64=CHANGE_ME
```

## Commands

```text
keyport-client
├── list
├── get <keyname>
├── push <keyname>
├── create <keyname> [--length N] [--push]
├── delete <keyname>
└── kek
    └── generate
```

`push` reads bytes from standard input and `get` writes decrypted bytes to
standard output. The Windows and Debian clients use the same AES-256-GCM
format (`v1:<base64(nonce || ciphertext || tag)>`) and AAD (`scope/keyname`),
so values written by either client can be decrypted by the other when they use
the same scope and KEK.

A scope may contain at most 1000 keys. Updating an existing key remains
allowed at the limit.
