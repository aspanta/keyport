# Regression checks

From the repository root:

```bash
python -m pip install -r tests/requirements.txt
python -m pytest -q tests/test_api.py tests/test_server_update.py tests/test_fail2ban.py
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
```

These checks load production update functions and inject failures before and
after replacement, including failed restoration and retained recovery copies.
The injected post-replacement error exercises recovery defensively; it does not
claim that native `Move-Item` necessarily produces that failure on every system.
They also exercise the exclusive file lock. CI runs this suite on Windows.
