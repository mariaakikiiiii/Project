"""One-off generator for scripts/migration-bodies/34-db-hardening.sql.txt.
Reads the CURRENT module definitions (exported from the database to a folder) and applies small,
asserted edits, so the new versions differ from the installed ones only where intended.
Usage: python scripts/gen-34.py <folder with exported .sql definitions>
"""
import sys, pathlib, re
D = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(__file__).resolve().parent / 'migration-bodies' / '34-db-hardening.sql.txt'

def get(name):
    t = (D / f'{name}.sql').read_text(encoding='utf-8').replace('\r\n', '\n').strip()
    t = re.sub(r'^CREATE\s+PROCEDURE', 'CREATE OR ALTER PROCEDURE', t, count=1)
    assert t.startswith('CREATE OR ALTER PROCEDURE'), name
    return t

def edit(text, old, new, name):
    assert text.count(old) == 1, f'{name}: expected exactly one match for {old[:70]!r} (found {text.count(old)})'
    return text.replace(old, new)

SETTLE_NOTE = '-- Money movement is explicit here (it used to be hidden in triggers).'
mods = []

# ---------------- 1. Money out of triggers ----------------
p = get('CancelGame')
p = edit(p, "   EXEC dbo.RefreshDepositEvent @GameId;\n  END;",
"""   """ + SETTLE_NOTE + """
   UPDATE dbo.Payments SET Status='RefundReview',ReviewNote=N'Event cancelled. Check Whish statement and arrange any refund manually.'
   WHERE GameID=@GameId AND Mode='WhishManual' AND Status<>'Cancelled';
   EXEC dbo.SettleWalletDepositRefunds @GameId;
   EXEC dbo.RefreshDepositEvent @GameId;
  END;""", 'CancelGame')
mods.append(p)

p = get('CancelParticipation')
p = edit(p, "   WHERE GameID=@GameId AND UserID=@UserId AND Status IN('PendingCash','MockPending','MockSucceeded');\n",
"""   WHERE GameID=@GameId AND UserID=@UserId AND Status IN('PendingCash','MockPending','MockSucceeded');
   """ + SETTLE_NOTE + """
   UPDATE dbo.Payments SET Status='RefundReview',ReviewNote=N'Booking removed. Check Whish statement and arrange any refund manually.'
   WHERE GameID=@GameId AND UserID=@UserId AND Mode='WhishManual' AND Status<>'Cancelled';
""", 'CancelParticipation')
p = edit(p, "  EXEC dbo.RefreshDepositEvent @GameId;\n  COMMIT;",
         "  EXEC dbo.SettleWalletDepositRefunds @GameId;\n  EXEC dbo.RefreshDepositEvent @GameId;\n  COMMIT;", 'CancelParticipation')
mods.append(p)

p = get('EvaluateAttendance')
p = edit(p, "-- Caller owns the transaction and the event lock. Money never moves here: at most a refund is queued.",
         "-- Caller owns the transaction and the event lock. Wallet-paid refunds and points are settled explicitly at the end.", 'EvaluateAttendance')
assert p.endswith('\nEND;')
p = p[:-len('END;')] + """ -- Points only when the host AND the player both confirm (was trigger LoyaltyGamePlayed). LoyaltyPost is idempotent.
 DECLARE @PointsUser int;
 DECLARE pts CURSOR LOCAL FAST_FORWARD FOR SELECT a.UserId FROM dbo.EventAttendance a WHERE a.GameId=@GameId AND a.HostMark='Attended' AND a.PlayerMark='Attended';
 OPEN pts; FETCH NEXT FROM pts INTO @PointsUser;
 WHILE @@FETCH_STATUS=0 BEGIN EXEC dbo.LoyaltyPost @PointsUser,50,'GamePlayed','Game',@GameId,N'Played a GameOn game'; FETCH NEXT FROM pts INTO @PointsUser; END;
 CLOSE pts; DEALLOCATE pts;
 EXEC dbo.SettleWalletDepositRefunds @GameId;
END;"""
mods.append(p)

