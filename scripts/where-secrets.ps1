# Shows where this terminal stores the API's user secrets and which names it holds (never the values).
$p = Join-Path $PSScriptRoot "..\backend"
"APPDATA = $env:APPDATA"
dotnet user-secrets list --verbose --project $p | Select-String "Secrets file path"
(dotnet user-secrets list --project $p) -replace ' = .*', ''
