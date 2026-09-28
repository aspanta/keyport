"""Validate the shipped filter with the actual Fail2ban parser."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def test_filter_matches_only_key_authentication_and_rate_limit_failures(tmp_path):
    executable = shutil.which('fail2ban-regex')
    if executable is None:
        pytest.skip('fail2ban-regex is required; installed by the Linux CI job')
    log = tmp_path / 'access.log'
    cases = [('GET', '/key/test/secret', 401), ('POST', '/key/test/secret', 429),
             ('GET', '/key/test/secret', 200), ('GET', '/key/test/secret', 403),
             ('GET', '/health', 401)]
    log.write_text(''.join(f'192.0.2.1 - - [28/Sep/2026:12:00:00 +0000] "{method} {path} HTTP/1.1" {status} 42 "-" "test"\n'
                           for method, path, status in cases))
    result = subprocess.run([executable, str(log), str(ROOT / 'server/config/fail2ban/filter.conf')],
                            capture_output=True, text=True, check=True)
    assert re.search(r'Failregex:\s+2 total', result.stdout), result.stdout
    assert re.search(r'5 lines, 0 ignored, 2 matched, 3 missed', result.stdout), result.stdout
