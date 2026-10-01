#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$client = Join-Path $root 'clients/windows/bin/keyport-client.ps1'
$wrapper = Join-Path $root 'clients/windows/bin/keyport-client.cmd'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keyport-input-' + [Guid]::NewGuid().ToString('N'))
$savedProgramData = $env:ProgramData
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "assertion failed: $Message" }
}
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $env:ProgramData = $temp
    foreach ($command in @('list','get','push','create','delete','kek','kek generate','push example','create example')) {
        foreach ($flag in @('-h','--help')) {
            # Exercise the actual cmd wrapper as invoked by users, with no configuration.
            $output = & cmd.exe /d /c "`"`"$wrapper`" $command $flag`"" 2>&1
            Assert ($LASTEXITCODE -eq 0) "help failed for $command $flag : $output"
            Assert (($output -join "`n").Contains("usage: keyport-client $($command.Split(' ')[0])")) 'subcommand usage missing'
        }
    }
    Write-Output 'PASS subcommand help through cmd wrapper'
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($client, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'client parses'
    $functions = ''
    foreach ($name in @('Test-Name','Read-PasswordBytes','Read-PushInput')) {
        $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
        Assert ($null -ne $node) "missing function $name"
        $functions += $node.Extent.Text + "`n"
        . ([ScriptBlock]::Create($node.Extent.Text))
    }
    $NamePattern = '^[a-z0-9][a-z0-9_-]{0,63}$'
    $MaxPlaintextLength = 3041
    function Read-Host([string]$Prompt, [switch]$AsSecureString) {
        $script:prompts += $Prompt
        if ($Prompt -eq 'Key name') { return 'example' }
        Assert $AsSecureString 'password must use secure input'
        $secure = New-Object Security.SecureString
        foreach ($c in $script:password.ToCharArray()) { $secure.AppendChar($c) }
        return $secure
    }
    foreach ($name in @('example','')) {
        $script:prompts = @(); $script:password = ' secret ' + [char]0x00e9
        $value = Read-PushInput $name $false
        Assert ($value.KeyName -eq 'example') 'prompted key name'
        Assert ([Text.Encoding]::UTF8.GetString($value.Bytes) -ceq $script:password) 'password bytes unchanged'
        $expected = if ($name) { 'Password' } else { 'Key name,Password' }
        Assert (($script:prompts -join ',') -eq $expected) 'prompt sequence'
    }
    foreach ($case in @('empty','oversize','invalid-name','pipe-no-name')) {
        $script:password = if ($case -eq 'oversize') { 'a' * 3042 } else { '' }
        $script:prompts = @(); $failed = $false
        try {
            if ($case -eq 'pipe-no-name') { $null = Read-PushInput '' $true }
            elseif ($case -eq 'invalid-name') { $null = Read-PushInput '-bad' $false }
            else { $null = Read-PushInput 'example' $false }
        } catch { $failed = $true }
        Assert $failed "$case must fail"
        if ($case -in @('invalid-name','pipe-no-name')) { Assert ($script:prompts.Count -eq 0) 'invalid input must not prompt' }
    }
    Write-Output 'PASS hidden interactive password, key name and validation'
    # A separate process exercises actual redirected binary stdin and the size bound.
    $harness = Join-Path $temp 'pipe.ps1'
    $source = '$ErrorActionPreference = "Stop"' + "`n" + '$NamePattern = ''^[a-z0-9][a-z0-9_-]{0,63}$''' + "`n" + '$MaxPlaintextLength = 3041' + "`n" + $functions + @'
try {
    $value = Read-PushInput 'example'
    [Console]::Out.Write([Convert]::ToBase64String($value.Bytes))
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
    [IO.File]::WriteAllText($harness, $source)
    foreach ($size in @(0,4,3041,3042)) {
        $bytes = New-Object byte[] $size
        for ($i=0; $i -lt $size; $i++) { $bytes[$i] = $i % 256 }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$harness`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        try {
            $p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
            $p.StandardInput.Close()
            $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd()
            Assert ($p.WaitForExit(15000)) 'pipe process timeout'
            if ($size -gt 3041) { Assert ($p.ExitCode -ne 0 -and $stderr.Contains('maximum size')) 'oversized pipe rejected' }
            else { Assert ($p.ExitCode -eq 0 -and $stdout -ceq [Convert]::ToBase64String($bytes)) 'pipe bytes preserved' }
        } finally { if (-not $p.HasExited) { $p.Kill() }; $p.Dispose() }
    }
    Write-Output 'PASS redirected byte input and maximum size'
} finally {
    $env:ProgramData = $savedProgramData
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
