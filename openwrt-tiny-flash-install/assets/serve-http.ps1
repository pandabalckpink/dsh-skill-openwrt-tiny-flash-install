# Serve a directory over HTTP for an offline router to pull packages from.
# Windows has no ssh-based bulk copy that survives an empty-password login, and
# HttpListener needs a URL ACL, so this uses a raw TcpListener (no privileges).
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File serve-http.ps1 -Root <dir> -Port 8080
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$Port = 8080
)
$ErrorActionPreference = 'Stop'
$rootFull = [System.IO.Path]::GetFullPath($Root)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "serving $rootFull on 0.0.0.0:$Port"

function Read-Line($stream) {
    $sb = New-Object System.Text.StringBuilder
    $prev = -1
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { break }
        if ($b -eq 10 -and $prev -eq 13) { return $sb.ToString().TrimEnd("`r") }
        [void]$sb.Append([char]$b)
        $prev = $b
        if ($sb.Length -gt 8192) { break }
    }
    return $sb.ToString()
}

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $requestLine = Read-Line $stream
        if ([string]::IsNullOrWhiteSpace($requestLine)) { $client.Close(); continue }
        while ($true) { if ([string]::IsNullOrEmpty((Read-Line $stream))) { break } }

        $parts = $requestLine -split ' '
        $urlPath = if ($parts.Length -ge 2) { $parts[1] } else { '/' }
        $urlPath = [System.Uri]::UnescapeDataString(($urlPath -split '\?')[0]).TrimStart('/')
        $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull $urlPath))

        $status = '404 Not Found'; $payload = [byte[]]@()
        if ($full.StartsWith($rootFull) -and (Test-Path $full -PathType Leaf)) {
            $payload = [System.IO.File]::ReadAllBytes($full); $status = '200 OK'
        }
        $head = "HTTP/1.1 $status`r`nContent-Type: application/octet-stream`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        if ($payload.Length -gt 0) { $stream.Write($payload, 0, $payload.Length) }
        $stream.Flush()
        Write-Host "$status $urlPath ($($payload.Length) bytes)"
    } catch {
        Write-Host "ERR: $_"
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}
