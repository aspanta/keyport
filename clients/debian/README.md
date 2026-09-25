# Keyport Client for Debian

The Keyport Debian client is a command-line client for storing and retrieving
encrypted key material using a Keyport server.

Encryption and decryption are performed locally. The Key Encryption Key (KEK)
remains on the client and is never sent to Keyport.

## Requirements

- Debian
- Python 3
- Python `cryptography` package
- A configured Keyport scope and API credential

On Debian, install the cryptography package with:

```bash
apt install python3-cryptography
```

## Installation

Install the current version from the `main` branch:

```bash
curl -fsSL https://raw.githubusercontent.com/aspanta/keyport/main/clients/debian/install.sh | sudo bash
```

The installer:

- installs the required Debian packages;
- downloads the current client and updater from the Keyport repository;
- validates the downloaded files before installation;
- installs the client under `/opt/keyport-client`;
- creates the `keyport-client` and `keyport-client-update` commands;
- creates an initial configuration if one does not already exist.

The resulting layout is:

```text
/opt/keyport-client/
├── keyport-client
├── keyport-client.conf
└── update.sh

/usr/local/sbin/keyport-client
/usr/local/sbin/keyport-client-update
```

An existing `keyport-client.conf` is never overwritten by the installer.

## Updating

Update the installed client from the current `main` branch with:

```bash
sudo keyport-client-update
```

The updater downloads and validates both the client and the updater before
replacing the installed files.

The local `keyport-client.conf` is not modified by updates.

## Configuration

The client reads:

```text
/opt/keyport-client/keyport-client.conf
```

Example:

```ini
KEYPORT_URL=https://keyport.example.com
KEYPORT_SCOPE=example
KEYPORT_API_KEY=CHANGE_ME
KEYPORT_KEK_BASE64=CHANGE_ME
```

`KEYPORT_URL`
: HTTPS URL of the Keyport server. A path, query, fragment, or embedded
credentials are not allowed.

`KEYPORT_SCOPE`
: Scope used by this client.

`KEYPORT_API_KEY`
: API credential belonging to the configured scope.

`KEYPORT_KEK_BASE64`
: Standard Base64 encoding of exactly 32 bytes used as the AES-256-GCM Key
Encryption Key.

Generate a KEK locally with:

```bash
keyport-client kek generate
```

The KEK must remain on the client. It is never transmitted to the Keyport
server.

### Configuration permissions

The configuration contains both the API credential and the KEK and must
therefore be treated as sensitive.

The repository does not prescribe one universal owner or permission mode for
the configuration file. The administrator should choose ownership and
permissions according to which local users or services are allowed to use
Keyport.

For a root-only installation, for example:

```bash
chown root:root /opt/keyport-client/keyport-client.conf
chmod 0600 /opt/keyport-client/keyport-client.conf
```

A service-oriented installation may instead use an appropriate Unix group and
mode such as `0640`.

Avoid making the configuration readable by users that do not require access to
Keyport.

## Commands

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

Scope and key names must match:

```text
^[a-z0-9][a-z0-9_-]{0,63}$
```

## Generate a KEK

```bash
keyport-client kek generate
```

This generates 32 cryptographically random bytes and prints their standard
Base64 representation.

This command does not require a client configuration and does not contact the
Keyport server.

## Generate a key

```bash
keyport-client create <keyname>
```

The generated key uses the alphabet:

```text
ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_
```

The default length is 64 characters.

A length from 16 through 1024 characters may be specified:

```bash
keyport-client create <keyname> --length 128
```

Without `--push`, this command does not require a client configuration and does
not contact the Keyport server.

The generated key is written to stdout followed by a newline for command-line
convenience. The generated key itself does not contain that newline.

## Generate and store a key

```bash
keyport-client create <keyname> --push
```

The key is generated locally and encrypted locally before being sent to
Keyport.

The plaintext generated key is written to stdout only after the server has
successfully stored the encrypted value. If the upload fails, the generated
key is not written to stdout.

For example:

```bash
KEY="$(keyport-client create disk-key --push)"
```

## Store existing key material

`push` reads plaintext bytes directly from stdin:

```bash
printf '%s' 'my-secret' | keyport-client push <keyname>
```

A binary key file may be passed directly:

```bash
keyport-client push <keyname> < /path/to/keyfile
```

The input is encrypted locally before transmission.

`push` is binary-safe and does not interpret or modify the plaintext bytes.

The maximum plaintext size supported by the current client and server format
is 3041 bytes.

## Retrieve key material

```bash
keyport-client get <keyname>
```

The encrypted value is retrieved from Keyport and decrypted locally.

The original plaintext bytes are written directly to stdout. The client does
not append a newline or otherwise modify the decrypted data.

For binary data:

```bash
keyport-client get <keyname> > /path/to/keyfile
```

For command substitution with textual key material:

```bash
KEY="$(keyport-client get <keyname>)"
```

## Delete a key

```bash
keyport-client delete <keyname>
```

Deletion is idempotent. Deleting a key that is already absent is considered
successful by the Keyport server.

## Encryption format

The Debian client uses AES-256-GCM.

For every encryption operation it generates a fresh 12-byte random nonce.

The Additional Authenticated Data (AAD) is the ASCII representation of:

```text
<scope>/<keyname>
```

The value stored on the Keyport server is:

```text
v1:<Base64(nonce || ciphertext || tag)>
```

The GCM authentication tag is 16 bytes.

The server treats the entire value as opaque data and cannot decrypt it because
the KEK remains on the client.

Binding the ciphertext to both the scope and key name through authenticated
additional data means that moving the encrypted value to another scope or key
name causes authentication to fail during decryption.

## Binary safety

`push` and `get` operate on bytes.

They preserve arbitrary binary key material, including:

- NUL bytes
- CR and LF bytes
- non-ASCII byte values

`create` is intentionally different: it generates printable ASCII key material
suitable for textual secrets and passphrases.

## TLS

The client requires HTTPS.

TLS certificate verification uses Python's standard TLS trust configuration.
The client does not provide an option to disable certificate verification.

## Error handling

Successful commands exit with status `0`.

Operational failures exit with a non-zero status and write an error message to
stderr.

Examples include:

- authentication failure
- access denied
- missing key
- invalid configuration
- invalid KEK
- authenticated decryption failure
- connection failure
- rate limiting
- oversized plaintext

Decrypted plaintext is written only to stdout, allowing callers to keep error
messages separate from key material.

## Using Keyport with encrypted storage

Keyport can provide key material to local disk-unlock or other automation
procedures.

For example, a stored key can be retrieved as raw bytes with:

```bash
keyport-client get disk-key
```

How those bytes are passed to LUKS, `cryptsetup`, or another local system is a
deployment-specific decision and is intentionally outside the Keyport client.

Keyport should not be the only recovery mechanism for encrypted data. Maintain
an independent offline recovery credential or equivalent recovery path that
does not depend on the Keyport server, DNS, network connectivity, the API
credential, or the client KEK.

## Security considerations

The API key and KEK serve different purposes.

The API key authenticates access to a Keyport scope. Possession of the API key
alone does not provide the KEK required to decrypt correctly client-encrypted
values.

The KEK provides local encryption and authenticated decryption. It must not be
stored on the Keyport server.

Anyone who obtains the client configuration gains access to both the API
credential and the KEK. Protect that configuration accordingly.

Keyport reduces the amount of plaintext key material that must be stored on the
remote server, but it does not protect a client whose local operating system,
configuration, or runtime has been fully compromised.
