# Keyport Client for Windows

The Keyport Windows client provides the same Keyport operations and encrypted
value format as the Linux client. Encryption and decryption are performed
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
├── build-info.json
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

The updater replaces client files under `bin` and updates root-level
`build-info.json` in the same recovery operation. It preserves
`keyport-client.conf`.

Only one installer/updater may run at a time. The lock is an exclusive open
file handle, not a test of whether `.update.lock` exists. Windows removes this
file automatically when the owning handle closes (`DeleteOnClose`). A stale
file from older versions can be reused safely; a genuinely held lock rejects
the second process. Do not manually remove a lock held by another process.

All replacement files and backups are prepared before installation begins.
If replacement fails, every attempted file is restored, including root-level
metadata. Failed recovery retains `.old` backups next to their destinations;
`.old.absent` marks a previously missing file. A subsequent update refuses to
overwrite these recovery records. With no updater running, preserve the backups,
restore each `.old` file (or remove a destination marked `.old.absent`), and
verify the client before removing recovery records and retrying.

## Help and version

Both `keyport-client` and `keyport-client-update` support `-h` / `--help` and
`-v` / `--version`. These options run before privilege checks, configuration
loading, downloads, and locking; existing filesystem permissions still apply.
Unknown updater arguments fail instead of starting an update.

Installation and updating resolve `main` once, then download `VERSION` and
all client files from that exact commit. The release number and full SHA are
stored in `C:\ProgramData\Keyport\build-info.json`, outside `bin`. Version
output uses a 12-character SHA and is entirely local. Missing/invalid metadata
reports `unknown (unknown)`.

For the first upgrade from an updater that does not install metadata, rerun
the current installer; it preserves the existing client configuration.

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
standard output. The Windows and Linux clients use the same AES-256-GCM
format (`v1:<base64(nonce || ciphertext || tag)>`) and AAD (`scope/keyname`),
so values written by either client can be decrypted by the other when they use
the same scope and KEK.

A scope may contain at most 1000 keys. Updating an existing key remains
allowed at the limit.

## Interactive push

With no redirected stdin, `keyport-client push mykey` prompts for a hidden
password. `keyport-client push` prompts for the key name first, then the password.
The password is encoded as UTF-8 without adding a newline. Empty interactive
passwords are rejected; the existing 3041-byte plaintext limit applies.
Cancel with Ctrl+C. The KEK and API credential still come from the configuration.

Pipes and redirected files continue to supply raw bytes and require a key name;
no prompts are shown for redirected input. For binary or multiline values, use
redirected input. `keyport-client push -h` and `keyport-client create -h` display
help without reading input or configuration.
