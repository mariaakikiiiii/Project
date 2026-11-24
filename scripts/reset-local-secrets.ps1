# Creates fresh local secrets for the API in YOUR user-secret store. Values are generated here and never printed.
#  1. New random password for the SQL login gameon_api (changed with your Windows admin login) + the connection string.
#  2. New Security:PasswordPepper and Security:MessageKey (via new-secrets.ps1).
# Effect: accounts created before this can no longer sign in with their old password (sign up again or reset it).
# Email:SmtpUser, Email:SmtpPassword and App:PublicOrigin are kept.
$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "..\backend"
$sqlcmd = (Get-Command sqlcmd -ErrorAction SilentlyContinue).Source
if (-not $sqlcmd) { $sqlcmd = "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE" }

# 1. Database password: 24 random letters/digits + symbols that need no escaping in SQL or connection strings.
$chars = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
$bytes = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })) + "#9aZ"
& $sqlcmd -S localhost -E -b -Q "ALTER LOGIN gameon_api WITH PASSWORD = N'$password';" | Out-Null
if ($LASTEXITCODE) { throw "Could not change the gameon_api password (run this as the Windows user that installed SQL Server)." }
dotnet user-secrets set "ConnectionStrings:GameOn" "Server=localhost;Database=GameOn;User Id=gameon_api;Password=$password;Encrypt=True;TrustServerCertificate=True" --project $project | Out-Null
Remove-Variable password
"ConnectionStrings:GameOn saved (new gameon_api password)"

# 2. Pepper and message key: replace whatever is there with new random values.
dotnet user-secrets remove "Security:PasswordPepper" --project $project 2>$null | Out-Null
dotnet user-secrets remove "Security:MessageKey" --project $project 2>$null | Out-Null
& (Join-Path $PSScriptRoot "new-secrets.ps1")

"Secrets now stored (names only):"
(dotnet user-secrets list --project $project) -replace ' = .*', ''
