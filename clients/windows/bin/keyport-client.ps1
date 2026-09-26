#requires -version 5.1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$ConfigFile = Join-Path $env:ProgramData 'Keyport\keyport-client.conf'
$NamePattern = '^[a-z0-9][a-z0-9_-]{0,63}$'
$CreateDefaultLength = 64
$CreateMinLength = 16
$CreateMaxLength = 1024
$CreateAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
$KekLength = 32
$NonceLength = 12
$TagLength = 16
$FormatPrefix = 'v1:'
$MaxServerValueLength = 4096
$MaxPlaintextLength = 3041
$HttpTimeoutSeconds = 15

function Fail([string]$Message) {
    [Console]::Error.WriteLine("keyport-client: $Message")
    exit 1
}

function Test-Name([string]$Value, [string]$Label) {
    if ($Value -notmatch $NamePattern) {
        throw "invalid ${Label}: must match $NamePattern"
    }
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        throw "configuration file not found: $ConfigFile"
    }

    $config = @{}
    $lineNumber = 0
    foreach ($raw in [IO.File]::ReadAllLines($ConfigFile, [Text.Encoding]::UTF8)) {
        $lineNumber++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $pos = $line.IndexOf('=')
        if ($pos -lt 1) { throw "invalid configuration line ${lineNumber}: expected KEY=VALUE" }
        $key = $line.Substring(0, $pos).Trim()
        $value = $line.Substring($pos + 1).Trim()
        if ($config.ContainsKey($key)) { throw "duplicate configuration key: $key" }
        $config[$key] = $value
    }

    foreach ($key in @('KEYPORT_URL','KEYPORT_SCOPE','KEYPORT_API_KEY','KEYPORT_KEK_BASE64')) {
        if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($config[$key])) {
            throw "missing configuration value: $key"
        }
    }

    Test-Name $config.KEYPORT_SCOPE 'scope'
    $urlText = $config.KEYPORT_URL.TrimEnd('/')
    $uri = $null
    if (-not [Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'KEYPORT_URL must use HTTPS'
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { throw 'KEYPORT_URL must not contain credentials' }
    if ($uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
        throw 'KEYPORT_URL must not contain a path, query, or fragment'
    }
    $config.KEYPORT_URL = $urlText
    return $config
}

function Get-Kek($Config) {
    try { $kek = [Convert]::FromBase64String($Config.KEYPORT_KEK_BASE64) }
    catch { throw 'KEYPORT_KEK_BASE64 is not valid Base64' }
    if ($kek.Length -ne $KekLength) { throw "KEYPORT_KEK_BASE64 must decode to exactly $KekLength bytes" }
    return ,([byte[]]$kek)
}

if (-not ('KeyportNative.BCrypt' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace KeyportNative {
    public static class BCrypt {
        const string BCRYPT_AES_ALGORITHM = "AES";
        const string BCRYPT_CHAINING_MODE = "ChainingMode";
        const string BCRYPT_CHAIN_MODE_GCM = "ChainingModeGCM";
        const int BCRYPT_AUTH_MODE_CHAIN_CALLS_FLAG = 0x00000001;

        [StructLayout(LayoutKind.Sequential)]
        struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO {
            public int cbSize; public int dwInfoVersion;
            public IntPtr pbNonce; public int cbNonce;
            public IntPtr pbAuthData; public int cbAuthData;
            public IntPtr pbTag; public int cbTag;
            public IntPtr pbMacContext; public int cbMacContext;
            public int cbAAD; public long cbData; public int dwFlags;
        }

        [DllImport("bcrypt.dll", CharSet=CharSet.Unicode)] static extern int BCryptOpenAlgorithmProvider(out IntPtr h, string alg, string impl, int flags);
        [DllImport("bcrypt.dll", CharSet=CharSet.Unicode)] static extern int BCryptSetProperty(IntPtr h, string prop, byte[] input, int cbInput, int flags);
        [DllImport("bcrypt.dll")] static extern int BCryptGenerateSymmetricKey(IntPtr alg, out IntPtr key, IntPtr obj, int cbObj, byte[] secret, int cbSecret, int flags);
        [DllImport("bcrypt.dll")] static extern int BCryptEncrypt(IntPtr key, byte[] input, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO padding, byte[] iv, int cbIV, byte[] output, int cbOutput, out int result, int flags);
        [DllImport("bcrypt.dll")] static extern int BCryptDecrypt(IntPtr key, byte[] input, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO padding, byte[] iv, int cbIV, byte[] output, int cbOutput, out int result, int flags);
        [DllImport("bcrypt.dll")] static extern int BCryptDestroyKey(IntPtr key);
        [DllImport("bcrypt.dll")] static extern int BCryptCloseAlgorithmProvider(IntPtr h, int flags);

        static void Check(int status) { if (status != 0) throw new InvalidOperationException(String.Format("BCrypt operation failed: NTSTATUS 0x{0:X8}", unchecked((uint)status))); }
        static GCHandle Pin(byte[] b, out IntPtr p) { if (b == null || b.Length == 0) { p=IntPtr.Zero; return default(GCHandle); } var h=GCHandle.Alloc(b, GCHandleType.Pinned); p=h.AddrOfPinnedObject(); return h; }

        static IntPtr MakeKey(byte[] secret, out IntPtr alg) {
            Check(BCryptOpenAlgorithmProvider(out alg, BCRYPT_AES_ALGORITHM, null, 0));
            byte[] mode = System.Text.Encoding.Unicode.GetBytes(BCRYPT_CHAIN_MODE_GCM + "\0");
            Check(BCryptSetProperty(alg, BCRYPT_CHAINING_MODE, mode, mode.Length, 0));
            IntPtr key;
            Check(BCryptGenerateSymmetricKey(alg, out key, IntPtr.Zero, 0, secret, secret.Length, 0));
            return key;
        }

        public static byte[] Encrypt(byte[] secret, byte[] nonce, byte[] aad, byte[] plain, out byte[] tag) {
            IntPtr alg=IntPtr.Zero,key=IntPtr.Zero,np=IntPtr.Zero,ap=IntPtr.Zero,tp=IntPtr.Zero; tag=new byte[16];
            GCHandle nh=default(GCHandle),ah=default(GCHandle),th=default(GCHandle);
            try { key=MakeKey(secret,out alg); nh=Pin(nonce,out np); ah=Pin(aad,out ap); th=Pin(tag,out tp);
                var info=new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO { cbSize=Marshal.SizeOf(typeof(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO)), dwInfoVersion=1, pbNonce=np, cbNonce=nonce.Length, pbAuthData=ap, cbAuthData=aad.Length, pbTag=tp, cbTag=tag.Length };
                byte[] output=new byte[plain.Length]; int result; Check(BCryptEncrypt(key,plain,plain.Length,ref info,null,0,output,output.Length,out result,0)); return output;
            } finally { if(nh.IsAllocated)nh.Free(); if(ah.IsAllocated)ah.Free(); if(th.IsAllocated)th.Free(); if(key!=IntPtr.Zero)BCryptDestroyKey(key); if(alg!=IntPtr.Zero)BCryptCloseAlgorithmProvider(alg,0); }
        }

        public static byte[] Decrypt(byte[] secret, byte[] nonce, byte[] aad, byte[] cipher, byte[] tag) {
            IntPtr alg=IntPtr.Zero,key=IntPtr.Zero,np=IntPtr.Zero,ap=IntPtr.Zero,tp=IntPtr.Zero;
            GCHandle nh=default(GCHandle),ah=default(GCHandle),th=default(GCHandle);
            try { key=MakeKey(secret,out alg); nh=Pin(nonce,out np); ah=Pin(aad,out ap); th=Pin(tag,out tp);
                var info=new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO { cbSize=Marshal.SizeOf(typeof(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO)), dwInfoVersion=1, pbNonce=np, cbNonce=nonce.Length, pbAuthData=ap, cbAuthData=aad.Length, pbTag=tp, cbTag=tag.Length };
                byte[] output=new byte[cipher.Length]; int result; Check(BCryptDecrypt(key,cipher,cipher.Length,ref info,null,0,output,output.Length,out result,0)); return output;
            } finally { if(nh.IsAllocated)nh.Free(); if(ah.IsAllocated)ah.Free(); if(th.IsAllocated)th.Free(); if(key!=IntPtr.Zero)BCryptDestroyKey(key); if(alg!=IntPtr.Zero)BCryptCloseAlgorithmProvider(alg,0); }
        }
    }
}
'@
}

function Get-RandomBytes([int]$Length) {
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ,$bytes
}

function Get-Aad($Config, [string]$KeyName) { return ,([Text.Encoding]::ASCII.GetBytes("$($Config.KEYPORT_SCOPE)/$KeyName")) }

function Protect-Value($Config, [string]$KeyName, [byte[]]$Plaintext) {
    Test-Name $KeyName 'key name'
    $nonce = Get-RandomBytes $NonceLength
    $tag = $null
    $cipher = [KeyportNative.BCrypt]::Encrypt((Get-Kek $Config), $nonce, (Get-Aad $Config $KeyName), $Plaintext, [ref]$tag)
    $payload = New-Object byte[] ($nonce.Length + $cipher.Length + $tag.Length)
    [Array]::Copy($nonce,0,$payload,0,$nonce.Length); [Array]::Copy($cipher,0,$payload,$nonce.Length,$cipher.Length); [Array]::Copy($tag,0,$payload,$nonce.Length+$cipher.Length,$tag.Length)
    $value = $FormatPrefix + [Convert]::ToBase64String($payload)
    if ($value.Length -gt $MaxServerValueLength) { throw "encrypted value exceeds server limit ($($value.Length) > $MaxServerValueLength)" }
    return $value
}

function Unprotect-Value($Config, [string]$KeyName, [string]$Value) {
    Test-Name $KeyName 'key name'
    if (-not $Value.StartsWith($FormatPrefix)) { throw 'unsupported encrypted value format' }
    try { $payload = [Convert]::FromBase64String($Value.Substring($FormatPrefix.Length)) } catch { throw 'invalid Base64 in encrypted value' }
    if ($payload.Length -lt ($NonceLength + $TagLength)) { throw 'encrypted value is too short' }
    $nonce=New-Object byte[] $NonceLength; [Array]::Copy($payload,0,$nonce,0,$NonceLength)
    $cipherLen=$payload.Length-$NonceLength-$TagLength; $cipher=New-Object byte[] $cipherLen; [Array]::Copy($payload,$NonceLength,$cipher,0,$cipherLen)
    $tag=New-Object byte[] $TagLength; [Array]::Copy($payload,$NonceLength+$cipherLen,$tag,0,$TagLength)
    try { return ,([KeyportNative.BCrypt]::Decrypt((Get-Kek $Config),$nonce,(Get-Aad $Config $KeyName),$cipher,$tag)) }
    catch { throw 'decryption failed: invalid KEK, scope, key name, or ciphertext' }
}

function Get-KeyUrl($Config, $KeyName) {
    $scope=[Uri]::EscapeDataString($Config.KEYPORT_SCOPE)
    if ($null -eq $KeyName) { return "$($Config.KEYPORT_URL)/key/$scope" }
    Test-Name $KeyName 'key name'; return "$($Config.KEYPORT_URL)/key/$scope/$([Uri]::EscapeDataString($KeyName))"
}

function Invoke-KeyportHttp($Config, $KeyName, [string]$Method, $Body=$null) {
    $handler=New-Object Net.Http.HttpClientHandler
    $client=New-Object Net.Http.HttpClient($handler)
    $client.Timeout=[TimeSpan]::FromSeconds($HttpTimeoutSeconds)
    $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Config.KEYPORT_API_KEY)
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
    try {
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),(Get-KeyUrl $Config $KeyName))
        if ($null -ne $Body) { $json=$Body | ConvertTo-Json -Compress; $request.Content=[Net.Http.StringContent]::new($json,[Text.Encoding]::ASCII,'application/json') }
        try { $response=$client.SendAsync($request).GetAwaiter().GetResult() } catch { throw "connection failed: $($_.Exception.Message)" }
        $bytes=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $status=[int]$response.StatusCode
        if (-not $response.IsSuccessStatusCode) {
            $messages=@{400='server rejected the request';401='authentication failed';403='access denied';404='key not found';409='key limit reached';413='request is too large';429='rate limit exceeded';503='service unavailable'}
            if ($messages.ContainsKey($status)) { throw $messages[$status] } else { throw "server returned HTTP $status" }
        }
        return [PSCustomObject]@{ Status = $status; Body = [byte[]]$bytes }
    } finally { if($request){$request.Dispose()}; $client.Dispose(); $handler.Dispose() }
}

