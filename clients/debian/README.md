# Legacy Debian client download paths

The shared Linux client is maintained in [clients/linux](../linux/README.md),
with Debian and Synology DSM as supported platforms.

Files in this directory remain available for existing installation and update
URLs. They are generated from the Linux sources by
`python3 scripts/sync-linux-compat.py` and must not be edited independently.
Both legacy and canonical installers download the current client from
`clients/linux/`. An older installed updater can still download files from
`clients/debian/`; its replacement then uses the canonical Linux path.

Use the [Linux installation instructions](../linux/README.md) for new deployments.
