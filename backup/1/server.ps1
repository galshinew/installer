$ErrorActionPreference = 'Stop'
$port = 8765
$root = $PSScriptRoot
$log = Join-Path $root 'debug.log'

function Log([string]$m) {
    try { Add-Content -LiteralPath $log -Value ("{0} - {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -ErrorAction SilentlyContinue } catch {}
}

$test = New-Object Net.Sockets.TcpClient
try {
    $test.Connect('127.0.0.1', $port)
    $test.Close()
    Log "Server already running on port $port - not starting again."
    exit
} catch {}

$html = Get-Content -LiteralPath (Join-Path $root 'winget-app-installer.html') -Raw -Encoding UTF8

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Log "Server started on http://localhost:$port/"

while ($listener.IsListening) {
    $ctx = $null
    try {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath

        if ($path -eq '/' -and $req.HttpMethod -eq 'GET') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($html)
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($path -eq '/winutil.ps1' -and $req.HttpMethod -eq 'GET') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'winutil.ps1'))
            $res.ContentType = 'text/plain; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($path -eq '/applications.json' -and $req.HttpMethod -eq 'GET') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'applications.json'))
            $res.ContentType = 'application/json; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        else {
            $res.StatusCode = 404
        }
    }
    catch {
        Log ("Request error: " + $_.Exception.Message)
        try {
            $res.StatusCode = 500
            $e = [Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
            $res.ContentLength64 = $e.Length
            $res.OutputStream.Write($e, 0, $e.Length)
        } catch {}
    }
    if ($ctx) { $ctx.Response.Close() }
}
