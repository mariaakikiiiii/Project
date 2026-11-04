# Validation record

Executed in the cloud workspace on 2026-11-04:

- .NET SDK 8.0.427: `dotnet build --no-restore` passed with 0 warnings and 0 errors.
- React/Vite 6.4.5: `npm run build` passed (24 modules transformed).
- `npm audit --audit-level=high`: reported 0 known vulnerabilities across the installed frontend dependency graph.
- `dotnet list package --vulnerable --include-transitive`: reported no known vulnerable packages against its current feeds. An explicit System.Security.Cryptography.Pkcs 8.0.2 reference patches the older transitive dependency.
- API started at local HTTPS with its development certificate. `python3 scripts/security-smoke.py /tmp/gameon-dev.pem` passed: TLS certificate validation, CSRF token issuance, anonymous /auth/me and Join denial, missing-CSRF rejection, and login input validation. This script does not touch SQL Server or validate successful login.

Not executed:

- SQL schema/procedure compilation, 200,000-row seed, invariant tests, two-session concurrency tests and actual execution-plan benchmarks.
- Database-backed API requests, successful registration/login, and browser end-to-end workflows.

SQL Server was not installed. Pulling `mcr.microsoft.com/mssql/server:2022-latest` through the managed Docker daemon failed with `download failed after attempts=6: Forbidden`. No TLS or artifact verification was disabled. No database credentials were requested or created, and no real database connection string was supplied. Run database/01 through 06 with an authorized SQL Server, configure the dedicated API connection securely, and perform the README's functional validation before claiming end-to-end readiness.

Development Data Protection keys in this environment are ephemeral; sessions will invalidate after API restart. Production must configure secure persistent keys. The generated dev certificate and private key are outside the repository and must not be committed.
