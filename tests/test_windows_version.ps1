#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('keyport-version-' + [Guid]::NewGuid().ToString('N'))
$savedProgramData = $env:ProgramData
try {
    $env:ProgramData = $testRoot
    $install = Join-Path $testRoot 'Keyport'
    [IO.Directory]::CreateDirectory($install) | Out-Null
    foreach ($metadata in @('missing', 'invalid', 'valid')) {
        $file = Join-Path $install 'build-info.json'
        if ($metadata -eq 'invalid') { [IO.File]::WriteAllText($file, 'invalid-json') }
        if ($metadata -eq 'valid') { [IO.File]::WriteAllText($file, '{"version":"1.2.0","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}') }
        foreach ($name in @('keyport-client','keyport-client-update')) {
            $script = Join-Path $root "clients/windows/bin/$name.ps1"
            foreach ($flag in @('-v','--version','-h','--help')) {
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script $flag
                if ($LASTEXITCODE -ne 0) { throw "$name $flag failed" }
                $text = $output -join "`n"
                if ($flag -in @('-v','--version')) {
                    $expected = if ($metadata -eq 'valid') { "$name 1.2.0 (aaaaaaaaaaaa)" } else { "$name unknown (unknown)" }
                    if ($text -ne $expected) { throw "unexpected version: $text" }
                } elseif (-not $text.Contains('-v, --version')) { throw 'version missing from help' }
                if (Test-Path (Join-Path $install '.update.lock')) { throw 'informational option acquired a lock' }
            }
        }
        Write-Output "PASS Windows CLI metadata=$metadata"
    }
    # Parse every shipped script, including the installer.
    Get-ChildItem (Join-Path $root 'clients/windows') -Recurse -Filter '*.ps1' | ForEach-Object {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { throw "syntax errors in $($_.FullName): $errors" }
    }
    Write-Output 'PASS Windows script syntax'
} finally {
    $env:ProgramData = $savedProgramData
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
