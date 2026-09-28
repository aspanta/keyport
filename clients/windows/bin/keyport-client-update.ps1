#requires -version 5.1
#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$BaseUrl = 'https://raw.githubusercontent.com/aspanta/keyport/main/clients/windows/bin'
$InstallDir = Join-Path $env:ProgramData 'Keyport'
$BinDir = Join-Path $InstallDir 'bin'
$Files = @('keyport-client.ps1','keyport-client.cmd','keyport-client-update.ps1','keyport-client-update.cmd')

function Fail([string]$Message) { [Console]::Error.WriteLine("keyport-client update: $Message"); exit 1 }
function Info([string]$Message) { [Console]::Out.WriteLine("keyport-client update: $Message") }

# Keep file replacement separate so failure and recovery can be exercised
# without downloading files or changing the real installation.
function Install-KeyportFiles([string]$SourceDir, [string]$DestinationDir, [string[]]$Names) {
    foreach ($file in $Names) {
        $backup = Join-Path $DestinationDir (".$file.old")
        if (Test-Path -LiteralPath $backup) {
            throw "recovery required: backup exists at $backup"
        }
    }

    $attempted = New-Object System.Collections.Generic.List[string]
    $removeBackups = $true
    try {
        # Prepare every replacement and recovery copy before changing a file.
        foreach ($file in $Names) {
            Copy-Item -LiteralPath (Join-Path $SourceDir $file) -Destination (Join-Path $DestinationDir (".$file.new")) -Force
            Copy-Item -LiteralPath (Join-Path $DestinationDir $file) -Destination (Join-Path $DestinationDir (".$file.old"))
        }
        $removeBackups = $false
        try {
            foreach ($file in $Names) {
                # Include the current file even if replacement changes the
                # destination and then reports failure.
                $attempted.Add($file)
                Move-Item -LiteralPath (Join-Path $DestinationDir (".$file.new")) -Destination (Join-Path $DestinationDir $file) -Force
            }
            $removeBackups = $true
        } catch {
            $updateError = $_
            $recoveryErrors = New-Object System.Collections.Generic.List[string]
            foreach ($file in $attempted) {
                try {
                    Copy-Item -LiteralPath (Join-Path $DestinationDir (".$file.old")) -Destination (Join-Path $DestinationDir $file) -Force
                } catch {
                    $recoveryErrors.Add("${file}: $($_.Exception.Message)")
                }
            }
            if ($recoveryErrors.Count) {
                throw "update failed: $($updateError.Exception.Message); recovery incomplete, backups retained in ${DestinationDir}: $($recoveryErrors -join '; ')"
            }
            $removeBackups = $true
            throw $updateError
        }
    } finally {
        foreach ($file in $Names) {
            Remove-Item -LiteralPath (Join-Path $DestinationDir (".$file.new")) -Force -ErrorAction SilentlyContinue
            if ($removeBackups) {
                Remove-Item -LiteralPath (Join-Path $DestinationDir (".$file.old")) -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-KeyportUpdateLock([string]$Directory) {
    try {
        return [IO.File]::Open((Join-Path $Directory '.update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw "cannot acquire update lock (another update may be running): $($_.Exception.Message)"
    }
}

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
            foreach ($file in $Files) {
                $wc.DownloadFile("$BaseUrl/$file", (Join-Path $tmp $file))
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

        Install-KeyportFiles $tmp $BinDir $Files

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
