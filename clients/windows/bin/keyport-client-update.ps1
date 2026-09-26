#requires -version 5.1
#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$BaseUrl = 'https://raw.githubusercontent.com/aspanta/keyport/main/clients/windows/bin'
$InstallDir = Join-Path $env:ProgramData 'Keyport'
$BinDir = Join-Path $InstallDir 'bin'
$Files = @('keyport-client.ps1','keyport-client.cmd','keyport-client-update.ps1','keyport-client-update.cmd')

function Fail([string]$Message) { [Console]::Error.WriteLine("keyport-client update: $Message"); exit 1 }
function Info([string]$Message) { [Console]::Out.WriteLine("keyport-client update: $Message") }

try {
    if (-not (Test-Path -LiteralPath $BinDir -PathType Container)) {
        throw "Keyport client is not installed in $InstallDir"
    }

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

        $newFiles = @{}
        $backupFiles = @{}
        foreach ($file in $Files) {
            $new = Join-Path $BinDir (".$file.new")
            $backup = Join-Path $BinDir (".$file.old")
            Remove-Item -LiteralPath $new,$backup -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath (Join-Path $tmp $file) -Destination $new
            $newFiles[$file] = $new
            $backupFiles[$file] = $backup
        }

        $replaced = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($file in $Files) {
                $destination = Join-Path $BinDir $file
                Copy-Item -LiteralPath $destination -Destination $backupFiles[$file]
                Move-Item -LiteralPath $newFiles[$file] -Destination $destination -Force
                $replaced.Add($file)
            }
        } catch {
            foreach ($file in $replaced) {
                $destination = Join-Path $BinDir $file
                if (Test-Path -LiteralPath $backupFiles[$file] -PathType Leaf) {
                    Copy-Item -LiteralPath $backupFiles[$file] -Destination $destination -Force
                }
            }
            throw
        } finally {
            foreach ($file in $Files) {
                Remove-Item -LiteralPath $newFiles[$file],$backupFiles[$file] -Force -ErrorAction SilentlyContinue
            }
        }

        Info 'update complete'
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
} catch {
    Fail $_.Exception.Message
}
