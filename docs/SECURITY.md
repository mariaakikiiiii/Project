# GameOn security setup

## One-time setup (each computer that runs the API)

1. Create the two secret keys (stored in .NET User Secrets, never in Git or the database):
   ```
   powershell -ExecutionPolicy Bypass -File scripts/new-secrets.ps1
   ```
   **Back up** `Security:PasswordPepper` and `Security:MessageKey` (`dotnet user-secrets list --project backend`)
   somewhere private. If they are lost, passwords stop working and chat messages cannot be read.
2. Install `database/33-security-hardening.sql` in SSMS (needs migration 31), **before** starting the new API.
3. Optional, to use GameOn from phones or other PCs on your network:
   ```
   powershell -ExecutionPolicy Bypass -File scripts/lan-cert.ps1
   ```
   Then `npm run dev` listens on all network addresses over HTTPS (for example `https://192.168.11.1:5173`).
   Windows may ask to allow Node.js through the firewall: allow it on **private** networks only.
   The certificate is self-signed, so each device shows a warning the first time.

## What protects what

| Area | Protection |
|---|---|
| Passwords | PBKDF2-HMAC-SHA512, 210,000 iterations, a unique random 128-bit **salt** per password, plus a secret **pepper** (HMAC-SHA256 key outside the database). Older hashes are upgraded automatically at the next sign-in. |
| Chat messages | Encrypted by the API with **AES-256-GCM** before they reach SQL Server; the database stores only `enc1:` ciphertext and refuses plain text. Each message is tied to its conversation, so moving it to another chat does not reveal it. Older messages are encrypted automatically when the API starts. |
| Network | HTTPS only. Without the LAN certificate the site stays on this PC; it never listens on the network over plain HTTP. |
| Database access | The API logs in as `gameon_api`, which can only EXECUTE stored procedures. All values are typed `SqlParameter`s. |
| Sessions | HttpOnly, Secure, SameSite=Strict cookies; CSRF token on every change; rate limits; suspended users are signed out everywhere. |

## Limits (be honest about these)

- Messages are encrypted **at rest**, not end-to-end: the API server holds the key, so whoever controls the server can read them.
- The LAN certificate is self-signed; for the internet you need a real domain and a trusted certificate.
- No external penetration test has been done.