for name in ('ResolveDispute', 'ReviewDeposit'):
    p = get(name)
    p = edit(p, "  EXEC dbo.RefreshDepositEvent @Game;\n  COMMIT;",
             "  EXEC dbo.SettleWalletDepositRefunds @Game;\n  EXEC dbo.RefreshDepositEvent @Game;\n  COMMIT;", name)
    mods.append(p)

p = get('RegisterForClass')
p = edit(p, "   UPDATE dbo.ClassRegistrations SET Status='Cancelled' WHERE ClassId=@ClassId AND UserId=@UserId AND Status<>'Cancelled';\n   IF @@ROWCOUNT=1\n",
"""   DECLARE @WasRegistered bit=IIF(EXISTS(SELECT 1 FROM dbo.ClassRegistrations WHERE ClassId=@ClassId AND UserId=@UserId AND Status='Registered'),1,0);
   UPDATE dbo.ClassRegistrations SET Status='Cancelled' WHERE ClassId=@ClassId AND UserId=@UserId AND Status<>'Cancelled';
   DECLARE @Changed int=@@ROWCOUNT;
   IF @WasRegistered=1 EXEC dbo.ReturnClassCredit @ClassId,@UserId; -- was trigger ClassPackCreditReturn
   IF @Changed=1
""", 'RegisterForClass')
mods.append(p)

p = get('AdminDeleteUser')
p = edit(p, "  DELETE p FROM dbo.Participations p JOIN dbo.GamesAndEvents e ON e.EventId=p.GameId WHERE p.UserId=@UserId AND e.StartsAt>SYSUTCDATETIME() AND e.HostUserId<>@UserId;\n",
"""  DECLARE @LeftGames TABLE(GameId int PRIMARY KEY);
  DELETE p OUTPUT deleted.GameId INTO @LeftGames FROM dbo.Participations p JOIN dbo.GamesAndEvents e ON e.EventId=p.GameId WHERE p.UserId=@UserId AND e.StartsAt>SYSUTCDATETIME() AND e.HostUserId<>@UserId;
  """ + SETTLE_NOTE + """
  UPDATE p SET Status='RefundReview',ReviewNote=N'Booking removed. Check Whish statement and arrange any refund manually.'
  FROM dbo.Payments p JOIN @LeftGames l ON l.GameId=p.GameID WHERE p.UserID=@UserId AND p.Mode='WhishManual' AND p.Status<>'Cancelled';
  UPDATE g SET DepositBookingStatus='OPEN_DEPOSITS_PENDING' FROM dbo.GamesAndEvents g JOIN @LeftGames l ON l.GameId=g.EventId;
""", 'AdminDeleteUser')
p = edit(p, "  UPDATE r SET Status='Cancelled' FROM dbo.ClassRegistrations r JOIN dbo.Classes c ON c.ClassId=r.ClassId WHERE r.UserId=@UserId AND r.Status<>'Cancelled' AND c.StartsAt>SYSUTCDATETIME();\n",
"""  DECLARE @PaidClasses TABLE(ClassId int PRIMARY KEY);
  INSERT @PaidClasses SELECT r.ClassId FROM dbo.ClassRegistrations r JOIN dbo.Classes c ON c.ClassId=r.ClassId WHERE r.UserId=@UserId AND r.Status='Registered' AND c.StartsAt>SYSUTCDATETIME();
  UPDATE r SET Status='Cancelled' FROM dbo.ClassRegistrations r JOIN dbo.Classes c ON c.ClassId=r.ClassId WHERE r.UserId=@UserId AND r.Status<>'Cancelled' AND c.StartsAt>SYSUTCDATETIME();
  DECLARE @Cl int;
  WHILE EXISTS(SELECT 1 FROM @PaidClasses) BEGIN SELECT TOP(1) @Cl=ClassId FROM @PaidClasses; EXEC dbo.ReturnClassCredit @Cl,@UserId; DELETE @PaidClasses WHERE ClassId=@Cl; END;
""", 'AdminDeleteUser')
p = edit(p, "UPDATE dbo.Messages SET Body=N'(message from a deleted account)' WHERE SenderId=@UserId;",
         "UPDATE dbo.Messages SET Body=N'(message from a deleted account)',BodyCipher=NULL WHERE SenderId=@UserId;", 'AdminDeleteUser')
mods.append(p)

