# Creates the API's two secret keys in .NET User Secrets (outside the repository). Safe to run again:
# an existing key is NEVER replaced, because a new message key would make stored chat messages unreadable
# and a new pepper would make every password fail. Back these values up somewhere private.
$project = Join-Path $PSScriptRoot "..\backend"
$existing = dotnet user-secrets list --project $project 2>$null
foreach ($name in "Security:PasswordPepper", "Security:MessageKey") {
    if ($existing -match [regex]::Escape($name)) { Write-Host "$name already set (kept)"; continue }
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    dotnet user-secrets set $name ([Convert]::ToBase64String($bytes)) --project $project | Out-Null
    Write-Host "$name created"
}
