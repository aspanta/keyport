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
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    if ($script:mode -eq "after$script:moveCount" -or ($script:mode -eq 'recovery' -and $script:moveCount -eq 2)) { throw 'injected failure after replacement' }
}
function Copy-Item([string]$LiteralPath, [string]$Destination, [switch]$Force) {
    if ($script:mode -eq 'recovery' -and $LiteralPath.EndsWith('.old')) { throw 'injected recovery failure' }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('keyport-tests-' + [Guid]::NewGuid().ToString('N'))
$names = @('client.ps1', 'client.cmd', 'update.ps1', 'update.cmd')
try {
    foreach ($case in @('success','before1','before2','before3','before4','after1','after2','after3','after4','recovery','stale')) {
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
    $lock = Get-KeyportUpdateLock $testRoot
    try {
        $failure = $null
        try { $second = Get-KeyportUpdateLock $testRoot; $second.Dispose() } catch { $failure = $_ }
        Assert ($null -ne $failure) 'parallel updater lock rejected'
    } finally { $lock.Dispose() }
    $lock = Get-KeyportUpdateLock $testRoot
    $lock.Dispose()
    Write-Output 'PASS exclusive lock and release'
} finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
