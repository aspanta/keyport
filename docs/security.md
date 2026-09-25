# Security

## Security objective

Keyport is designed to reduce the consequences of compromise of a remote key-release server. The server does not need the client-side Key Encryption Key (KEK) used to decrypt stored automation key material.

Keyport is not intended to make a compromised client safe, nor can guest-OS hardening provide a security boundary against a fully compromised infrastructure provider or hypervisor.

## Client-side encryption

The reference Debian client encrypts and decrypts key material locally using
AES-256-GCM with a 256-bit Key Encryption Key (KEK).

A fresh 12-byte random nonce is generated for every encryption operation. The
GCM authentication tag is 16 bytes.

The stored format is:

```text
v1:<base64(nonce || ciphertext || tag)>
```

The Additional Authenticated Data (AAD) is the ASCII representation of:

```text
scope/keyname
```

Binding the ciphertext to the scope and key name means that moving an encrypted
value to another scope or key name causes authenticated decryption to fail.

Encryption and decryption are client responsibilities. Keyport treats the
resulting string as opaque data. The KEK remains on the client and is never
sent to Keyport.

The server accepts opaque values up to 4096 ASCII characters. With the current
`v1` encoding, the reference Debian client therefore limits plaintext input to
3041 bytes.

The `push` and `get` operations are binary-safe. Decrypted data is returned
exactly as bytes without adding a newline or otherwise modifying the plaintext.

## Separation of secrets

The design separates the API key, KEK, encrypted automation key, and offline recovery credential. The API key authorizes Keyport access but is insufficient by itself to decrypt correctly client-encrypted material. The KEK is not stored by Keyport. Recovery remains independent of Keyport availability.

## API credentials

API credentials are generated with cryptographically secure randomness. Keyport stores `SHA-256(API key)` rather than the plaintext API key. The plaintext value is shown once at creation.

## Source allow-list

Credentials are additionally constrained by a per-scope IPv4/IPv6 source allow-list. In the reference deployment nginx replaces `X-Keyport-Source-IP` with `$remote_addr`. Gunicorn is therefore bound only to `127.0.0.1:8000` and must not be exposed directly to untrusted networks.

## Source mismatch locking

When `lock_on_source_mismatch` is enabled, a request using a valid credential from outside the configured allow-list can atomically transition an active scope to `LOCKED`. Arbitrary invalid API keys must not allow an unauthenticated attacker to lock scopes.

## Scope states

Scopes have three states: `ACTIVE`, `LOCKED`, and `DISABLED`. Only `ACTIVE` scopes authorize key operations.

## Audit logging

Authorization and key operations generate audit records. Sensitive values must not be placed in audit records. In particular, audit data must not contain API keys, stored key values, request bodies containing those values, or client KEKs.

## HTTP exposure

The reference public service exposes nginx on HTTPS. Gunicorn listens only on loopback. MariaDB is accessed by the application through a local Unix socket. `/key/` is rate-limited. HTTP redirects to HTTPS and the reference HTTPS configuration sends `Strict-Transport-Security: max-age=31536000`.

## Fail2ban

The reference Fail2ban filter reacts to repeated HTTP 401 and 429 responses on `/key/`. It deliberately does not treat every 403 as an authentication attack because 403 is also part of Keyport authorization and scope/source behavior. The jail uses escalating ban times.

## systemd isolation

The reference systemd service uses `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, private temporary/device namespaces, kernel/control-group protections, process visibility restrictions, namespace restrictions, an empty capability bounding set, and restricted address families.

The service is allowed writable state under `/var/lib/keyport`, while `/opt/keyport` is intended to remain read-only to the service account. This prevents a compromised worker from trivially replacing its own installed application or Python environment.

## Database compromise

The database contains scope configuration, source allow-lists, SHA-256 API-key digests, opaque stored key values, and audit data. It must still be protected as sensitive data. In the intended client-encryption model, database compromise alone does not provide the client KEK and therefore should not reveal the plaintext automation key.

## Server compromise

A fully compromised Keyport server can observe future authenticated requests, alter responses, modify stored data, or interfere with availability. Client-side authenticated encryption protects payload confidentiality and integrity against some server-side manipulation, but it does not make a compromised server harmless.

## Infrastructure trust

The cloud infrastructure provider is part of the trusted computing base for the server. Guest-OS hardening should not be interpreted as protection against a fully compromised hypervisor or provider control plane.

## Recovery

Keyport should not be the only recovery path for encrypted data. Maintain an independent offline recovery credential or equivalent mechanism. Recovery should remain possible when Keyport, DNS, or the network is unavailable; when the database or API credential is lost; when a scope is locked; or when the client-side KEK mechanism fails.

## Backups

Back up the database, deployment configuration, application source/version, and operational documentation. Do not create unnecessary backups of plaintext client secrets. Database backups must be protected as sensitive material even though stored key values are intended to be client-encrypted.

## Operational principle

Keep the service small. Additional remote administration endpoints, cryptographic responsibilities, plugins, or server-side knowledge of stored values should be added only when there is a clear requirement. The limited feature set is part of the security design.
