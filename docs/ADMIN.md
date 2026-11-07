# GameOn admin panel (migration 31)

## Install

1. Stop the API (Visual Studio) and the website (Ctrl+C). Back up GameOn in SSMS.
2. SSMS → `database\31-admin.sql` → **F5** → `Migration 31 completed successfully` (needs 29).
   Run it **before** starting the new API: the new sign-in reads the account status added by this migration.
3. Make yourself the first admin. In SSMS, **New Query**, replace the email with yours, press **F5**:

```sql
USE GameOn;
INSERT dbo.Admins(UserId) SELECT UserId FROM dbo.Users WHERE Email = 'your-email@example.com' AND NOT EXISTS(SELECT 1 FROM dbo.Admins a WHERE a.UserId = dbo.Users.UserId);
SELECT u.UserId, u.Email FROM dbo.Admins a JOIN dbo.Users u ON u.UserId = a.UserId;
```

4. Start the API (F5) and the website (`npm run dev`). Everyone signs in once more (sessions now carry a security stamp).
5. Open **Me → Admin panel**.

After this, add or remove admins from the panel itself. SSMS is only needed for the very first admin.

## What you can do

| Tab | Actions |
|---|---|
| Overview | Players (active, new, signed in this week, suspended), upcoming games and court bookings, clubs, money held in wallets and for clubs, top-ups to check, open disputes, reported photos |
| Users | Search by name, email or ID. **Suspend** (with a reason; the player is signed out everywhere at once and sees "account suspended"), **Restore**, **Delete**, **Make/remove operator**, **Make/remove admin** |
| App settings | Announcement banner on every page; sign-ups open/closed; Shots on/off; Pro price; support email. Changes are live within 30 seconds |
| Photo reports | Hide reported photos, or restore them (which clears the reports) |
| Audit log | Every admin action: who, what, on whom, when |

### Safety rules (enforced in the database)

- Only admins can use the panel. Nobody can make themselves admin.
- You can't suspend or delete yourself, and the last admin can't be removed.
- An admin must lose the admin role before they can be suspended or deleted.
- **Delete** erases name, email, birth date, sports, friends, groups, photos, coach profile and message text. Games, bookings and payments stay as anonymous records, so the money history stays correct. Their upcoming hosted games are cancelled (players are notified and refunded by the usual rules).
- Delete is refused while the user has money in their wallet, a withdrawal waiting, open deposits, paid upcoming court bookings, or owns a club. Settle those first: money never disappears.
- Deleted accounts can't be restored. Suspended ones can.

## Roles

- **Admin**: this panel (users, settings, moderation).
- **Operator**: money operations (verify top-ups and deposits, refunds, disputes, club payouts, onboarding clubs). Give yourself this role in Users if you handle payments too.
- **Club staff**: Owner / Manager / Reception / Coach, managed by each club owner.

## Security improvement included

Each account now has a secret session stamp. A sign-in cookie is only valid for the exact account it was issued to. This closes the gap where, after restoring a database backup, an old cookie could match a different account with the same ID.
