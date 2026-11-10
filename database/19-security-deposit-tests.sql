-- Acceptance tests for migration 18 (deposits). DISPOSABLE DATABASE ONLY (name must end in _Tests). No Whish calls.
--   sqlcmd -S localhost -E -C -b -I -d GameOn_Tests -i database9-security-deposit-tests.sql
-- Fixtures stay in the test database. There is no outer transaction on purpose: an expected error (for example a
-- player trying to verify their own deposit) can then be caught without making the whole test uncommittable.
SET NOCOUNT ON; SET XACT_ABORT OFF; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF DB_NAME() NOT LIKE N'%[_]Tests' THROW 50002,'Run these tests only on a disposable *_Tests database.',1;
BEGIN TRY
 -- References must be unique forever, so every run uses its own.
 DECLARE @Run nvarchar(8)=LEFT(CONVERT(nvarchar(36),NEWID()),8);
 DECLARE @R1 nvarchar(100)=N'DEPOSIT-FIXTURE-'+@Run,@R2 nvarchar(100)=N'REFUND-FIXTURE-'+@Run,@R3 nvarchar(100)=N'CASH-DEPOSIT-FIXTURE-'+@Run,
  @R4 nvarchar(100)=N'CANCEL-BEFORE-REVIEW-'+@Run,@R5 nvarchar(100)=N'CANCEL-REFUND-FIXTURE-'+@Run;
 DECLARE @Host int=(SELECT MIN(UserId) FROM dbo.Users),@Type int=(SELECT MIN(SubtypeId) FROM dbo.Subtypes),@Venue int,@Player int,@Operator int,@Game int,@ID uniqueidentifier,@Key uniqueidentifier=NEWID(),@Start datetime2=DATEADD(day,7,SYSUTCDATETIME());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Deposit player fixture',N'DISABLED_FIXTURE'); SET @Player=SCOPE_IDENTITY();
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Deposit operator fixture',N'DISABLED_FIXTURE'); SET @Operator=SCOPE_IDENTITY();
 INSERT dbo.PaymentOperators VALUES(@Operator);
 INSERT dbo.Venues(Name,Area,Address,ContactPhoneNumber,IsVerified) VALUES(N'Deposit test fixture',N'Beirut',N'Not a real venue','+96100000000',1); SET @Venue=SCOPE_IDENTITY();
 EXEC dbo.CreateGame @Host,@Type,@Venue,@Start,2,N'Deposit fixture',2,'USD',0;
 SELECT @Game=MAX(EventId) FROM dbo.GamesAndEvents WHERE HostUserId=@Host;
 IF NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@Game AND RequiresDeposit=1 AND DepositAmount=1) THROW 51000,'New event deposit defaults are wrong.',1;
 IF dbo.PlatformServiceFee(2)<>0.10 THROW 51000,'5% share fee calculation failed.',1;
 EXEC dbo.InitializeDeposit @Game,@Player,1,@Key;
 EXEC dbo.InitializeDeposit @Game,@Player,1,@Key;
 SELECT @ID=DepositID FROM dbo.DepositBookings WHERE UserId=@Player AND IdempotencyKey=@Key;
 IF (SELECT COUNT(*) FROM dbo.DepositBookings WHERE GameId=@Game AND UserId=@Player)<>1 THROW 51000,'Deposit checkout retry duplicated intents.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@ID AND BaseAmount=2 AND ServiceFee=0.10 AND DepositAmount=1 AND TotalAmount=3.10 AND DepositStatus='PENDING') THROW 51000,'Deposit quote mismatch.',1;
 IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@Player) THROW 51000,'Unverified deposit reserved a spot.',1;
 EXEC dbo.SubmitDepositTransfer @ID,@Player,@R1;
 IF (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@ID)<>'PENDING' THROW 51000,'Reference submission falsely marked paid.',1;
 BEGIN TRY
  EXEC dbo.ReviewDeposit @ID,@Player,'VERIFY',N'Unauthorized fixture';
  THROW 51000,'Player was allowed to verify own deposit.',1;
 END TRY BEGIN CATCH IF ERROR_NUMBER()<>50003 THROW; END CATCH;
 EXEC dbo.ReviewDeposit @ID,@Operator,'VERIFY',N'Fixture only: statement reconciled';
 IF NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@Player AND DepositStatus='PAID_HELD' AND DepositPaidAt IS NOT NULL) THROW 51000,'Verified deposit did not reserve a spot.',1;
 IF (SELECT DepositBookingStatus FROM dbo.GamesAndEvents WHERE EventId=@Game)<>'CONFIRMED_DEPOSIT_LOCKED' THROW 51000,'Full event deposit state was not confirmed.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.DepositReviews WHERE DepositID=@ID AND OperatorId=@Operator) THROW 51000,'Deposit review audit missing.',1;
 EXEC dbo.CancelParticipation @Game,@Player;
 -- Rule since migration 22: a player who leaves keeps the deposit HELD and flagged for an operator (no automatic refund or forfeit).
 IF NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@ID AND DepositStatus='PAID_HELD' AND PlayerLeftAt IS NOT NULL AND ReviewNote LIKE N'Player left%') THROW 51000,'Leaving did not flag the deposit for operator review.',1;
 IF (SELECT DepositBookingStatus FROM dbo.GamesAndEvents WHERE EventId=@Game)<>'OPEN_DEPOSITS_PENDING' THROW 51000,'Leaving did not reset full-event status.',1;
 EXEC dbo.ReviewDeposit @ID,@Operator,'REFUND',N'Fixture only: actual external refund recorded',@R2;
 IF (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@ID)<>'REFUNDED' THROW 51000,'Recorded refund state missing.',1;
 SET @Key=NEWID();
 EXEC dbo.InitializeDeposit @Game,@Player,1,@Key,0,'+96171364432','Cash';
 SELECT @ID=DepositID FROM dbo.DepositBookings WHERE UserId=@Player AND IdempotencyKey=@Key;
 IF NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@ID AND DueNow=1.00 AND TotalAmount=3.10 AND PaymentMethod='Cash') THROW 51000,'Cash-share deposit quote mismatch.',1;
 EXEC dbo.SubmitDepositTransfer @ID,@Player,@R3;
 EXEC dbo.ReviewDeposit @ID,@Operator,'VERIFY',N'Fixture only: one dollar received';
 IF NOT EXISTS(SELECT 1 FROM dbo.DepositBookings d JOIN dbo.Payments p ON p.PaymentID=d.PaymentId WHERE d.DepositID=@ID AND p.Status='PendingCash' AND p.TotalAmount=2.10 AND p.FeeRate=0.05) THROW 51000,'Deposit authorization incorrectly marked the cash share paid.',1;
 UPDATE dbo.GamesAndEvents SET StartsAt=DATEADD(hour,-1,SYSUTCDATETIME()) WHERE EventId=@Game;
 -- Rule since migration 22: forfeiture stays disabled until a written no-show policy is approved.
 DECLARE @Refused bit=0;
 BEGIN TRY EXEC dbo.ReviewDeposit @ID,@Operator,'FORFEIT',N'Fixture only: no-show review'; END TRY BEGIN CATCH IF ERROR_NUMBER()=50002 SET @Refused=1; ELSE THROW; END CATCH;
 IF @Refused=0 OR (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@ID)<>'PAID_HELD' THROW 51000,'Forfeiture was allowed without an approved no-show policy.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserActivityLogs WHERE EventId=@Game AND Action='DepositReviewed' AND DepositAmount=1 AND RequiresDeposit=1) THROW 51000,'Deposit analytics snapshot missing.',1;
 -- A cancellation before review still retires a genuinely refunded original reference.
 EXEC dbo.CreateGame @Host,@Type,@Venue,@Start,2,N'Cancelled pending transfer fixture',2,'USD',0;
 SELECT @Game=MAX(EventId) FROM dbo.GamesAndEvents WHERE HostUserId=@Host;
 SET @Key=NEWID();
 EXEC dbo.InitializeDeposit @Game,@Player,1,@Key;
 SELECT @ID=DepositID FROM dbo.DepositBookings WHERE UserId=@Player AND IdempotencyKey=@Key;
 EXEC dbo.SubmitDepositTransfer @ID,@Player,@R4;
 EXEC dbo.CancelGame @Game,@Host;
 EXEC dbo.ReviewDeposit @ID,@Operator,'REFUND',N'Fixture only: original funds checked and external refund completed',@R5;
 IF NOT EXISTS(SELECT 1 FROM dbo.VerifiedWhishTransfers WHERE TransferReference=@R4) THROW 51000,'Refunded original reference could be reused.',1;
 PRINT 'PASS: USD 3.10 quote, deposit defaults, idempotency, pending references, operator authorization/audit, held seat, full confirmation, cancellation and recorded refund.';
END TRY BEGIN CATCH THROW; END CATCH;
GO
