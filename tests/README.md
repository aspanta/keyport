# Regression checks

From the repository root:

```bash
python -m pip install -r tests/requirements.txt
python -m pytest -q tests
```

The API tests use the real Flask router and a transactional SQLite test double;
they do not establish MariaDB compatibility or concurrency guarantees. Server
updater tests run the actual shell script with relocated installation paths and
fault-injected external commands. They cover all four renames, TERM interruption,
restart/readiness failures, failed recovery, and update locking.

The Fail2ban check requires `fail2ban-regex` and is skipped locally when it is
unavailable. CI installs Fail2ban before running this check.

On Windows, from Windows PowerShell 5.1:

```powershell
./tests/test_windows_update.ps1
./tests/test_windows_version.ps1
```

These checks load production update functions and inject failures before and
after replacement, including failed restoration and retained recovery copies.
The injected post-replacement error exercises recovery defensively; it does not
claim that native `Move-Item` necessarily produces that failure on every system.
They also exercise a native replacement failure with an exclusively opened
target file and the updater's exclusive lock. CI runs this suite on Windows.

Version checks cover help/version options without configuration or network,
missing/corrupt metadata, and API fields. Client update tests verify pinned
downloads and code/metadata recovery, including legacy installs. Server update
checks reject a responding service with a different version or SHA. Windows
checks use a second process to verify lock exclusion, automatic deletion, and
reuse of stale lock files from older installations.

Linux lock checks run two real updater/installer processes, both during normal
work and while the first is paused after unlinking `.update.lock`. They verify
that the second process is rejected, stale files are reused, legacy file locks
are respected, and success/failure/signal paths remove only the owner's file.

Linux installer tests cover Debian-family detection, existing dependencies,
package installation and failures without changing host packages.
