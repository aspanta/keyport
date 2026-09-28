#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$updater = Join-Path $root 'clients/windows/bin/keyport-client-update.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($updater, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "updater syntax errors: $errors" }
# Load the production functions without executing installation/download code.
foreach ($name in @('Install-KeyportFiles', 'Get-KeyportUpdateLock')) {
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    if ($null -eq $function) { throw "missing function $name" }
    . ([ScriptBlock]::Create($function.Extent.Text))
}

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "assertion failed: $Message" }
}
function Move-Item([string]$LiteralPath, [string]$Destination, [switch]$Force) {
    $script:moveCount++
    if ($script:mode -eq "before$script:moveCount") { throw 'injected move failure' }
    if ($script:mode -eq "locked$script:moveCount") {
        $held = [IO.File]::Open($Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        } finally { $held.Dispose() }
    } else {
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    if ($script:mode -eq "after$script:moveCount" -or ($script:mode -eq 'recovery' -and $script:moveCount -eq 2)) { throw 'injected failure after replacement' }
}
function Copy-Item([string]$LiteralPath, [string]$Destination, [switch]$Force) {
    if ($script:mode -eq 'recovery' -and $LiteralPath.EndsWith('.old')) { throw 'injected recovery failure' }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('keyport-tests-' + [Guid]::NewGuid().ToString('N'))
$names = @('client.ps1', 'client.cmd', 'update.ps1', 'update.cmd')
try {
    foreach ($case in @('success','before1','before2','before3','before4','after1','after2','after3','after4','locked2','recovery','stale')) {
        $script:mode = $case
        $script:moveCount = 0
        $source = Join-Path $testRoot "$case/source"
        $destination = Join-Path $testRoot "$case/bin"
        [IO.Directory]::CreateDirectory($source) | Out-Null
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        foreach ($name in $names) {
            [IO.File]::WriteAllText((Join-Path $source $name), 'new')
            [IO.File]::WriteAllText((Join-Path $destination $name), 'old')
        }
        if ($case -eq 'stale') { [IO.File]::WriteAllText((Join-Path $destination '.client.ps1.old'), 'recovery-copy') }
        $failure = $null
        try { Install-KeyportFiles $source $destination $names } catch { $failure = $_ }
        if ($case -eq 'success') {
            Assert ($null -eq $failure) "successful update: $failure"
        } else {
            Assert ($null -ne $failure) "$case must fail"
        }
        if ($case -eq 'stale') {
            Assert ([IO.File]::ReadAllText((Join-Path $destination '.client.ps1.old')) -eq 'recovery-copy') 'stale backup preserved'
            Assert ($script:moveCount -eq 0) 'no replacement with stale backup'
        } elseif ($case -eq 'recovery') {
            foreach ($name in $names) {
                Assert ([IO.File]::ReadAllText((Join-Path $destination (".$name.old"))) -eq 'old') 'failed recovery retains all backups'
            }
            $script:mode = 'success'
            $failure = $null
            try { Install-KeyportFiles $source $destination $names } catch { $failure = $_ }
            Assert ($null -ne $failure) 'retry must require recovery'
        } else {
            foreach ($name in $names) {
                $expected = if ($case -eq 'success') { 'new' } else { 'old' }
                Assert ([IO.File]::ReadAllText((Join-Path $destination $name)) -eq $expected) "$case preserves expected file content"
                Assert (-not (Test-Path -LiteralPath (Join-Path $destination (".$name.old")))) "$case cleans recovered backups"
            }
        }
        Write-Output "PASS $case"
    }
    # Root-level metadata must follow the same recovery decision as binaries.
    foreach ($legacy in @($false, $true)) {
        foreach ($case in @('success', 'before2', 'after5')) {
            $script:mode = $case; $script:moveCount = 0
            $caseRoot = Join-Path $testRoot ("metadata-$legacy-$case")
            $source = Join-Path $caseRoot 'source'; $destination = Join-Path $caseRoot 'bin'
            [IO.Directory]::CreateDirectory($source) | Out-Null
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            foreach ($name in $names) {
                [IO.File]::WriteAllText((Join-Path $source $name), 'new')
                [IO.File]::WriteAllText((Join-Path $destination $name), 'old')
            }
            $meta = Join-Path $caseRoot 'build-info.json'
            $metaSource = Join-Path $source 'build-info.json'
            [IO.File]::WriteAllText($metaSource, 'new-metadata')
            if (-not $legacy) { [IO.File]::WriteAllText($meta, 'old-metadata') }
            $failure = $null
            try { Install-KeyportFiles $source $destination $names $metaSource $meta } catch { $failure = $_ }
            if ($case -eq 'success') {
                Assert ($null -eq $failure) "metadata success: $failure"
                Assert ([IO.File]::ReadAllText($meta) -eq 'new-metadata') 'metadata installed in root'
            } else {
                Assert ($null -ne $failure) 'metadata failure injected'
                foreach ($name in $names) { Assert ([IO.File]::ReadAllText((Join-Path $destination $name)) -eq 'old') 'code restored' }
                if ($legacy) { Assert (-not (Test-Path $meta)) 'legacy metadata absence restored' }
                else { Assert ([IO.File]::ReadAllText($meta) -eq 'old-metadata') 'metadata restored' }
            }
            Assert (-not (Test-Path (Join-Path $destination 'build-info.json'))) 'metadata is not in bin'
            Write-Output "PASS metadata legacy=$legacy case=$case"
        }
    }

    # Use a second OS process, not just two handles in this process.
    $childScript = Join-Path $testRoot 'lock-child.ps1'
    $lockFunction = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-KeyportUpdateLock'}, $true)
    $childCode = 'param([string]$Directory)' + "`n" + $lockFunction.Extent.Text + "`n" + 'try { $lock = Get-KeyportUpdateLock $Directory; $lock.Dispose(); exit 0 } catch { exit 9 }'
    [IO.File]::WriteAllText($childScript, $childCode)
    # A stale file left by the previous updater must not block a new run.
    [IO.File]::WriteAllText((Join-Path $testRoot '.update.lock'), '')
    $lock = Get-KeyportUpdateLock $testRoot
    try {
        $child = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $childScript + '"'),('"' + $testRoot + '"')) -Wait -PassThru
        Assert ($child.ExitCode -eq 9) 'second process rejected while lock is held'
    } finally { $lock.Dispose() }
    Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot '.update.lock'))) 'lock file removed after disposal'
    $child = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $childScript + '"'),('"' + $testRoot + '"')) -Wait -PassThru
    Assert ($child.ExitCode -eq 0) 'next process acquires released lock'
    Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot '.update.lock'))) 'child cleans lock file'
    Write-Output 'PASS cross-process lock, stale file, cleanup and release'
} finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