# ---------------- 2. Wallet writers announce themselves to the balance check ----------------
for name in ('WalletPost', 'WalletDebit', 'BuyPro'):
    p = get(name)
    i = p.index('UPDATE dbo.WalletAccounts SET'); j = p.index('INSERT dbo.WalletLedger'); k = p.index(';', p.index('VALUES', j)) + 1
    indent = p[p.rindex('\n', 0, i) + 1:i]
    p = (p[:i] + "EXEC sys.sp_set_session_context @key=N'GameOn.WalletPosting',@value=1;\n" + indent + p[i:k] +
         "\n" + indent + "EXEC sys.sp_set_session_context @key=N'GameOn.WalletPosting',@value=NULL;" + p[k:])
    mods.append(p)

# ---------------- 3. Messages: SQL Server encryption ----------------
p = get('SendMessage')
p = re.sub(r'@Body nvarchar\(max\),@ClientKey uniqueidentifier AS', '@Body nvarchar(1000),@ClientKey uniqueidentifier WITH EXECUTE AS OWNER AS', p, count=1)
p = edit(p, "-- Migration 33: the API sends only AES-GCM ciphertext; plain text is refused so it can never be stored by mistake.\n IF @Body IS NULL OR LEFT(@Body,5)<>'enc1:' OR LEN(@Body) NOT BETWEEN 33 AND 6000 THROW 50002,'Write a message (up to 1000 characters).',1;",
         "IF @Body IS NULL OR LEN(@Body) NOT BETWEEN 1 AND 1000 THROW 50002,'Write a message (up to 1000 characters).',1;", 'SendMessage')
p = edit(p, "   INSERT dbo.Messages(ConversationId,SenderId,Body,ClientKey) VALUES(@ConversationId,@UserId,@Body,@ClientKey);",
"""   -- Encrypted by SQL Server: AES-256 symmetric key, protected by a certificate (never stored in the app or in Git).
   -- The conversation id is the authenticator, so a ciphertext copied into another chat will not decrypt.
   OPEN SYMMETRIC KEY GameOnMessageKey DECRYPTION BY CERTIFICATE GameOnMessageCert;
   INSERT dbo.Messages(ConversationId,SenderId,Body,BodyCipher,ClientKey)
   VALUES(@ConversationId,@UserId,NULL,ENCRYPTBYKEY(KEY_GUID(N'GameOnMessageKey'),@Body,1,CONVERT(varbinary(8),@ConversationId)),@ClientKey);
   CLOSE SYMMETRIC KEY GameOnMessageKey;""", 'SendMessage')
DEC = "CONVERT(nvarchar(1000),COALESCE(m.Body,CONVERT(nvarchar(1000),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,m.BodyCipher,1,CONVERT(varbinary(8),m.ConversationId)))))"
p = edit(p, "u.DisplayName AS SenderName,m.Body,m.CreatedAt", f"u.DisplayName AS SenderName,{DEC} AS Body,m.CreatedAt", 'SendMessage')
p = edit(p, "BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;",
         "BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;", 'SendMessage')
mods.append(p)

p = get('GetMessages')
p = p.replace('@BeforeId bigint=NULL AS', '@BeforeId bigint=NULL WITH EXECUTE AS OWNER AS', 1)
p = edit(p, "u.DisplayName AS SenderName,m.Body,m.CreatedAt", f"u.DisplayName AS SenderName,{DEC} AS Body,m.CreatedAt", 'GetMessages')
mods.append(p)

p = get('ListConversations')
p = p.replace('@UserId int AS', '@UserId int WITH EXECUTE AS OWNER AS', 1)
p = edit(p, "(SELECT TOP(1) m.Body FROM dbo.Messages m", f"(SELECT TOP(1) LEFT({DEC},80) FROM dbo.Messages m", 'ListConversations')
mods.append(p)

body = open(pathlib.Path(__file__).resolve().parent / 'migration-bodies' / '34-static.sql.txt', encoding='utf-8').read()
body = body.replace('-- @@GENERATED_MODULES@@', '\nGO\n'.join(mods))
OUT.write_text(body, encoding='utf-8', newline='\n')
print('wrote', OUT, len(mods), 'modified modules')
