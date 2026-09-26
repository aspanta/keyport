#requires -version 5.1
#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$BaseUrl = 'https://raw.githubusercontent.com/aspanta/keyport/main/clients/windows'
$InstallDir = Join-Path $env:ProgramData 'Keyport'
$BinDir = Join-Path $InstallDir 'bin'
$ConfigFile = Join-Path $InstallDir 'keyport-client.conf'
$Files = @('keyport-client.ps1','keyport-client.cmd','keyport-client-update.ps1','keyport-client-update.cmd')

function Fail([string]$Message) { [Console]::Error.WriteLine("keyport-client install: $Message"); exit 1 }
function Info([string]$Message) { [Console]::Out.WriteLine("keyport-client install: $Message") }

try {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('keyport-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null
    try {
        Info 'downloading Keyport client from main'
        $wc = New-Object Net.WebClient
        foreach ($file in $Files) { $wc.DownloadFile("$BaseUrl/bin/$file", (Join-Path $tmp $file)) }
        $wc.DownloadFile("$BaseUrl/keyport-client.conf.example", (Join-Path $tmp 'keyport-client.conf.example'))

        foreach ($file in @('keyport-client.ps1','keyport-client-update.ps1')) {
            $errors=$null; [Management.Automation.PSParser]::Tokenize([IO.File]::ReadAllText((Join-Path $tmp $file)),[ref]$errors) | Out-Null
            if($errors.Count){ throw "PowerShell validation failed: $file" }
        }

        [IO.Directory]::CreateDirectory($BinDir) | Out-Null
        foreach ($file in $Files) { Copy-Item -LiteralPath (Join-Path $tmp $file) -Destination (Join-Path $BinDir $file) -Force }
        if (-not (Test-Path -LiteralPath $ConfigFile)) { Copy-Item -LiteralPath (Join-Path $tmp 'keyport-client.conf.example') -Destination $ConfigFile }

        & icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'failed to set installation ACL' }

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
} catch { Fail $_.Exception.Message }
