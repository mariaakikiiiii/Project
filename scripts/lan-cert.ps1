# Creates an HTTPS certificate so phones and other computers on your network can open GameOn securely.
# It covers localhost, this PC's name and its current IPv4 addresses. Run it again if your IP address changes.
# Output (outside the repository): %LOCALAPPDATA%\GameOn\lan-cert.pfx + lan-cert.pass (random passphrase).
$dir = Join-Path $env:LOCALAPPDATA "GameOn"; New-Item -ItemType Directory -Force $dir | Out-Null
$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "169.254.*" } | ForEach-Object IPAddress
$dns = @("localhost", $env:COMPUTERNAME) + $ips
$cert = New-SelfSignedCertificate -Subject "CN=GameOn LAN ($env:COMPUTERNAME)" -DnsName $dns -CertStoreLocation Cert:\CurrentUser\My `
    -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(1) -FriendlyName "GameOn LAN dev" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")
$bytes = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pass = [Convert]::ToBase64String($bytes)
Export-PfxCertificate -Cert $cert -FilePath (Join-Path $dir "lan-cert.pfx") -Password (ConvertTo-SecureString $pass -AsPlainText -Force) | Out-Null
Set-Content -Path (Join-Path $dir "lan-cert.pass") -Value $pass -NoNewline -Encoding ascii
Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)"  # the PFX file is all Vite needs
Write-Host "Certificate created for: $($dns -join ', ')"
Write-Host "Saved in $dir (keep it private; it is not in Git)."
