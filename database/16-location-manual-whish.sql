-- Run the WHOLE file in a NEW SSMS query using your migration/Windows identity.
-- Ordinary SSMS mode works. No SQLCMD Mode or : commands are needed.
-- Back up GameOn and stop the API before applying this migration.
USE GameOn;
GO
IF @@TRANCOUNT<>0 THROW 50002,'Open a fresh query with no active transaction.',1;
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
BEGIN TRY
 BEGIN TRANSACTION;
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=13) THROW 50002,'Install migration 13 first.',1;
 IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=16) THROW 50002,'Migration 16 is already recorded. If a previous attempt failed, use its repair guide instead of rerunning it.',1;
 IF OBJECT_ID(N'dbo.Payments',N'U') IS NULL OR COL_LENGTH(N'dbo.Waitlists',N'AcceptedServiceFee') IS NULL THROW 50002,'Migration 13 schema is incomplete. Use 16-repair-partial-install.sql first.',1;
 EXEC(N'ALTER TABLE dbo.Venues ADD Latitude decimal(10,7) NULL,Longitude decimal(10,7) NULL,GooglePlaceId nvarchar(255) NULL;');
 EXEC(N'ALTER TABLE dbo.Venues ADD CONSTRAINT CK_Venues_Coordinates CHECK((Latitude IS NULL AND Longitude IS NULL) OR (Latitude IS NOT NULL AND Longitude IS NOT NULL AND Latitude BETWEEN 33 AND 34.8 AND Longitude BETWEEN 35 AND 36.7));');
 EXEC(N'ALTER TABLE dbo.Payments ADD RecipientNumber nvarchar(20) NULL,TransferReference nvarchar(100) NULL,ReviewNote nvarchar(400) NULL;');
 EXEC(N'ALTER TABLE dbo.Payments DROP CONSTRAINT CK_Payments_Mode,CK_Payments_State;');
 EXEC(N'ALTER TABLE dbo.Payments ADD CONSTRAINT CK_Payments_Mode CHECK(Mode IN(''Cash'',''WhishMock'',''WhishManual'')),
 CONSTRAINT CK_Payments_State CHECK((Mode=''Cash'' AND Status IN(''PendingCash'',''Cancelled'')) OR
 (Mode=''WhishMock'' AND Status IN(''MockPending'',''MockSucceeded'',''MockFailed'',''Expired'',''Cancelled'',''MockCancelled'')) OR
 (Mode=''WhishManual'' AND Status IN(''AwaitingTransfer'',''AwaitingVerification'',''VerifiedManual'',''Rejected'',''RefundReview'',''Cancelled'')));');
 EXEC(N'ALTER TABLE dbo.Participations DROP CONSTRAINT CK_Participations_Payment;');
 EXEC(N'ALTER TABLE dbo.Participations ADD CONSTRAINT CK_Participations_Payment CHECK(PaymentMethod IN(''Cash'',''Whish'',''WhishMock'',''WhishManual''));');
 EXEC(N'CREATE TABLE dbo.PaymentOperators(UserId int CONSTRAINT PK_PaymentOperators PRIMARY KEY REFERENCES dbo.Users(UserId));');
 EXEC(N'CREATE TABLE dbo.VerifiedWhishTransfers(TransferReference nvarchar(100) CONSTRAINT PK_VerifiedWhishTransfers PRIMARY KEY,PaymentId uniqueidentifier NOT NULL CONSTRAINT UQ_VerifiedWhishPayment UNIQUE REFERENCES dbo.Payments(PaymentID));');
 EXEC(N'CREATE TABLE dbo.PaymentReviews(ReviewId bigint IDENTITY PRIMARY KEY,PaymentId uniqueidentifier NOT NULL REFERENCES dbo.Payments(PaymentID),
 OperatorId int NOT NULL REFERENCES dbo.Users(UserId),Decision varchar(20) NOT NULL,Note nvarchar(400) NOT NULL,CreatedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME());');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.InitializeCheckout
 @GameId int,@UserId int,@Mode varchar(12),@IdempotencyKey uniqueidentifier,@ExpectedRevision int,@Recipient nvarchar(20)=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Cost decimal(12,2),@Currency char(3),@Revision int,@Capacity int,@Start datetime2(3),@State varchar(12),@ID uniqueidentifier;
  SELECT @Cost=CostPerPlayer,@Currency=Currency,@Revision=Revision,@Capacity=Capacity,@Start=StartsAt,@State=GameStatus
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Cost IS NULL THROW 50001,''Event not found.'',1;
  IF @Mode NOT IN(''Cash'',''WhishMock'',''WhishManual'') OR @Mode IS NULL OR @IdempotencyKey IS NULL THROW 50002,''Invalid checkout.'',1;
  SELECT @ID=PaymentID FROM dbo.Payments WHERE UserID=@UserId AND IdempotencyKey=@IdempotencyKey;
  IF @ID IS NOT NULL
  BEGIN
   IF NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@ID AND GameID=@GameId AND Mode=@Mode) THROW 50004,''Checkout key was used for a different booking.'',1;
  END
  ELSE
  BEGIN
   IF @ExpectedRevision IS NULL OR @ExpectedRevision<>@Revision THROW 50004,''Event changed. Review the latest fee quote.'',1;
   IF @State<>''Open'' OR @Start<=SYSUTCDATETIME() THROW 50002,''Event is no longer open.'',1;
   IF @Mode IN(''Cash'',''WhishManual'')
   BEGIN
    IF @Mode=''WhishManual'' AND EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId) THROW 50004,''You already have a booking. Open Payments to review it.'',1;
    IF @Mode=''WhishManual'' AND (@Recipient IS NULL OR @Recipient<>N''+96171364432'') THROW 50002,''Manual Whish recipient is unavailable.'',1;
    DECLARE @OutcomeStatus varchar(20);
    EXEC dbo.sp_JoinGameOrActivity @GameId=@GameId,@UserId=@UserId,@PaymentMethod=''Cash'',@CashIdempotencyKey=@IdempotencyKey,@ResultStatus=@OutcomeStatus OUTPUT,@ReturnResult=0;
    SELECT TOP(1) @ID=PaymentID FROM dbo.Payments WHERE GameID=@GameId AND UserID=@UserId AND Status IN(''PendingCash'',''MockSucceeded'') ORDER BY CreatedAt DESC;
    IF @ID IS NULL
    BEGIN
     COMMIT;
     SELECT @OutcomeStatus AS Status,CAST(NULL AS uniqueidentifier) AS PaymentId,
      @Cost AS Amount,dbo.PlatformServiceFee(@Cost) AS ServiceFee,@Cost+dbo.PlatformServiceFee(@Cost) AS TotalAmount,@Currency AS Currency,''Cash'' AS Mode;
     RETURN;
    END;
    IF @Mode=''WhishManual''
    BEGIN
     IF NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@ID AND Status=''PendingCash'') THROW 50004,''Booking already settled.'',1;
     UPDATE dbo.Payments SET Mode=''WhishManual'',Status=''AwaitingTransfer'',RecipientNumber=@Recipient WHERE PaymentID=@ID;
     UPDATE dbo.Participations SET PaymentMethod=''WhishManual'' WHERE GameId=@GameId AND UserId=@UserId;
    END;
   END
   ELSE
   BEGIN
    IF @Cost<=0 THROW 50002,''Free places do not require a payment checkout.'',1;
    IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId)
     OR EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId) THROW 50004,''You are already enrolled or queued.'',1;
    IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)>=@Capacity THROW 50004,''Event is full. Join the waitlist without payment.'',1;
    UPDATE dbo.Payments SET Status=''Expired'' WHERE GameID=@GameId AND UserID=@UserId AND Status=''MockPending'' AND (ExpiresAt<=SYSUTCDATETIME() OR EventRevision<>@Revision);
    SELECT @ID=PaymentID FROM dbo.Payments WHERE GameID=@GameId AND UserID=@UserId AND Status=''MockPending'';
    IF @ID IS NULL
    BEGIN
     SET @ID=NEWID();
     INSERT dbo.Payments(PaymentID,UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision,ExpiresAt)
      VALUES(@ID,@UserId,@GameId,@Cost,dbo.PlatformServiceFee(@Cost),@Currency,''WhishMock'',''MockPending'',@IdempotencyKey,@Revision,DATEADD(minute,10,SYSUTCDATETIME()));
    END;
   END;
  END;
  COMMIT;
  SELECT PaymentID AS PaymentId,GameID AS GameId,Amount,ServiceFee,TotalAmount,Currency,Mode,Status,GatewayTransactionID AS GatewayTransactionId,CreatedAt,ExpiresAt,RecipientNumber,TransferReference,ReviewNote FROM dbo.Payments WHERE PaymentID=@ID;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetPayment @PaymentID uniqueidentifier,@UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT PaymentID AS PaymentId,GameID AS GameId,Amount,ServiceFee,TotalAmount,Currency,Mode,Status,GatewayTransactionID AS GatewayTransactionId,CreatedAt,ExpiresAt,RecipientNumber,TransferReference,ReviewNote
 FROM dbo.Payments WHERE PaymentID=@PaymentID AND UserID=@UserId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.SubmitWhishTransfer @PaymentID uniqueidentifier,@UserId int,@Reference nvarchar(100) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Game int;
 SELECT @Game=GameID FROM dbo.Payments WHERE PaymentID=@PaymentID AND UserID=@UserId AND Mode=''WhishManual'';
 IF @Game IS NULL THROW 50001,''Payment not found.'',1;
 DECLARE @State varchar(12);
 SELECT @State=GameStatus FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@Game;
 IF LEN(TRIM(@Reference))<4 OR LEN(@Reference)>100 THROW 50002,''Enter the transfer reference from Whish.'',1;
 IF EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@PaymentID AND Status=''AwaitingVerification'' AND TransferReference=@Reference)
 BEGIN COMMIT; EXEC dbo.GetPayment @PaymentID,@UserId; RETURN; END;
 IF @State<>''Open'' OR NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@UserId)
  THROW 50004,''Booking is no longer active. Contact support if you transferred money.'',1;
 UPDATE dbo.Payments SET TransferReference=TRIM(@Reference),Status=''AwaitingVerification'',ReviewNote=NULL
 WHERE PaymentID=@PaymentID AND Status IN(''AwaitingTransfer'',''Rejected'');
 IF @@ROWCOUNT=0 THROW 50004,''Payment is already submitted or settled.'',1;
 COMMIT;
 EXEC dbo.GetPayment @PaymentID,@UserId;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetMyPayments @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(100) p.PaymentID AS PaymentId,p.GameID AS GameId,p.Amount,p.ServiceFee,p.TotalAmount,p.Currency,p.Mode,p.Status,
 p.RecipientNumber,p.TransferReference,p.ReviewNote,p.CreatedAt,s.Name AS Sport,v.Name AS Venue
 FROM dbo.Payments p JOIN dbo.GamesAndEvents g ON g.EventId=p.GameID JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId
 JOIN dbo.Venues v ON v.VenueId=g.VenueId WHERE p.UserID=@UserId ORDER BY p.CreatedAt DESC,p.PaymentID;
 SELECT CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THEN 1 ELSE 0 END AS bit) AS CanReview;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ListWhishReviews @UserId int AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Payment operator access required.'',1;
 SELECT TOP(100) p.PaymentID AS PaymentId,p.GameID AS GameId,p.TotalAmount,p.Currency,p.Status,p.TransferReference,p.RecipientNumber,
 p.CreatedAt,u.DisplayName,p.ReviewNote FROM dbo.Payments p JOIN dbo.Users u ON u.UserId=p.UserID
 WHERE p.Mode=''WhishManual'' AND p.Status IN(''AwaitingVerification'',''RefundReview'') ORDER BY p.CreatedAt;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ReviewWhishTransfer @PaymentID uniqueidentifier,@UserId int,@Decision varchar(20),@Note nvarchar(400) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Payment operator access required.'',1;
 IF @Decision NOT IN(''VerifiedManual'',''Rejected'',''RefundReview'') OR LEN(TRIM(@Note))<4 THROW 50002,''Enter a review decision and reconciliation note.'',1;
 BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Game int,@Owner int,@State varchar(12),@PaymentState varchar(24);
 SELECT @Game=GameID,@Owner=UserID FROM dbo.Payments WHERE PaymentID=@PaymentID AND Mode=''WhishManual'';
 IF @Game IS NULL THROW 50001,''Payment not found.'',1;
 SELECT @State=GameStatus FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@Game;
 SELECT @PaymentState=Status FROM dbo.Payments WITH(UPDLOCK,HOLDLOCK) WHERE PaymentID=@PaymentID;
 IF @PaymentState NOT IN(''AwaitingVerification'',''RefundReview'') THROW 50004,''Payment already reviewed.'',1;
 IF @Decision=''VerifiedManual'' AND (@PaymentState=''RefundReview'' OR @State<>''Open'' OR NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@Owner))
  THROW 50004,''Inactive booking requires refund review.'',1;
 IF @Decision=''VerifiedManual''
 BEGIN
  DECLARE @Reference nvarchar(100)=(SELECT TransferReference FROM dbo.Payments WHERE PaymentID=@PaymentID);
  IF @Reference IS NULL THROW 50002,''A transfer reference is required.'',1;
  INSERT dbo.VerifiedWhishTransfers(TransferReference,PaymentId) VALUES(@Reference,@PaymentID);
 END;
 UPDATE dbo.Payments SET Status=@Decision,ReviewNote=TRIM(@Note),CompletedAt=CASE WHEN @Decision=''VerifiedManual'' THEN SYSUTCDATETIME() ELSE NULL END WHERE PaymentID=@PaymentID;
 INSERT dbo.PaymentReviews(PaymentId,OperatorId,Decision,Note) VALUES(@PaymentID,@UserId,@Decision,TRIM(@Note));
 COMMIT;
 EXEC dbo.GetPayment @PaymentID,@Owner;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'-- A cancelled booking never claims that external funds were automatically refunded.
