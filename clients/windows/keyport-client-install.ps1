#requires -version 5.1
#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:ProgramData 'Keyport'
$BinDir = Join-Path $InstallDir 'bin'
$ConfigFile = Join-Path $InstallDir 'keyport-client.conf'
$Files = @('keyport-client.ps1','keyport-client.cmd','keyport-client-update.ps1','keyport-client-update.cmd')

function Fail([string]$Message) { [Console]::Error.WriteLine("keyport-client install: $Message"); exit 1 }
function Info([string]$Message) { [Console]::Out.WriteLine("keyport-client install: $Message") }

$updateLock = $null

try {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('keyport-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null
    try {
        Info 'downloading Keyport client from main'
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
            foreach ($file in $Files) { $wc.DownloadFile("$BaseUrl/bin/$file", (Join-Path $tmp $file)) }
            $wc.DownloadFile("$BaseUrl/keyport-client.conf.example", (Join-Path $tmp 'keyport-client.conf.example'))
        } finally { $wc.Dispose() }

        foreach ($file in @('keyport-client.ps1','keyport-client-update.ps1')) {
            $errors=$null; [Management.Automation.PSParser]::Tokenize([IO.File]::ReadAllText((Join-Path $tmp $file)),[ref]$errors) | Out-Null
            if($errors.Count){ throw "PowerShell validation failed: $file" }
        }

        # Reuse transaction and lock functions from the same pinned snapshot.
        $tokens=$null; $errors=$null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $tmp 'keyport-client-update.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'downloaded updater has syntax errors' }
        foreach ($name in @('Install-KeyportFiles','Get-KeyportUpdateLock')) {
            $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
            if ($null -eq $function) { throw "downloaded updater is missing $name" }
            . ([ScriptBlock]::Create($function.Extent.Text))
        }
        [IO.Directory]::CreateDirectory($BinDir) | Out-Null
        $updateLock = Get-KeyportUpdateLock $InstallDir

        & icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'failed to set installation ACL' }

        if (-not (Test-Path -LiteralPath $ConfigFile)) { Copy-Item -LiteralPath (Join-Path $tmp 'keyport-client.conf.example') -Destination $ConfigFile }
        Install-KeyportFiles $tmp $BinDir $Files (Join-Path $tmp 'build-info.json') (Join-Path $InstallDir 'build-info.json')

        $machinePath=[Environment]::GetEnvironmentVariable('Path','Machine')
        $parts=@($machinePath -split ';' | Where-Object { $_ })
        if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $BinDir.TrimEnd('\') })) {
            [Environment]::SetEnvironmentVariable('Path', (($parts + $BinDir) -join ';'), 'Machine')
            $env:Path += ";$BinDir"
        }
        Info 'installation complete'
        if (-not (Select-String -LiteralPath $ConfigFile -Pattern '^KEYPORT_API_KEY=(?!CHANGE_ME$).+' -Quiet)) {
            [Console]::Out.WriteLine(''); [Console]::Out.WriteLine("Configuration: $ConfigFile")
        }
    } finally { if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force} }
} catch { Fail $_.Exception.Message } finally { if ($null -ne $updateLock) { $updateLock.Dispose() } }