function Push-Value($Config,[string]$KeyName,[byte[]]$Plaintext) {
    $encrypted=Protect-Value $Config $KeyName $Plaintext
    $result=Invoke-KeyportHttp $Config $KeyName 'POST' @{key=$encrypted}
    if ($result.Status -ne 204) { throw "unexpected HTTP response: $($result.Status)" }
}

function Show-Help {
@'
usage: keyport-client <command> [arguments]

commands:
  list                         list keys in the configured scope
  get <keyname>                retrieve and decrypt a key
  push <keyname>               encrypt stdin and store it in Keyport
  create <keyname> [--length N] [--push]
                               generate a random ASCII key
  delete <keyname>             delete a key from Keyport
  kek generate                 generate a KEK
'@ | Write-Output
}

try {
    if ($args.Count -eq 0 -or $args[0] -in @('-h','--help')) { Show-Help; exit 0 }
    $command=$args[0]
    switch ($command) {
        'list' {
            if ($args.Count -ne 1) { throw 'usage: keyport-client list' }
            $config=Get-Config; $r=Invoke-KeyportHttp $config $null 'GET'; if($r.Status-ne 200){throw "unexpected HTTP response: $($r.Status)"}
            try { $obj=[Text.Encoding]::UTF8.GetString($r.Body) | ConvertFrom-Json } catch { throw 'server returned invalid JSON' }
            $names=@($obj.PSObject.Properties.Name); if ($null -eq $obj.keys -or $names.Count -ne 1 -or $names[0] -ne 'keys') { throw 'server returned an unexpected response' }
            foreach($name in @($obj.keys)){ if($name -isnot [string] -or $name -notmatch $NamePattern){throw 'server returned an unexpected response'}; [Console]::Out.WriteLine($name) }
        }
        'get' {
            if($args.Count-ne 2){throw 'usage: keyport-client get <keyname>'}; $config=Get-Config; $r=Invoke-KeyportHttp $config $args[1] 'GET';
            try{$obj=[Text.Encoding]::UTF8.GetString($r.Body)|ConvertFrom-Json}catch{throw 'server returned invalid JSON'}
            $names=@($obj.PSObject.Properties.Name); if($names.Count-ne 1 -or $names[0] -ne 'key' -or $obj.key -isnot [string]){throw 'server returned an unexpected response'}
            $plain=Unprotect-Value $config $args[1] $obj.key; $out=[Console]::OpenStandardOutput(); $out.Write($plain,0,$plain.Length); $out.Flush()
        }
		'push' {
			if($args.Count-ne 2){throw 'usage: keyport-client push <keyname>'}
			$stdin=[Console]::OpenStandardInput()
			$ms=New-Object IO.MemoryStream
			$buf=New-Object byte[] 4096
			while(($n=$stdin.Read($buf,0,$buf.Length))-gt 0){
				$ms.Write($buf,0,$n)
				if($ms.Length-gt $MaxPlaintextLength){
					throw "plaintext exceeds maximum size ($MaxPlaintextLength bytes)"
				}
			}
			Push-Value (Get-Config) $args[1] $ms.ToArray()
		}
        'create' {
            if($args.Count-lt 2){throw 'usage: keyport-client create <keyname> [--length N] [--push]'}; $name=$args[1]; Test-Name $name 'key name'; $length=$CreateDefaultLength; $push=$false; $i=2
            while($i-lt $args.Count){if($args[$i]-eq '--push'){$push=$true;$i++}elseif($args[$i]-eq '--length' -and $i+1-lt $args.Count){$length=0;if(-not [int]::TryParse($args[$i+1],[ref]$length)){throw 'invalid length'};$i+=2}else{throw "unknown argument: $($args[$i])"}}
            if($length-lt $CreateMinLength -or $length-gt $CreateMaxLength){throw "length must be between $CreateMinLength and $CreateMaxLength"}
            $random=Get-RandomBytes $length; $chars=New-Object char[] $length; for($j=0;$j-lt $length;$j++){$chars[$j]=$CreateAlphabet[$random[$j] % $CreateAlphabet.Length]}; $text=-join $chars; $bytes=[Text.Encoding]::ASCII.GetBytes($text)
            if($push){Push-Value (Get-Config) $name $bytes}; [Console]::Out.WriteLine($text)
        }
        'delete' { if($args.Count-ne 2){throw 'usage: keyport-client delete <keyname>'}; $r=Invoke-KeyportHttp (Get-Config) $args[1] 'DELETE'; if($r.Status-ne 204){throw "unexpected HTTP response: $($r.Status)"} }
        'kek' { if($args.Count-ne 2 -or $args[1]-ne 'generate'){throw 'usage: keyport-client kek generate'}; [Console]::Out.WriteLine([Convert]::ToBase64String((Get-RandomBytes $KekLength))) }
        default { throw "unknown command: $command" }
    }
} catch { Fail $_.Exception.Message }
