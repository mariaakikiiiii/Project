# GameOn security setup

## One-time setup (each computer that runs the API)

1. Create the secret keys in .NET User Secrets (never in the code, Git or the database), like the connection string:
   ```
   powershell -ExecutionPolicy Bypass -File scripts/new-secrets.ps1
   ```
   `Security:PasswordPepper` is required. `Security:MessageKey` is only needed once, to move messages that
   migration 33 encrypted into SQL Server encryption. **Back them up** privately (`dotnet user-secrets list --project backend`).
2. In SSMS, with your Windows login, install in order: `database/33-security-hardening.sql`,
   `database/34-db-hardening.sql`, `database/35-court-booking-performance.sql`. Then start the API.
3. **Back up the message-encryption certificate** (without it, a restored backup cannot decrypt chats).
   In SSMS, choose your own strong password and a folder SQL Server can write to:
   ```sql
   USE GameOn;
   BACKUP CERTIFICATE GameOnMessageCert TO FILE = 'C:\GameOnKeys\GameOnMessageCert.cer'
     WITH PRIVATE KEY (FILE = 'C:\GameOnKeys\GameOnMessageCert.pvk', ENCRYPTION BY PASSWORD = '<your strong password>');
   BACKUP MASTER KEY TO FILE = 'C:\GameOnKeys\GameOn.dmk' ENCRYPTION BY PASSWORD = '<your strong password>';
   ```
4. Optional, for phones and other PCs on your network: `powershell -ExecutionPolicy Bypass -File scripts/lan-cert.ps1`,
   then `npm run dev` listens on all addresses over HTTPS. Allow Node.js through the firewall on **private** networks only.

## What protects what

| Area | Protection |
|---|---|
| Passwords | **Argon2id** (19 MiB, 2 passes): a random 16-byte salt per password, stored inside the hash string (`$argon2id$v=19$m=19456,t=2,p=1$salt$hash`), so no salt column. The pepper from User Secrets is Argon2's secret input. Older hashes are upgraded at the next sign-in. |
| Chat messages | Encrypted **by SQL Server**: AES-256 symmetric key `GameOnMessageKey`, protected by certificate `GameOnMessageCert`, protected by the database master key. `SendMessage` uses `ENCRYPTBYKEY`; reads use `DECRYPTBYKEYAUTOCERT`. The conversation id is the authenticator, so a ciphertext copied to another chat does not decrypt. A CHECK constraint refuses plain text. `gameon_api` cannot open the key itself: only the procedures (`EXECUTE AS OWNER`) can. |
| Money | Moves only in stored procedures. Triggers only check (wallet balance = ledger sum, append-only ledger) or log. See `docs/KEY-TRANSACTIONS.md`. |
| Network | HTTPS only. Without the LAN certificate the site stays on this PC. |
| Database access | The API logs in as `gameon_api`, which can only EXECUTE stored procedures. All values are typed `SqlParameter`s. |
| Sessions | HttpOnly, Secure, SameSite=Strict cookies; CSRF token on every change; rate limits; suspended users are signed out everywhere. |

## Limits (be honest about these)

- Messages are encrypted **at rest**, not end-to-end: a database owner (sysadmin) can decrypt them.
- The LAN certificate is self-signed; for the internet you need a real domain and a trusted certificate.
- No external penetration test has been done.
