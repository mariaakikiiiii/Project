-- Acceptance tests for migration 25 (wallet). DISPOSABLE DATABASE ONLY (name must end in _Tests).
--   sqlcmd -S localhost -E -C -b -d GameOn_Tests -i database\26-wallet-tests.sql
SET NOCOUNT ON; SET XACT_ABORT OFF; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF DB_NAME() NOT LIKE N'%[_]Tests' THROW 50002,'Run these tests only on a disposable *_Tests database.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=25) THROW 50002,'Apply migration 25 to this test database first.',1;
DECLARE @tag nvarchar(12)=LEFT(REPLACE(CONVERT(nvarchar(36),NEWID()),'-',''),10);
DECLARE @t TABLE(Name nvarchar(200),Pass bit);
DECLARE @sink TABLE(a sql_variant,b sql_variant,c sql_variant,d sql_variant,e sql_variant,f sql_variant);
DECLARE @ids TABLE(id int);
DECLARE @ok bit,@H int,@P int,@Q int,@O int,@V int,@G int,@Rev int,@TopUp uniqueidentifier,@W uniqueidentifier,@k uniqueidentifier,@D uniqueidentifier;
DECLARE @future datetime2(3)=DATEADD(day,3,SYSUTCDATETIME()),@ref nvarchar(40)=N'WTOP-'+@tag,@ref2 nvarchar(40)=N'WOUT-'+@tag;
DECLARE @Sport int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes ORDER BY SubtypeId);
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('wh'+@tag+'@gameon.invalid','Wallet host','DISABLED_FIXTURE'); SET @H=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('wp'+@tag+'@gameon.invalid','Wallet player','DISABLED_FIXTURE'); SET @P=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('wq'+@tag+'@gameon.invalid','Wallet player 2','DISABLED_FIXTURE'); SET @Q=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('wo'+@tag+'@gameon.invalid','Wallet operator','DISABLED_FIXTURE'); SET @O=SCOPE_IDENTITY();
INSERT dbo.PaymentOperators(UserId) VALUES(@O);
INSERT dbo.Venues(Name,Area,Address,ListingStatus) VALUES(N'Wallet test pitch '+@tag,N'Testville',N'Pin',N'Unverified'); SET @V=SCOPE_IDENTITY();
INSERT @ids EXEC dbo.CreateGame @HostUserId=@H,@SportId=@Sport,@VenueId=@V,@StartsAt=@future,@Capacity=2,@CostPerPlayer=4; SELECT @G=id FROM @ids; DELETE @ids;
SELECT @Rev=Revision FROM dbo.GamesAndEvents WHERE EventId=@G;
-- Empty wallet cannot pay.
SET @ok=0; SET @k=NEWID(); BEGIN TRY EXEC dbo.JoinWithWallet @GameId=@G,@UserId=@P,@Key=@k,@Revision=@Rev; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50006 THEN 1 ELSE 0 END; END CATCH;
INSERT @t SELECT 'Empty wallet cannot pay and nothing is booked',CASE WHEN @ok=1 AND NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@G AND UserId=@P) AND NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE GameId=@G AND UserId=@P) THEN 1 ELSE 0 END;
-- Top-up: pending until an operator verifies; same key twice = one top-up.
SET @k=NEWID();
INSERT @sink(a,b,c,d,e,f) EXEC dbo.CreateTopUp @UserId=@P,@Key=@k,@Amount=5,@Recipient='+96171364432'; SELECT @TopUp=CONVERT(uniqueidentifier,a) FROM @sink; DELETE @sink;
INSERT @sink(a,b,c,d,e,f) EXEC dbo.CreateTopUp @UserId=@P,@Key=@k,@Amount=5,@Recipient='+96171364432'; DELETE @sink;
INSERT @t SELECT 'Repeated top-up request creates one top-up',CASE WHEN (SELECT COUNT(*) FROM dbo.WalletTopUps WHERE UserId=@P)=1 THEN 1 ELSE 0 END;
INSERT @sink(a,b,c,d) EXEC dbo.SubmitTopUpReference @UserId=@P,@TopUpId=@TopUp,@Reference=@ref; DELETE @sink;
INSERT @t SELECT 'Submitted reference does not credit wallet',CASE WHEN NOT EXISTS(SELECT 1 FROM dbo.WalletAccounts WHERE UserId=@P AND Balance>0) THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewTopUp @OperatorId=@P,@TopUpId=@TopUp,@Decision='VERIFY',@Note=N'self'; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50003 THEN 1 ELSE 0 END; END CATCH;
INSERT @t VALUES('Player cannot verify own top-up',@ok);
EXEC dbo.ReviewTopUp @OperatorId=@O,@TopUpId=@TopUp,@Decision='VERIFY',@Note=N'Seen on Whish statement';
INSERT @t SELECT 'Verified top-up credits wallet once',CASE WHEN (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=5 THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewTopUp @OperatorId=@O,@TopUpId=@TopUp,@Decision='VERIFY',@Note=N'again'; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t SELECT 'Top-up cannot be credited twice',CASE WHEN @ok=1 AND (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=5 THEN 1 ELSE 0 END;
-- Reusing the same Whish reference for another top-up is blocked.
SET @k=NEWID(); INSERT @sink(a,b,c,d,e,f) EXEC dbo.CreateTopUp @UserId=@Q,@Key=@k,@Amount=3,@Recipient='+96171364432'; SELECT @W=CONVERT(uniqueidentifier,a) FROM @sink; DELETE @sink;
SET @ok=0; BEGIN TRY EXEC dbo.SubmitTopUpReference @UserId=@Q,@TopUpId=@W,@Reference=@ref; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Whish reference cannot be reused',@ok);
-- Pay $1 from wallet: seat confirmed instantly; double tap charges once.
SET @k=NEWID();
INSERT @sink(a,b,c) EXEC dbo.JoinWithWallet @GameId=@G,@UserId=@P,@Key=@k,@Revision=@Rev; SELECT @D=CONVERT(uniqueidentifier,b) FROM @sink; DELETE @sink;
INSERT @sink(a,b,c) EXEC dbo.JoinWithWallet @GameId=@G,@UserId=@P,@Key=@k,@Revision=@Rev; DELETE @sink;
INSERT @t SELECT 'Wallet join seats player and holds deposit',CASE WHEN EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@G AND UserId=@P AND DepositStatus='PAID_HELD') AND (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D)='PAID_HELD' THEN 1 ELSE 0 END;
INSERT @t SELECT 'Double tap charges exactly $1',CASE WHEN (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=4 AND (SELECT COUNT(*) FROM dbo.WalletLedger WHERE UserId=@P AND Kind='DepositPayment')=1 THEN 1 ELSE 0 END;
INSERT @t SELECT 'Due now is $1; share + fee stay payable at venue',CASE WHEN (SELECT DueNow FROM dbo.DepositBookings WHERE DepositID=@D)=1 AND EXISTS(SELECT 1 FROM dbo.Payments WHERE GameID=@G AND UserID=@P AND Status='PendingCash' AND Amount=4) THEN 1 ELSE 0 END;
-- Game is now full (capacity 2): another wallet join is refused without charging.
SET @k=NEWID(); INSERT @sink(a,b,c,d,e,f) EXEC dbo.CreateTopUp @UserId=@Q,@Key=@k,@Amount=2,@Recipient='+96171364432'; SELECT @W=CONVERT(uniqueidentifier,a) FROM @sink; DELETE @sink;
INSERT @sink(a,b,c,d) EXEC dbo.SubmitTopUpReference @UserId=@Q,@TopUpId=@W,@Reference=@ref2; DELETE @sink;
EXEC dbo.ReviewTopUp @OperatorId=@O,@TopUpId=@W,@Decision='VERIFY',@Note=N'Seen on statement';
SET @ok=0; SET @k=NEWID(); BEGIN TRY EXEC dbo.JoinWithWallet @GameId=@G,@UserId=@Q,@Key=@k,@Revision=@Rev; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t SELECT 'Full game refuses wallet join without charging',CASE WHEN @ok=1 AND (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@Q)=2 THEN 1 ELSE 0 END;
-- Host cancels: $1 back in wallet immediately, marked refunded with an internal reference.
EXEC dbo.CancelGame @GameId=@G,@HostUserId=@H;
INSERT @t SELECT 'Host cancel returns $1 to wallet instantly',CASE WHEN (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=5 AND (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D)='REFUNDED' THEN 1 ELSE 0 END;
UPDATE dbo.DepositBookings SET ReviewNote=N'touch' WHERE DepositID=@D;
INSERT @t SELECT 'Refund is never credited twice',CASE WHEN (SELECT COUNT(*) FROM dbo.WalletLedger WHERE DepositID=@D AND Kind='DepositRefund')=1 THEN 1 ELSE 0 END;
-- Withdrawals: balance held at request; rejection returns it; over-balance refused.
SET @ok=0; SET @k=NEWID(); BEGIN TRY EXEC dbo.RequestWithdrawal @UserId=@P,@Key=@k,@Amount=50,@WhishNumber='+96171123456'; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50006 THEN 1 ELSE 0 END; END CATCH;
INSERT @t VALUES('Cannot withdraw more than balance',@ok);
SET @k=NEWID(); INSERT @sink(a,b,c,d) EXEC dbo.RequestWithdrawal @UserId=@P,@Key=@k,@Amount=3,@WhishNumber='+96171123456'; SELECT @W=CONVERT(uniqueidentifier,a) FROM @sink; DELETE @sink;
INSERT @t SELECT 'Withdrawal request holds the money',CASE WHEN (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=2 THEN 1 ELSE 0 END;
EXEC dbo.ReviewWithdrawal @OperatorId=@O,@WithdrawalId=@W,@Decision='REJECT',@Note=N'Number did not match account';
INSERT @t SELECT 'Rejected withdrawal returns the money',CASE WHEN (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=5 THEN 1 ELSE 0 END;
SET @k=NEWID(); INSERT @sink(a,b,c,d) EXEC dbo.RequestWithdrawal @UserId=@P,@Key=@k,@Amount=5,@WhishNumber='+96171123456'; SELECT @W=CONVERT(uniqueidentifier,a) FROM @sink; DELETE @sink;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewWithdrawal @OperatorId=@O,@WithdrawalId=@W,@Decision='SENT',@Note=N'sent'; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Sent withdrawal requires the Whish reference',@ok);
EXEC dbo.ReviewWithdrawal @OperatorId=@O,@WithdrawalId=@W,@Decision='SENT',@Reference=@ref2,@Note=N'Sent from GameOn Whish';
INSERT @t SELECT 'Sent withdrawal empties wallet',CASE WHEN (SELECT Balance FROM dbo.WalletAccounts WHERE UserId=@P)=0 AND (SELECT Status FROM dbo.WalletWithdrawals WHERE WithdrawalId=@W)='Sent' THEN 1 ELSE 0 END;
-- Ledger integrity: cached balance always equals the sum of ledger entries.
INSERT @t SELECT 'Every balance equals its ledger sum',CASE WHEN NOT EXISTS(SELECT 1 FROM dbo.WalletAccounts a WHERE a.Balance<>(SELECT COALESCE(SUM(Amount),0) FROM dbo.WalletLedger l WHERE l.UserId=a.UserId)) THEN 1 ELSE 0 END;
SELECT Name, CASE WHEN Pass=1 THEN 'PASS' ELSE 'FAIL' END AS Result FROM @t;
DECLARE @failed int=(SELECT COUNT(*) FROM @t WHERE Pass=0);
IF @failed>0 BEGIN DECLARE @m nvarchar(100)=CONCAT(@failed,' wallet test(s) failed.'); THROW 50099,@m,1; END;
SELECT CONCAT((SELECT COUNT(*) FROM @t),' wallet tests passed') AS Summary;