CREATE OR ALTER TRIGGER dbo.ManualWhishParticipationRemoved ON dbo.Participations AFTER DELETE AS
BEGIN
 SET NOCOUNT ON;
 UPDATE p SET Status=''RefundReview'',ReviewNote=N''Booking removed. Check Whish statement and arrange any refund manually.''
 FROM dbo.Payments p JOIN deleted d ON d.GameId=p.GameID AND d.UserId=p.UserID
 WHERE p.Mode=''WhishManual'' AND p.Status<>''Cancelled'';
END;');
 EXEC(N'CREATE OR ALTER TRIGGER dbo.ManualWhishEventCancelled ON dbo.GamesAndEvents AFTER UPDATE AS
BEGIN
 SET NOCOUNT ON;
 UPDATE p SET Status=''RefundReview'',ReviewNote=N''Event cancelled. Check Whish statement and arrange any refund manually.''
 FROM dbo.Payments p JOIN inserted i ON i.EventId=p.GameID JOIN deleted d ON d.EventId=i.EventId
 WHERE i.GameStatus=''Cancelled'' AND d.GameStatus<>''Cancelled'' AND p.Mode=''WhishManual'' AND p.Status<>''Cancelled'';
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetVenueLocation @VenueId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT VenueId,Latitude,Longitude,GooglePlaceId,Name,Area,Address FROM dbo.Venues WHERE VenueId=@VenueId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.CreateGame
 @HostUserId int,@SportId int,@VenueId int,@StartsAt datetime2(3),@Capacity smallint,
 @Description nvarchar(1000)=N'''',@CostPerPlayer decimal(10,2)=0,@Currency char(3)=''USD'',@SponsoredSlots smallint=0,@VenueName nvarchar(120)=NULL,@VenueArea nvarchar(80)=NULL,@VenueAddress nvarchar(250)=NULL,@Latitude decimal(10,7)=NULL,@Longitude decimal(10,7)=NULL,@GooglePlaceId nvarchar(255)=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  IF @StartsAt<=SYSUTCDATETIME() OR @Capacity NOT BETWEEN 2 AND 100 OR @SponsoredSlots<0 OR @SponsoredSlots>=@Capacity
   OR @CostPerPlayer<0 OR @Currency NOT IN(''USD'',''LBP'') THROW 50002,''Invalid game details.'',1;
  IF @VenueId=0
  BEGIN
   IF NULLIF(TRIM(@VenueName),N'''') IS NULL OR NULLIF(TRIM(@VenueArea),N'''') IS NULL OR NULLIF(TRIM(@VenueAddress),N'''') IS NULL
    OR @Latitude IS NULL OR @Longitude IS NULL OR @Latitude NOT BETWEEN 33 AND 34.8 OR @Longitude NOT BETWEEN 35 AND 36.7
    THROW 50002,''Choose a location in Lebanon.'',1;
   INSERT dbo.Venues(Name,Area,Address,Latitude,Longitude,GooglePlaceId) VALUES(@VenueName,@VenueArea,@VenueAddress,@Latitude,@Longitude,@GooglePlaceId);
   SET @VenueId=CONVERT(int,SCOPE_IDENTITY());
  END;
  INSERT dbo.Games(HostUserId,SportId,VenueId,StartsAt,Capacity,Description,CostPerPlayer,Currency,SponsoredSlots)
  VALUES(@HostUserId,@SportId,@VenueId,@StartsAt,@Capacity,@Description,@CostPerPlayer,@Currency,@SponsoredSlots);
  DECLARE @GameId int=CONVERT(int,SCOPE_IDENTITY());
  INSERT dbo.Participations(GameId,UserId) VALUES(@GameId,@HostUserId);
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,''Created'');
  COMMIT;
  SELECT @GameId AS GameId;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;');
 EXEC(N'CREATE OR ALTER VIEW dbo.GameSummary AS
SELECT v.Latitude,v.Longitude,v.GooglePlaceId,g.EventId AS GameId,g.HostUserId,g.SubtypeId AS SportId,g.SubtypeId,g.VenueId,g.StartsAt,g.Capacity,
 g.Description,g.GameStatus,g.CostPerPlayer,g.Currency,g.SponsoredSlots,g.Revision,
 s.Name AS Sport,s.Slug AS SubtypeSlug,c.CategoryId,c.Name AS CategoryName,c.Slug AS CategorySlug,
 v.Name AS Venue,v.Area,v.Address,
 (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.EventId) AS PlayerCount,
 (SELECT COUNT(*) FROM dbo.SponsoredSeats f WHERE f.GameId=g.EventId) AS SponsoredClaimed
FROM dbo.GamesAndEvents g JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId
JOIN dbo.Categories c ON c.CategoryId=s.CategoryId JOIN dbo.Venues v ON v.VenueId=g.VenueId;');
 EXEC(N'GRANT EXECUTE ON dbo.SubmitWhishTransfer TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.GetMyPayments TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.ListWhishReviews TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.ReviewWhishTransfer TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.GetVenueLocation TO gameon_executor;');
 INSERT dbo.PlatformMigrations(Version) VALUES(16);
 COMMIT;
 SELECT 'Migration 16 completed successfully' AS Result;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
