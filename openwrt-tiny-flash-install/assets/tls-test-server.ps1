# Minimal TLS endpoint that answers any request with HTTP 404.
# Purpose: prove a router's TLS stack really handshakes and speaks HTTP even
# though the peer is not a VPN server.  Expect on the router side:
#   SSL negotiation ... certificate verified ... Got HTTP response: HTTP/1.1 404
#   Unexpected 404 result from server      <- this is SUCCESS for the test
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tls-test-server.ps1 -Port 4443
param([int]$Port = 4443, [string]$DnsName = 'vpn-test.local')

$ErrorActionPreference = 'Stop'
$cert = New-SelfSignedCertificate -DnsName $DnsName `
    -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(30)
Write-Host "cert thumbprint: $($cert.Thumbprint)"

# A PEM copy, for appending to the client's CA bundle when full verification
# (not --servercert pinning) is what should be tested.
$pem = "-----BEGIN CERTIFICATE-----`n" +
       [Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks') +
       "`n-----END CERTIFICATE-----`n"
$pemPath = Join-Path $env:TEMP 'vpn-test-cert.pem'
[System.IO.File]::WriteAllText($pemPath, $pem)
Write-Host "PEM written to $pemPath"

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "TLS test server on 0.0.0.0:$Port  (host name $DnsName)"
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
        $ssl.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        Write-Host "handshake OK from $($client.Client.RemoteEndPoint) $($ssl.SslProtocol)"
        $buf = New-Object byte[] 2048
        $n = $ssl.Read($buf, 0, $buf.Length)
        if ($n -gt 0) { Write-Host "request: $(([System.Text.Encoding]::ASCII.GetString($buf, 0, $n) -split "`n")[0])" }
        $body = 'not-an-anyconnect-server'
        $resp = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
        $rb = [System.Text.Encoding]::ASCII.GetBytes($resp)
        $ssl.Write($rb, 0, $rb.Length); $ssl.Flush()
    } catch {
        Write-Host "handshake error: $($_.Exception.Message)"
    } finally {
        try { $client.Close() } catch {}
    }
}
