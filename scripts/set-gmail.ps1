# Saves Gmail SMTP settings in YOUR user-secret store so the API can send verification/reset emails to anyone.
# The app password is typed hidden and never printed. Create one at https://myaccount.google.com/apppasswords
# (requires 2-Step Verification on that Google account).
$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "..\backend"
$user = (Read-Host "Gmail address to send from").Trim()
if ($user -notmatch '^[^@\s]+@[^@\s]+$') { throw "That does not look like an email address." }
$secure = Read-Host "Gmail app password (16 letters, hidden)" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
$plain = $plain -replace '\s', ''
if ($plain.Length -ne 16) { Write-Warning "Gmail app passwords are 16 letters; got $($plain.Length). Saving anyway." }
dotnet user-secrets set "Email:SmtpUser" $user --project $project | Out-Null
dotnet user-secrets set "Email:SmtpPassword" $plain --project $project | Out-Null
Remove-Variable plain
# Resend is no longer used; drop its old settings.
dotnet user-secrets remove "Email:ApiKey" --project $project 2>$null | Out-Null
dotnet user-secrets remove "Email:From" --project $project 2>$null | Out-Null
"Saved Email:SmtpUser and Email:SmtpPassword. Restart GameOn (start-public.ps1) to use Gmail."
