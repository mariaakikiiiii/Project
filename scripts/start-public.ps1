# Puts the whole GameOn app online for a demo, from this PC, for free:
#   browser --HTTPS--> https://<random>.trycloudflare.com --> Cloudflare Tunnel --> vite preview (127.0.0.1:4173)
#           --> /api and /hubs proxied to the ASP.NET API (https://localhost:7043) --> SQL Server (local)
# One public address serves the site, the API and live chat, so the strict same-site cookies, CSRF checks and
# the SignalR origin check all keep working unchanged. Nothing is opened on the router or firewall.
# The address changes every run; the site is online only while this window stays open.
# Usage (from anywhere):  powershell -ExecutionPolicy Bypass -File scripts\start-public.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$cloudflared = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cloudflared) { $cloudflared = "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe" }
if (-not (Test-Path $cloudflared)) { throw "cloudflared is not installed. Run: winget install -e --id Cloudflare.cloudflared" }
# Terminals opened before Node.js was installed lack it on PATH; add the default install folder.
if (Test-Path "$env:ProgramFiles\nodejs") { $env:Path = "$env:ProgramFiles\nodejs;$env:Path" }
$npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
if (-not $npm) { throw "Node.js is not installed. Run: winget install -e --id OpenJS.NodeJS.LTS" }

$logDir = Join-Path $env:TEMP "gameon-public"; New-Item -ItemType Directory -Force $logDir | Out-Null
$tunnelLog = Join-Path $logDir "tunnel.log"; Remove-Item $tunnelLog -ErrorAction SilentlyContinue
$procs = @()
try {
    Write-Host "1/4 Opening Cloudflare tunnel..." -ForegroundColor Cyan
    $procs += Start-Process $cloudflared -ArgumentList "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:4173", "--logfile", $tunnelLog -PassThru -WindowStyle Hidden
    $url = $null
    for ($i = 0; $i -lt 60 -and -not $url; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $tunnelLog) { $m = Select-String -Path $tunnelLog -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" | Select-Object -First 1; if ($m) { $url = $m.Matches[0].Value } }
    }
    if (-not $url) { throw "The tunnel did not start. See $tunnelLog" }

    Write-Host "2/4 Building the website..." -ForegroundColor Cyan
    Push-Location (Join-Path $root "frontend"); & $npm run build --silent; if ($LASTEXITCODE) { throw "Frontend build failed." }; Pop-Location

    Write-Host "3/4 Starting the API..." -ForegroundColor Cyan
    # Email links (verification, password reset) must point at the public address.
    $env:App__PublicOrigin = $url
    $procs += Start-Process dotnet -ArgumentList "run", "--urls", "https://localhost:7043" -WorkingDirectory (Join-Path $root "backend") -PassThru
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-WebRequest "https://localhost:7043/api/config" -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { }
    }

    Write-Host "4/4 Serving the website..." -ForegroundColor Cyan
    $procs += Start-Process $npm -ArgumentList "exec", "--", "vite", "preview", "--host", "127.0.0.1", "--port", "4173", "--strictPort" -WorkingDirectory (Join-Path $root "frontend") -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3

    Write-Host ""
    Write-Host "GameOn is online at:  $url" -ForegroundColor Green
    Write-Host "Share that link. In Development, confirmation/reset emails are printed in the API window." -ForegroundColor Gray
    Write-Host "Press Ctrl+C (or close this window) to take it offline." -ForegroundColor Gray
    Start-Process $url
    while ($true) { Start-Sleep -Seconds 5; if ($procs | Where-Object { $_.HasExited }) { Write-Warning "A component stopped; shutting down."; break } }
}
finally {
    foreach ($p in $procs) { if ($p -and -not $p.HasExited) { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } }
    Write-Host "GameOn is offline." -ForegroundColor Yellow
}
