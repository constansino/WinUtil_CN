# ASCII-only launcher for GitHub Release `irm ... | iex` usage.
# Windows PowerShell 5.1 can decode Release assets with the system code page.
# Keep this file ASCII so the launcher itself survives that decode path, then
# read the full localized script explicitly as UTF-8.
$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

$ScriptUrl = 'https://github.com/constansino/WinUtil_CN/releases/download/26.08.04-cn.20260804/winutil.zh_CN.commented.20260804.ps1'
$Response = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing

if ($null -ne $Response.RawContentStream) {
    if ($Response.RawContentStream.CanSeek) {
        $Response.RawContentStream.Position = 0
    }

    $Reader = [System.IO.StreamReader]::new($Response.RawContentStream, [System.Text.Encoding]::UTF8, $true)
    try {
        $Script = $Reader.ReadToEnd()
    } finally {
        $Reader.Dispose()
    }
} elseif ($Response.Content -is [byte[]]) {
    $Script = [System.Text.Encoding]::UTF8.GetString($Response.Content)
} else {
    $Script = [string]$Response.Content
}

Invoke-Expression $Script
