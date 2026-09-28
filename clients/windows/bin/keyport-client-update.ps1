#requires -version 5.1

$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:ProgramData 'Keyport'
$BinDir = Join-Path $InstallDir 'bin'
$Files = @('keyport-client.ps1','keyport-client.cmd','keyport-client-update.ps1','keyport-client-update.cmd')

function Fail([string]$Message) { [Console]::Error.WriteLine("keyport-client update: $Message"); exit 1 }
function Info([string]$Message) { [Console]::Out.WriteLine("keyport-client update: $Message") }

# Keep file replacement separate so failure and recovery can be exercised
# without downloading files or changing the real installation.
function Install-KeyportFiles([string]$SourceDir, [string]$DestinationDir, [string[]]$Names, [string]$BuildInfoSource = '', [string]$BuildInfoDestination = '') {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in $Names) {
        $items.Add([PSCustomObject]@{Source=(Join-Path $SourceDir $file); Destination=(Join-Path $DestinationDir $file)})
    }
    if ($BuildInfoSource -and $BuildInfoDestination) {
        $items.Add([PSCustomObject]@{Source=$BuildInfoSource; Destination=$BuildInfoDestination})
    } elseif ($BuildInfoSource -or $BuildInfoDestination) { throw 'both metadata paths are required' }

    foreach ($item in $items) {
        $directory = Split-Path -Parent $item.Destination
        $name = Split-Path -Leaf $item.Destination
        $item | Add-Member NoteProperty New (Join-Path $directory (".$name.new"))
        $item | Add-Member NoteProperty Backup (Join-Path $directory (".$name.old"))
        $item | Add-Member NoteProperty Absent (Join-Path $directory (".$name.old.absent"))
        $item | Add-Member NoteProperty HadOriginal (Test-Path -LiteralPath $item.Destination -PathType Leaf)
        if ((Test-Path -LiteralPath $item.Backup) -or (Test-Path -LiteralPath $item.Absent)) {
            throw "recovery required: backup exists for $($item.Destination)"
        }
    }

    $attempted = New-Object System.Collections.Generic.List[object]
    $removeBackups = $true
    try {
        foreach ($item in $items) {
            Copy-Item -LiteralPath $item.Source -Destination $item.New -Force
            if ($item.HadOriginal) {
                Copy-Item -LiteralPath $item.Destination -Destination $item.Backup
            } else {
                [IO.File]::WriteAllText($item.Absent, '')
            }
        }
        $removeBackups = $false
        try {
            foreach ($item in $items) {
                $attempted.Add($item)
                Move-Item -LiteralPath $item.New -Destination $item.Destination -Force
            }
            $removeBackups = $true
        } catch {
            $updateError = $_
            $recoveryErrors = New-Object System.Collections.Generic.List[string]
            foreach ($item in $attempted) {
                try {
                    if ($item.HadOriginal) {
                        Copy-Item -LiteralPath $item.Backup -Destination $item.Destination -Force
                    } elseif (Test-Path -LiteralPath $item.Destination) {
                        Remove-Item -LiteralPath $item.Destination -Force
                    }
                } catch { $recoveryErrors.Add("$($item.Destination): $($_.Exception.Message)") }
            }
            if ($recoveryErrors.Count) {
                throw "update failed: $($updateError.Exception.Message); recovery incomplete, backups retained: $($recoveryErrors -join '; ')"
            }
            $removeBackups = $true
            throw $updateError
        }
    } finally {
        foreach ($item in $items) {
            Remove-Item -LiteralPath $item.New -Force -ErrorAction SilentlyContinue
            if ($removeBackups) {
                Remove-Item -LiteralPath $item.Backup,$item.Absent -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-KeyportUpdateLock([string]$Directory) {
    try {
        return [IO.FileStream]::new((Join-Path $Directory '.update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    } catch {
        throw "cannot acquire update lock (another update may be running): $($_.Exception.Message)"
    }
}

function Show-Version {
    $version = 'unknown'; $commit = 'unknown'
    try {
        $info = [IO.File]::ReadAllText((Join-Path $InstallDir 'build-info.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($info.version -is [string] -and $info.version -cmatch '\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\z' -and $info.commit -is [string] -and $info.commit -cmatch '\A[0-9a-f]{40}\z') {
            $version = $info.version; $commit = $info.commit.Substring(0,12)
        }
    } catch { }
    [Console]::Out.WriteLine("keyport-client-update $version ($commit)")
}

if ($args.Count -eq 1 -and $args[0] -in @('-h','--help')) {
@'
usage: keyport-client-update [-h] [-v]

Update the installed Keyport client from main.

options:
  -h, --help     show this help message and exit
  -v, --version  show version information and exit
'@ | Write-Output
    exit 0
}
if ($args.Count -eq 1 -and $args[0] -in @('-v','--version')) { Show-Version; exit 0 }
if ($args.Count -ne 0) { [Console]::Error.WriteLine('keyport-client-update: unknown arguments; use --help'); exit 2 }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'must be run as Administrator' }

$updateLock = $null

try {
    if (-not (Test-Path -LiteralPath $BinDir -PathType Container)) {
        throw "Keyport client is not installed in $InstallDir"
    }

    $updateLock = Get-KeyportUpdateLock $InstallDir

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('keyport-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null

    try {
        Info 'downloading current files from main'
        $wc = New-Object Net.WebClient
        try {
            $wc.Headers['User-Agent'] = 'Keyport'
            $revision = $wc.DownloadString('https://api.github.com/repos/aspanta/keyport/commits/main') | ConvertFrom-Json
            $commit = $revision.sha
            if ($commit -isnot [string] -or $commit -cnotmatch '\A[0-9a-f]{40}\z') { throw 'invalid commit returned by GitHub' }
            $rootUrl = "https://raw.githubusercontent.com/aspanta/keyport/$commit"
            $BaseUrl = "$rootUrl/clients/windows"
            $version = $wc.DownloadString("$rootUrl/VERSION").Trim()
            if ($version -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\z') { throw 'invalid VERSION' }
            $metadata = @{version=$version; commit=$commit} | ConvertTo-Json -Compress
            [IO.File]::WriteAllText((Join-Path $tmp 'build-info.json'), $metadata, (New-Object Text.UTF8Encoding $false))
            foreach ($file in $Files) {
                $wc.DownloadFile("$BaseUrl/bin/$file", (Join-Path $tmp $file))
            }
        } finally {
            $wc.Dispose()
        }

        foreach ($file in @('keyport-client.ps1','keyport-client-update.ps1')) {
            $errors = $null
            [Management.Automation.PSParser]::Tokenize(
                [IO.File]::ReadAllText((Join-Path $tmp $file)),
                [ref]$errors
            ) | Out-Null
            if ($errors.Count) {
                throw "PowerShell validation failed: $file"
            }
        }

        Install-KeyportFiles $tmp $BinDir $Files (Join-Path $tmp 'build-info.json') (Join-Path $InstallDir 'build-info.json')

        Info 'update complete'
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
} catch {
    Fail $_.Exception.Message
} finally {
    if ($null -ne $updateLock) { $updateLock.Dispose() }
}
