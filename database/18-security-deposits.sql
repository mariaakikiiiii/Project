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
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=16) THROW 50002,'Install migration 16 first.',1;
 IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=18) THROW 50002,'Migration 18 is already recorded. If a previous attempt failed, use its repair guide instead of rerunning it.',1;
 IF OBJECT_ID(N'dbo.PaymentOperators',N'U') IS NULL OR COL_LENGTH(N'dbo.Venues',N'Latitude') IS NULL OR COL_LENGTH(N'dbo.Payments',N'RecipientNumber') IS NULL THROW 50002,'Migration 16 schema is incomplete. Use 16-repair-partial-install.sql first.',1;
 EXEC(N'ALTER TABLE dbo.Venues ADD ContactPhoneNumber varchar(20) NULL,IsVerified bit NOT NULL CONSTRAINT DF_Venues_Verified DEFAULT 1;');
 EXEC(N'UPDATE dbo.Venues SET IsVerified=0;');
 EXEC(N'ALTER TABLE dbo.GamesAndEvents ADD RequiresDeposit bit NOT NULL CONSTRAINT DF_Events_Deposit DEFAULT 0,
 DepositAmount decimal(18,2) NOT NULL CONSTRAINT DF_Events_DepositAmount DEFAULT 1.00,
 DepositBookingStatus varchar(32) NOT NULL CONSTRAINT DF_Events_DepositBooking DEFAULT ''OPEN_DEPOSITS_PENDING'';');
 EXEC(N'ALTER TABLE dbo.GamesAndEvents DROP CONSTRAINT DF_Events_Deposit;');
 EXEC(N'ALTER TABLE dbo.GamesAndEvents ADD CONSTRAINT DF_Events_Deposit DEFAULT 1 FOR RequiresDeposit;');
 EXEC(N'ALTER TABLE dbo.GamesAndEvents ADD CONSTRAINT CK_Events_DepositAmount CHECK(DepositAmount=1.00),
 CONSTRAINT CK_Events_DepositBooking CHECK(DepositBookingStatus IN(''OPEN_DEPOSITS_PENDING'',''CONFIRMED_DEPOSIT_LOCKED''));');
 EXEC(N'ALTER TABLE dbo.Participations ADD DepositStatus varchar(20) NOT NULL CONSTRAINT DF_Participations_Deposit DEFAULT ''PENDING'',DepositPaidAt datetime NULL;');
 EXEC(N'ALTER TABLE dbo.Participations ADD CONSTRAINT CK_Participations_Deposit CHECK(DepositStatus IN(''PENDING'',''PAID_HELD'',''REFUNDED'',''FORFEITED''));');
 EXEC(N'ALTER TABLE dbo.UserActivityLogs ADD DepositStatus varchar(20) NULL,DepositAmount decimal(18,2) NULL,RequiresDeposit bit NULL;');
 EXEC(N'ALTER TABLE dbo.UserActivityLogs DROP CONSTRAINT CK_UserActivity_Action;');
 EXEC(N'ALTER TABLE dbo.UserActivityLogs ADD CONSTRAINT CK_UserActivity_Action CHECK(Action IN(''DiscoverySearch'',''EventViewed'',''FilterApplied'',''JoinAttempt'',''PaymentOptionsViewed'',''DepositInitialized'',''DepositSubmitted'',''DepositReviewed''));');
 EXEC(N'CREATE INDEX IX_Activity_Event_Deposit_Time ON dbo.UserActivityLogs(EventId,DepositStatus,OccurredAt DESC) INCLUDE(UserId,Action,DepositAmount,RequiresDeposit,IsSynthetic);');
 EXEC(N'CREATE INDEX IX_Participation_Deposit ON dbo.Participations(GameId,DepositStatus) INCLUDE(UserId,DepositPaidAt);');
 EXEC(N'CREATE INDEX IX_Venue_Verified ON dbo.Venues(IsVerified,VenueId) INCLUDE(ContactPhoneNumber,Name,Area);');
 EXEC(N'ALTER TABLE dbo.Payments ADD FeeRate decimal(5,4) NOT NULL CONSTRAINT DF_Payments_OldRate DEFAULT 0.02;');
 EXEC(N'ALTER TABLE dbo.Payments DROP CONSTRAINT DF_Payments_OldRate,CK_Payments_Amounts;');
 EXEC(N'ALTER TABLE dbo.Payments ADD CONSTRAINT DF_Payments_Rate DEFAULT 0.05 FOR FeeRate;');
 EXEC(N'ALTER TABLE dbo.Payments ADD CONSTRAINT CK_Payments_Amounts CHECK(Amount>=0 AND FeeRate IN(0.02,0.05) AND ServiceFee=CONVERT(decimal(12,2),ROUND(Amount*FeeRate,2)));');
 EXEC(N'CREATE TABLE dbo.DepositBookings(
 DepositID uniqueidentifier NOT NULL PRIMARY KEY DEFAULT NEWSEQUENTIALID(),GameId int NOT NULL REFERENCES dbo.GamesAndEvents(EventId),
 UserId int NOT NULL REFERENCES dbo.Users(UserId),IdempotencyKey uniqueidentifier NOT NULL,EventRevision int NOT NULL,
 BaseAmount decimal(12,2) NOT NULL,ServiceFee decimal(12,2) NOT NULL,DepositAmount decimal(18,2) NOT NULL DEFAULT 1.00,
 PaymentMethod varchar(12) NOT NULL DEFAULT ''WhishManual'' CHECK(PaymentMethod IN(''Cash'',''WhishManual'')),
 TotalAmount AS (BaseAmount+ServiceFee+DepositAmount) PERSISTED,DueNow AS (CASE WHEN PaymentMethod=''Cash'' THEN DepositAmount ELSE BaseAmount+ServiceFee+DepositAmount END) PERSISTED,Currency char(3) NOT NULL DEFAULT ''USD'',
 ClaimSponsored bit NOT NULL DEFAULT 0,DepositStatus varchar(20) NOT NULL DEFAULT ''PENDING'',
 RecipientNumber varchar(20) NOT NULL,TransferReference nvarchar(100) NULL,PaymentId uniqueidentifier NULL REFERENCES dbo.Payments(PaymentID),
 ReviewNote nvarchar(400) NULL,CreatedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),DepositPaidAt datetime NULL,
 RefundReference nvarchar(100) NULL,
 CONSTRAINT UQ_Deposit_Key UNIQUE(UserId,IdempotencyKey),
 CONSTRAINT CK_Deposit_Amounts CHECK(BaseAmount>=0 AND DepositAmount=1.00 AND ServiceFee=CONVERT(decimal(12,2),ROUND(BaseAmount*0.05,2)) AND Currency=''USD''),
 CONSTRAINT CK_Deposit_State CHECK(DepositStatus IN(''PENDING'',''PAID_HELD'',''REFUND_PENDING'',''REFUNDED'',''FORFEITED'',''REJECTED'')));');
 EXEC(N'CREATE UNIQUE INDEX UX_Deposit_Pending ON dbo.DepositBookings(GameId,UserId) WHERE DepositStatus=''PENDING'';');
 EXEC(N'CREATE INDEX IX_Deposit_User_Time ON dbo.DepositBookings(UserId,CreatedAt DESC) INCLUDE(GameId,DepositStatus,TotalAmount);');
 EXEC(N'CREATE TABLE dbo.DepositReviews(ReviewId bigint IDENTITY PRIMARY KEY,DepositID uniqueidentifier NOT NULL REFERENCES dbo.DepositBookings(DepositID),
 OperatorId int NOT NULL REFERENCES dbo.Users(UserId),Decision varchar(20) NOT NULL,Note nvarchar(400) NOT NULL,CreatedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME());');
 EXEC(N'CREATE OR ALTER FUNCTION dbo.PlatformServiceFee(@Amount decimal(12,2)) RETURNS decimal(12,2) AS
BEGIN RETURN CONVERT(decimal(12,2),ROUND(@Amount*0.05,2)); END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.sp_JoinGameOrActivity
 @GameId int,@UserId int,@ClaimSponsored bit=0,@PaymentMethod varchar(12)=''Cash'',@MockPaymentID uniqueidentifier=NULL,@CashIdempotencyKey uniqueidentifier=NULL,@ResultStatus varchar(20)=NULL OUTPUT,@ReturnResult bit=1,@DepositAuthorizationID uniqueidentifier=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Capacity int,@Start datetime2(3),@GameStatus varchar(12),@Host int,@Slots int,@Cost decimal(10,2),@Currency char(3),@Revision int,@Status varchar(20);
  SELECT @Capacity=Capacity,@Start=StartsAt,@GameStatus=GameStatus,@Host=HostUserId,@Slots=SponsoredSlots,@Cost=CostPerPlayer,@Currency=Currency,@Revision=Revision
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Capacity IS NULL THROW 50001,''Event not found.'',1;
  IF @GameStatus<>''Open'' OR @Start<=SYSUTCDATETIME() THROW 50002,''Event is no longer open.'',1;
  IF @PaymentMethod IS NULL OR @PaymentMethod NOT IN(''Cash'',''Whish'',''WhishMock'') THROW 50002,''Unknown payment method.'',1;
  -- Whish is a provider integration boundary. Never pretend that selecting it paid.
  IF @PaymentMethod=''Whish'' AND @Cost>0 AND @ClaimSponsored=0
   THROW 50005,''Whish checkout requires the verified merchant integration. Choose cash at the venue for now.'',1;
  IF @PaymentMethod=''WhishMock'' AND NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@MockPaymentID AND GameID=@GameId AND UserID=@UserId AND Status=''MockPending'' AND Mode=''WhishMock'' AND Amount=@Cost AND Currency=@Currency AND EventRevision=@Revision AND ExpiresAt>SYSUTCDATETIME())
   THROW 50003,''A matching mock checkout is required.'',1;
  IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId)
  BEGIN
   IF @ClaimSponsored=1 AND NOT EXISTS(SELECT 1 FROM dbo.SponsoredSeats WHERE GameId=@GameId AND UserId=@UserId)
    THROW 50004,''You already joined at the standard fee. No sponsored place was claimed.'',1;
   SET @Status=''Joined'';
  END
  ELSE IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId)
  BEGIN
   IF @ClaimSponsored=1 THROW 50004,''You are already queued. No sponsored place was claimed.'',1;
   SET @Status=''Waitlisted'';
  END
  ELSE
  BEGIN
   IF @ClaimSponsored=1 AND (@UserId=@Host OR @Slots<=(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@GameId)
    OR @Capacity<=(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId))
     THROW 50004,''No host-covered place is available. Refresh to see current places.'',1;
   IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)<@Capacity
   BEGIN
    IF EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId AND RequiresDeposit=1) AND @UserId<>@Host
    BEGIN
     IF NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@DepositAuthorizationID AND GameId=@GameId AND UserId=@UserId AND DepositStatus=''PAID_HELD'' AND EventRevision=@Revision AND DepositAmount=1.00 AND Currency=''USD'')
      THROW 50005,''A verified commitment deposit is required. Open deposit checkout.'',1;
    END;
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@UserId,@PaymentMethod);
    IF @ClaimSponsored=1 INSERT dbo.SponsoredSeats(GameId,UserId) VALUES(@GameId,@UserId);
    IF @Cost>0 AND @ClaimSponsored=0 AND @PaymentMethod=''Cash''
     INSERT dbo.Payments(UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision)
     VALUES(@UserId,@GameId,@Cost,dbo.PlatformServiceFee(@Cost),@Currency,''Cash'',''PendingCash'',COALESCE(@CashIdempotencyKey,NEWID()),@Revision);
    IF @DepositAuthorizationID IS NOT NULL UPDATE dbo.Participations SET DepositStatus=''PAID_HELD'',DepositPaidAt=GETUTCDATE() WHERE GameId=@GameId AND UserId=@UserId;
    SET @Status=''Joined'';
   END
   ELSE
   BEGIN
    INSERT dbo.Waitlists(GameId,UserId,PaymentMethod,AcceptedServiceFee) VALUES(@GameId,@UserId,@PaymentMethod,1);
    SET @Status=''Waitlisted'';
   END;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,@Status);
   INSERT dbo.UserActivityLogs(UserId,EventId,Action) VALUES(@UserId,@GameId,''JoinAttempt'');
   IF @ClaimSponsored=1 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,''Sponsored'');
   INSERT dbo.Notifications(UserId,GameId,Title,Body) VALUES(@UserId,@GameId,
    CASE WHEN @Status=''Joined'' THEN N''Your place is confirmed'' ELSE N''You are on the waitlist'' END,
    CASE WHEN @ClaimSponsored=1 THEN N''The host has agreed to cover your venue share. No money is transferred in the app.''
     WHEN @Status=''Joined'' THEN N''Check your event time and venue. Any venue share is settled directly with the host.''
     ELSE N''We will notify you if a place opens.'' END);
   IF @Host<>@UserId INSERT dbo.Notifications(UserId,GameId,Title,Body)
    VALUES(@Host,@GameId,N''Your event has a new player'',N''Someone joined your event or its waitlist.'');
  END;
  EXEC dbo.RefreshDepositEvent @GameId;
  COMMIT;
  SET @ResultStatus=@Status;
  IF @ReturnResult=1 SELECT @Status AS Status;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.CancelParticipation @GameId int,@UserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int,@Start datetime2(3),@Status varchar(12),@NextUser int,@Waitlist bigint,@Method varchar(12),@AcceptedFee bit;
  SELECT @Id=EventId,@Start=StartsAt,@Status=GameStatus FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Id IS NULL THROW 50001,''Event not found.'',1;
  IF @Start<=SYSUTCDATETIME() OR @Status<>''Open'' THROW 50002,''Event is no longer open.'',1;
  DELETE dbo.Participations WHERE GameId=@GameId AND UserId=@UserId;
  IF @@ROWCOUNT=1
  BEGIN
   UPDATE dbo.Payments SET Status=CASE WHEN Status=''MockSucceeded'' THEN ''MockCancelled'' ELSE ''Cancelled'' END
    WHERE GameID=@GameId AND UserID=@UserId AND Status IN(''PendingCash'',''MockPending'',''MockSucceeded'');
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,''Cancelled'');
   SELECT TOP(1) @NextUser=UserId,@Waitlist=WaitlistId,@Method=PaymentMethod,@AcceptedFee=AcceptedServiceFee FROM dbo.Waitlists WHERE GameId=@GameId AND NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId AND RequiresDeposit=1) ORDER BY WaitlistId;
   IF @NextUser IS NOT NULL
   BEGIN
    DELETE dbo.Waitlists WHERE WaitlistId=@Waitlist;
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@NextUser,@Method);
    INSERT dbo.Payments(UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision)
     SELECT @NextUser,EventId,CostPerPlayer,dbo.PlatformServiceFee(CostPerPlayer),Currency,''Cash'',''PendingCash'',NEWID(),Revision
     FROM dbo.GamesAndEvents WHERE EventId=@GameId AND CostPerPlayer>0 AND @AcceptedFee=1;
    INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@NextUser,''Promoted'');
    INSERT dbo.Notifications(UserId,GameId,Title,Body)
     VALUES(@NextUser,@GameId,N''A place opened. You are in!'',N''You moved from the waitlist to the roster. Your original venue share and payment preference apply.'');
   END;
   IF EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId AND RequiresDeposit=1)
    INSERT dbo.Notifications(UserId,GameId,Title,Body) SELECT TOP(1) UserId,@GameId,N''A spot opened — verify your deposit'',N''Open the event to begin deposit checkout. A transfer reference alone does not reserve the spot.'' FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
  END
  ELSE
  BEGIN
   DELETE dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId;
   IF @@ROWCOUNT=1 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,''LeftWaitlist'');
  END;
  UPDATE dbo.DepositBookings SET DepositStatus=''REFUND_PENDING'',ReviewNote=N''Deposit request withdrawn. Reconcile any actual transfer before recording a refund.'' WHERE GameId=@GameId AND UserId=@UserId AND DepositStatus=''PENDING'';
  EXEC dbo.RefreshDepositEvent @GameId;
  COMMIT;
  SELECT ''Cancelled'' AS Status;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.EditGame
 @GameId int,@HostUserId int,@Revision int,@StartsAt datetime2(3),@Capacity smallint,@Description nvarchar(1000),
 @CostPerPlayer decimal(10,2),@Currency char(3),@SponsoredSlots smallint
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Owner int,@Status varchar(12),@OldStart datetime2(3),@OldCost decimal(10,2),@OldCurrency char(3),@CurrentRevision int;
  SELECT @Owner=HostUserId,@Status=GameStatus,@OldStart=StartsAt,@OldCost=CostPerPlayer,@OldCurrency=Currency,@CurrentRevision=Revision
   FROM dbo.Games WITH(UPDLOCK,HOLDLOCK) WHERE GameId=@GameId;
  IF @Owner IS NULL THROW 50001,''Game not found.'',1;
  IF @Owner<>@HostUserId THROW 50003,''Only the host can edit this game.'',1;
  IF @CurrentRevision<>@Revision THROW 50004,''Game changed. Refresh and try again.'',1;
  IF @Status<>''Open'' OR @OldStart<=SYSUTCDATETIME() OR @StartsAt<=SYSUTCDATETIME() THROW 50002,''Game cannot be edited.'',1;
  IF @Capacity NOT BETWEEN 2 AND 100 OR @Capacity<(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)
   OR @SponsoredSlots<0 OR @SponsoredSlots>=@Capacity OR @SponsoredSlots<(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@GameId)
   OR @CostPerPlayer<0 OR @Currency NOT IN(''USD'',''LBP'') THROW 50002,''Invalid capacity, price or sponsored places.'',1;
  -- Avoid silently changing financial expectations after other players commit.
  IF (@OldCost<>@CostPerPlayer OR @OldCurrency<>@Currency) AND
   (EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId<>@HostUserId) OR EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId))
   THROW 50002,''Price and currency cannot change after other players join.'',1;
  IF EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE GameId=@GameId AND DepositStatus=''PENDING'' AND TransferReference IS NOT NULL) THROW 50004,''Resolve submitted deposit transfers before editing.'',1;
  UPDATE dbo.Games SET StartsAt=@StartsAt,Capacity=@Capacity,Description=@Description,CostPerPlayer=@CostPerPlayer,
   Currency=@Currency,SponsoredSlots=@SponsoredSlots,Revision=Revision+1 WHERE GameId=@GameId;
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,''Edited'');
  -- Increasing capacity fills newly available places in FIFO order, without a loop.
  DECLARE @Open int=@Capacity-(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId);
  DECLARE @Promoted TABLE(UserId int PRIMARY KEY,WaitlistId bigint,PaymentMethod varchar(12),AcceptedServiceFee bit);
  INSERT @Promoted(UserId,WaitlistId,PaymentMethod,AcceptedServiceFee)
   SELECT TOP(@Open) UserId,WaitlistId,PaymentMethod,AcceptedServiceFee FROM dbo.Waitlists WHERE GameId=@GameId AND NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId AND RequiresDeposit=1) ORDER BY WaitlistId;
  DELETE w FROM dbo.Waitlists w JOIN @Promoted p ON p.WaitlistId=w.WaitlistId;
  INSERT dbo.Participations(GameId,UserId,PaymentMethod) SELECT @GameId,UserId,PaymentMethod FROM @Promoted;
  INSERT dbo.Payments(UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision)
   SELECT p.UserId,g.EventId,g.CostPerPlayer,dbo.PlatformServiceFee(g.CostPerPlayer),g.Currency,''Cash'',''PendingCash'',NEWID(),g.Revision
   FROM @Promoted p CROSS JOIN dbo.GamesAndEvents g WHERE g.EventId=@GameId AND g.CostPerPlayer>0 AND p.AcceptedServiceFee=1;
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) SELECT @GameId,UserId,''Promoted'' FROM @Promoted;
  INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT UserId,@GameId,N''A place opened. You are in!'',N''The host opened more places and you moved from the waitlist to the roster. Your standard venue share applies.'' FROM @Promoted;

  INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT UserId,@GameId,N''Your game was updated'',N''The host changed the game details. Review the time and information before playing.''
   FROM (SELECT UserId FROM dbo.Participations WHERE GameId=@GameId UNION SELECT UserId FROM dbo.Waitlists WHERE GameId=@GameId) members
   WHERE UserId<>@HostUserId;
  EXEC dbo.RefreshDepositEvent @GameId;
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetGame @GameId int,@UserId int=NULL AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.*,u.DisplayName AS HostName FROM dbo.GameSummary s JOIN dbo.Users u ON u.UserId=s.HostUserId WHERE GameId=@GameId;
 SELECT p.UserId,u.DisplayName,p.JoinedAt,p.DepositStatus,p.DepositPaidAt,CAST(CASE WHEN f.UserId IS NULL THEN 0 ELSE 1 END AS bit) AS IsSponsored
 FROM dbo.Participations p JOIN dbo.Users u ON u.UserId=p.UserId
 LEFT JOIN dbo.SponsoredSeats f ON f.GameId=p.GameId AND f.UserId=p.UserId
 WHERE p.GameId=@GameId ORDER BY p.JoinedAt,p.UserId;
 SELECT CAST(''Joined'' AS varchar(20)) AS Status,p.PaymentMethod,CAST(NULL AS bigint) AS QueuePosition
 FROM dbo.Participations p WHERE p.GameId=@GameId AND p.UserId=@UserId
 UNION ALL SELECT ''Waitlisted'',w.PaymentMethod,dbo.WaitlistPosition(w.GameId,w.UserId)
 FROM dbo.Waitlists w WHERE w.GameId=@GameId AND w.UserId=@UserId;
 IF EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId)
  INSERT dbo.UserActivityLogs(UserId,EventId,SubtypeId,Action) SELECT @UserId,EventId,SubtypeId,''EventViewed'' FROM dbo.GamesAndEvents WHERE EventId=@GameId;
END;');
 EXEC(N'CREATE OR ALTER VIEW dbo.GameSummary AS
SELECT g.RequiresDeposit,g.DepositAmount,g.DepositBookingStatus,v.ContactPhoneNumber,v.IsVerified AS VenueIsVerified,v.Latitude,v.Longitude,v.GooglePlaceId,g.EventId AS GameId,g.HostUserId,g.SubtypeId AS SportId,g.SubtypeId,g.VenueId,g.StartsAt,g.Capacity,
 g.Description,g.GameStatus,g.CostPerPlayer,g.Currency,g.SponsoredSlots,g.Revision,
 s.Name AS Sport,s.Slug AS SubtypeSlug,c.CategoryId,c.Name AS CategoryName,c.Slug AS CategorySlug,
 v.Name AS Venue,v.Area,v.Address,
 (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.EventId) AS PlayerCount,
 (SELECT COUNT(*) FROM dbo.SponsoredSeats f WHERE f.GameId=g.EventId) AS SponsoredClaimed
FROM dbo.GamesAndEvents g JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId
JOIN dbo.Categories c ON c.CategoryId=s.CategoryId JOIN dbo.Venues v ON v.VenueId=g.VenueId;');
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
  IF @Currency<>''USD'' THROW 50002,''New deposit-backed events currently require USD. No LBP conversion is performed.'',1;
  IF @VenueId=0
  BEGIN
   IF NULLIF(TRIM(@VenueName),N'''') IS NULL OR NULLIF(TRIM(@VenueArea),N'''') IS NULL OR NULLIF(TRIM(@VenueAddress),N'''') IS NULL
    OR @Latitude IS NULL OR @Longitude IS NULL OR @Latitude NOT BETWEEN 33 AND 34.8 OR @Longitude NOT BETWEEN 35 AND 36.7
    THROW 50002,''Choose a location in Lebanon.'',1;
   INSERT dbo.Venues(Name,Area,Address,Latitude,Longitude,GooglePlaceId,IsVerified) VALUES(@VenueName,@VenueArea,@VenueAddress,@Latitude,@Longitude,@GooglePlaceId,0);
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
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.RefreshDepositEvent @GameId int AS
BEGIN
 SET NOCOUNT ON;
 UPDATE g SET DepositBookingStatus=CASE WHEN RequiresDeposit=1 AND GameStatus=''Open''
 AND (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.EventId)=g.Capacity
 AND NOT EXISTS(SELECT 1 FROM dbo.Participations p WHERE p.GameId=g.EventId AND p.UserId<>g.HostUserId AND p.DepositStatus<>''PAID_HELD'')
 THEN ''CONFIRMED_DEPOSIT_LOCKED'' ELSE ''OPEN_DEPOSITS_PENDING'' END
 FROM dbo.GamesAndEvents g WHERE EventId=@GameId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetDepositBooking @DepositID uniqueidentifier,@UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT d.DepositID AS DepositId,d.GameId,d.BaseAmount,d.ServiceFee,d.DepositAmount,d.TotalAmount,d.DueNow,d.PaymentMethod,d.Currency,d.DepositStatus,d.RecipientNumber,
 d.TransferReference,d.ReviewNote,d.CreatedAt,d.EventRevision,d.ClaimSponsored,g.GameStatus,g.StartsAt,g.Revision AS CurrentRevision,s.Name AS Sport,v.Name AS Venue
 FROM dbo.DepositBookings d JOIN dbo.GamesAndEvents g ON g.EventId=d.GameId JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId JOIN dbo.Venues v ON v.VenueId=g.VenueId
 WHERE d.DepositID=@DepositID AND d.UserId=@UserId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetDepositQuote @GameId int,@UserId int,@ClaimSponsored bit=0,@Method varchar(12)=''WhishManual'' AS
BEGIN
 SET NOCOUNT ON;
 IF @Method NOT IN(''Cash'',''WhishManual'') THROW 50002,''Invalid deposit payment method.'',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId) THROW 50001,''Event not found.'',1;
 SELECT g.EventId AS GameId,g.Revision,g.RequiresDeposit,g.DepositAmount,g.Currency,
 CASE WHEN @ClaimSponsored=1 THEN CONVERT(decimal(12,2),0) ELSE g.CostPerPlayer END AS BaseAmount,
 CASE WHEN @ClaimSponsored=1 THEN CONVERT(decimal(12,2),0) ELSE dbo.PlatformServiceFee(g.CostPerPlayer) END AS ServiceFee,
 g.DepositAmount+CASE WHEN @ClaimSponsored=1 THEN 0 ELSE g.CostPerPlayer+dbo.PlatformServiceFee(g.CostPerPlayer) END AS TotalAmount,
 CASE WHEN @Method=''Cash'' THEN g.DepositAmount ELSE g.DepositAmount+CASE WHEN @ClaimSponsored=1 THEN 0 ELSE g.CostPerPlayer+dbo.PlatformServiceFee(g.CostPerPlayer) END END AS DueNow,@Method AS PaymentMethod,
 CAST(CASE WHEN v.IsVerified=1 AND v.ContactPhoneNumber IS NOT NULL THEN 1 ELSE 0 END AS bit) AS VenueIsVerified,v.ContactPhoneNumber,
 CAST(CASE WHEN g.GameStatus=''Open'' AND g.StartsAt>SYSUTCDATETIME() THEN 1 ELSE 0 END AS bit) AS IsOpen,
 CAST(CASE WHEN (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)>=g.Capacity THEN 1 ELSE 0 END AS bit) AS IsFull
 FROM dbo.GamesAndEvents g JOIN dbo.Venues v ON v.VenueId=g.VenueId WHERE EventId=@GameId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.InitializeDeposit @GameId int,@UserId int,@Revision int,@Key uniqueidentifier,@ClaimSponsored bit=0,@Recipient varchar(20)=''+96171364432'',@Method varchar(12)=''WhishManual'' AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Capacity int,@Cost decimal(12,2),@State varchar(12),@Start datetime2(3),@Current int,@Required bit,@Currency char(3),@Host int,@Slots int,@Venue int,@ID uniqueidentifier;
 SELECT @Capacity=Capacity,@Cost=CostPerPlayer,@State=GameStatus,@Start=StartsAt,@Current=Revision,@Required=RequiresDeposit,@Currency=Currency,@Host=HostUserId,@Slots=SponsoredSlots,@Venue=VenueId
 FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
 IF @Capacity IS NULL THROW 50001,''Event not found.'',1;
 IF @Method IS NULL OR @Method NOT IN(''Cash'',''WhishManual'') OR @Key IS NULL OR @Recipient<>''+96171364432'' THROW 50002,''Invalid deposit checkout.'',1;
 SELECT @ID=DepositID FROM dbo.DepositBookings WHERE UserId=@UserId AND IdempotencyKey=@Key;
 IF @ID IS NOT NULL
 BEGIN
  IF NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@ID AND GameId=@GameId AND ClaimSponsored=@ClaimSponsored AND PaymentMethod=@Method) THROW 50004,''Checkout key conflicts with another booking.'',1;
 END
 ELSE
 BEGIN
  SELECT @ID=DepositID FROM dbo.DepositBookings WHERE GameId=@GameId AND UserId=@UserId AND DepositStatus=''PENDING'';
  IF @ID IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@ID AND ClaimSponsored=@ClaimSponsored AND PaymentMethod=@Method) THROW 50004,''Resume the pending deposit under Payments before changing its method.'',1;
  IF @ID IS NULL
  BEGIN
   IF EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE GameId=@GameId AND UserId=@UserId AND DepositStatus=''REFUND_PENDING'') THROW 50004,''Resolve the previous refund review before starting another deposit.'',1;
   IF @Required<>1 OR @Currency<>''USD'' OR @Revision<>@Current OR @Host=@UserId THROW 50002,''Refresh this USD deposit-backed event before checkout.'',1;
   IF @State<>''Open'' OR @Start<=SYSUTCDATETIME() THROW 50002,''Event is no longer open.'',1;
   IF NOT EXISTS(SELECT 1 FROM dbo.Venues WHERE VenueId=@Venue AND IsVerified=1 AND ContactPhoneNumber IS NOT NULL) THROW 50002,''The venue contact must be verified by GameOn before collecting deposits.'',1;
   IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId) THROW 50004,''You already have a spot.'',1;
   IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)>=@Capacity THROW 50004,''Event is full. Join its waitlist without payment.'',1;
   IF @ClaimSponsored=1 AND @Slots<=(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@GameId) THROW 50004,''No host-covered share remains.'',1;
   IF @ClaimSponsored=1 SET @Cost=0;
   SET @ID=NEWID();
   INSERT dbo.DepositBookings(DepositID,GameId,UserId,IdempotencyKey,EventRevision,BaseAmount,ServiceFee,ClaimSponsored,RecipientNumber,PaymentMethod)
    VALUES(@ID,@GameId,@UserId,@Key,@Current,@Cost,dbo.PlatformServiceFee(@Cost),@ClaimSponsored,@Recipient,@Method);
   INSERT dbo.UserActivityLogs(UserId,EventId,Action,DepositStatus,DepositAmount,RequiresDeposit) VALUES(@UserId,@GameId,''DepositInitialized'',''PENDING'',1,1);
  END;
 END;
 COMMIT;
 EXEC dbo.GetDepositBooking @ID,@UserId;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.SubmitDepositTransfer @DepositID uniqueidentifier,@UserId int,@Reference nvarchar(100) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @Reference IS NULL OR LEN(TRIM(@Reference)) NOT BETWEEN 4 AND 100 THROW 50002,''Enter a valid Whish transfer reference.'',1;
 BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Game int;
 SELECT @Game=GameId FROM dbo.DepositBookings WHERE DepositID=@DepositID AND UserId=@UserId;
 IF @Game IS NULL THROW 50001,''Deposit not found.'',1;
 SELECT @Game=EventId FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@Game;
 IF EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE DepositID=@DepositID AND DepositStatus IN(''PENDING'',''REFUND_PENDING'') AND TransferReference=TRIM(@Reference))
 BEGIN COMMIT; EXEC dbo.GetDepositBooking @DepositID,@UserId; RETURN; END;
 UPDATE dbo.DepositBookings SET TransferReference=TRIM(@Reference) WHERE DepositID=@DepositID AND UserId=@UserId AND DepositStatus IN(''PENDING'',''REFUND_PENDING'') AND TransferReference IS NULL;
 IF @@ROWCOUNT=0 THROW 50004,''Deposit was already reviewed or its reference differs. Contact the operator.'',1;
 INSERT dbo.UserActivityLogs(UserId,EventId,Action,DepositStatus,DepositAmount,RequiresDeposit) SELECT UserId,GameId,''DepositSubmitted'',DepositStatus,DepositAmount,1 FROM dbo.DepositBookings WHERE DepositID=@DepositID;
 COMMIT;
 EXEC dbo.GetDepositBooking @DepositID,@UserId;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ReviewDeposit @DepositID uniqueidentifier,@UserId int,@Decision varchar(20),@Note nvarchar(400),@RefundReference nvarchar(100)=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Payment operator access required.'',1;
 IF @Decision IS NULL OR @Decision NOT IN(''VERIFY'',''REJECT'',''REFUND'',''FORFEIT'') OR @Note IS NULL OR LEN(TRIM(@Note))<4 THROW 50002,''Enter a decision and reconciliation note.'',1;
 BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Game int,@Owner int,@Capacity int,@Start datetime2(3),@State varchar(12),@Revision int,@Venue int,@Slots int,@StoredRevision int,
 @Status varchar(20),@Reference nvarchar(100),@Base decimal(12,2),@Fee decimal(12,2),@Covered bit,@Payment uniqueidentifier,@Recipient varchar(20),@PaidAt datetime,@Method varchar(12);
 SELECT @Game=GameId FROM dbo.DepositBookings WHERE DepositID=@DepositID;
 IF @Game IS NULL THROW 50001,''Deposit not found.'',1;
 SELECT @Capacity=Capacity,@Start=StartsAt,@State=GameStatus,@Revision=Revision,@Venue=VenueId,@Slots=SponsoredSlots FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@Game;
 SELECT @Method=PaymentMethod,@Owner=UserId,@Status=DepositStatus,@Reference=TransferReference,@Base=BaseAmount,@Fee=ServiceFee,@Covered=ClaimSponsored,@StoredRevision=EventRevision,@Recipient=RecipientNumber,@Payment=PaymentId,@PaidAt=DepositPaidAt
 FROM dbo.DepositBookings WITH(UPDLOCK,HOLDLOCK) WHERE DepositID=@DepositID;
 IF @Decision=''VERIFY''
 BEGIN
  IF @Status<>''PENDING'' OR @Reference IS NULL THROW 50004,''A pending submitted transfer is required.'',1;
  IF EXISTS(SELECT 1 FROM dbo.VerifiedWhishTransfers WHERE TransferReference=@Reference) THROW 50004,''This transfer reference has already settled another booking.'',1;
  DECLARE @CanJoin bit=CASE WHEN @State=''Open'' AND @Start>SYSUTCDATETIME() AND @Revision=@StoredRevision
   AND (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game)<@Capacity
   AND NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@Owner)
   AND EXISTS(SELECT 1 FROM dbo.Venues WHERE VenueId=@Venue AND IsVerified=1 AND ContactPhoneNumber IS NOT NULL)
   AND (@Covered=0 OR @Slots>(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@Game)) THEN 1 ELSE 0 END;
  IF @CanJoin=1
  BEGIN
   UPDATE dbo.DepositBookings SET DepositStatus=''PAID_HELD'',DepositPaidAt=GETUTCDATE() WHERE DepositID=@DepositID;
   DELETE dbo.Waitlists WHERE GameId=@Game AND UserId=@Owner;
   DECLARE @JoinResult varchar(20);
   EXEC dbo.sp_JoinGameOrActivity @GameId=@Game,@UserId=@Owner,@ClaimSponsored=@Covered,@PaymentMethod=''Cash'',@CashIdempotencyKey=@DepositID,@ResultStatus=@JoinResult OUTPUT,@ReturnResult=0,@DepositAuthorizationID=@DepositID;
   IF @JoinResult<>''Joined'' THROW 50004,''The deposit could not authorize a spot.'',1;
   SELECT @Payment=PaymentID FROM dbo.Payments WHERE UserID=@Owner AND IdempotencyKey=@DepositID;
  END;
  IF @Payment IS NULL
  BEGIN
   SET @Payment=NEWID();
   INSERT dbo.Payments(PaymentID,UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision,RecipientNumber,TransferReference)
    VALUES(@Payment,@Owner,@Game,CASE WHEN @Method=''Cash'' THEN 0 ELSE @Base END,CASE WHEN @Method=''Cash'' THEN 0 ELSE @Fee END,''USD'',''WhishManual'',CASE WHEN @CanJoin=1 THEN ''VerifiedManual'' ELSE ''RefundReview'' END,@DepositID,@StoredRevision,@Recipient,@Reference);
  END
  ELSE IF @Method=''WhishManual'' UPDATE dbo.Payments SET Mode=''WhishManual'',Status=''VerifiedManual'',RecipientNumber=@Recipient,TransferReference=@Reference,CompletedAt=SYSUTCDATETIME() WHERE PaymentID=@Payment;
  INSERT dbo.VerifiedWhishTransfers(TransferReference,PaymentId) VALUES(@Reference,@Payment);
  UPDATE dbo.DepositBookings SET PaymentId=@Payment,DepositStatus=CASE WHEN @CanJoin=1 THEN ''PAID_HELD'' ELSE ''REFUND_PENDING'' END,
   DepositPaidAt=GETUTCDATE(),ReviewNote=@Note WHERE DepositID=@DepositID;
  IF @CanJoin=1 UPDATE dbo.Participations SET PaymentMethod=@Method WHERE GameId=@Game AND UserId=@Owner;
 END
 ELSE IF @Decision=''REJECT''
 BEGIN
  IF @Status<>''PENDING'' AND NOT(@Status=''REFUND_PENDING'' AND @PaidAt IS NULL) THROW 50004,''Only an unverified transfer can be rejected.'',1;
  UPDATE dbo.DepositBookings SET DepositStatus=''REJECTED'',ReviewNote=@Note WHERE DepositID=@DepositID;
 END
 ELSE IF @Decision=''REFUND''
 BEGIN
  IF @Status NOT IN(''REFUND_PENDING'',''PAID_HELD'') OR (@Status=''PAID_HELD'' AND @Start>SYSUTCDATETIME() AND @State=''Open'') THROW 50004,''Deposit is not eligible for release yet.'',1;
  IF @RefundReference IS NULL OR LEN(TRIM(@RefundReference)) NOT BETWEEN 4 AND 100 THROW 50002,''Record the actual external refund reference.'',1;
  -- Cancellation may happen before operator verification. Retire the received-and-refunded reference too.
  IF @Payment IS NULL
  BEGIN
   IF @Reference IS NULL THROW 50002,''A reconciled original transfer reference is required before recording a refund.'',1;
   IF EXISTS(SELECT 1 FROM dbo.VerifiedWhishTransfers WHERE TransferReference=@Reference) THROW 50004,''Transfer reference already belongs to another booking.'',1;
   SET @Payment=NEWID();
   INSERT dbo.Payments(PaymentID,UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision,RecipientNumber,TransferReference)
   VALUES(@Payment,@Owner,@Game,CASE WHEN @Method=''Cash'' THEN 0 ELSE @Base END,CASE WHEN @Method=''Cash'' THEN 0 ELSE @Fee END,''USD'',''WhishManual'',''Cancelled'',@DepositID,@StoredRevision,@Recipient,@Reference);
   INSERT dbo.VerifiedWhishTransfers(TransferReference,PaymentId) VALUES(@Reference,@Payment);
   UPDATE dbo.DepositBookings SET PaymentId=@Payment,DepositPaidAt=GETUTCDATE() WHERE DepositID=@DepositID;
  END;
  UPDATE dbo.DepositBookings SET DepositStatus=''REFUNDED'',RefundReference=@RefundReference,ReviewNote=@Note WHERE DepositID=@DepositID;
  UPDATE dbo.Participations SET DepositStatus=''REFUNDED'' WHERE GameId=@Game AND UserId=@Owner;
  UPDATE dbo.Payments SET Status=''Cancelled'',ReviewNote=@Note WHERE PaymentID=@Payment AND Status=''RefundReview'';
 END
 ELSE
 BEGIN
  IF @Status<>''PAID_HELD'' OR @Start>SYSUTCDATETIME() OR @State=''Cancelled'' THROW 50004,''Only a held deposit after the event starts can be forfeited following a no-show review.'',1;
  UPDATE dbo.DepositBookings SET DepositStatus=''FORFEITED'',ReviewNote=@Note WHERE DepositID=@DepositID;
  UPDATE dbo.Participations SET DepositStatus=''FORFEITED'' WHERE GameId=@Game AND UserId=@Owner;
 END;
 INSERT dbo.DepositReviews(DepositID,OperatorId,Decision,Note) VALUES(@DepositID,@UserId,@Decision,@Note);
 INSERT dbo.UserActivityLogs(UserId,EventId,Action,DepositStatus,DepositAmount,RequiresDeposit)
 SELECT @Owner,@Game,''DepositReviewed'',DepositStatus,DepositAmount,1 FROM dbo.DepositBookings WHERE DepositID=@DepositID;
 EXEC dbo.RefreshDepositEvent @Game;
 COMMIT;
 EXEC dbo.GetDepositBooking @DepositID,@Owner;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetMyDeposits @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(100) d.DepositID AS DepositId,d.GameId,d.BaseAmount,d.ServiceFee,d.DepositAmount,d.TotalAmount,d.DueNow,d.PaymentMethod,d.Currency,d.DepositStatus,d.RecipientNumber,
 d.TransferReference,d.ReviewNote,d.EventRevision,g.Revision AS CurrentRevision,g.GameStatus,g.StartsAt,s.Name AS Sport,v.Name AS Venue
 FROM dbo.DepositBookings d JOIN dbo.GamesAndEvents g ON g.EventId=d.GameId JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId JOIN dbo.Venues v ON v.VenueId=g.VenueId WHERE d.UserId=@UserId ORDER BY d.CreatedAt DESC;
 SELECT CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THEN 1 ELSE 0 END AS bit) AS CanReview;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ListDepositReviews @UserId int AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Payment operator access required.'',1;
 SELECT TOP(100) d.DepositID AS DepositId,d.GameId,d.BaseAmount,d.ServiceFee,d.DepositAmount,d.TotalAmount,d.DueNow,d.PaymentMethod,d.Currency,d.DepositStatus,d.TransferReference,
 d.RecipientNumber,d.ReviewNote,d.DepositPaidAt,g.StartsAt,g.GameStatus,u.DisplayName FROM dbo.DepositBookings d JOIN dbo.GamesAndEvents g ON g.EventId=d.GameId JOIN dbo.Users u ON u.UserId=d.UserId
 WHERE d.DepositStatus IN(''PENDING'',''PAID_HELD'',''REFUND_PENDING'') ORDER BY d.CreatedAt;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.SetVenueContact @VenueId int,@UserId int,@Phone varchar(20),@Verified bit AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Operator access required.'',1;
 IF @Verified=1 AND (@Phone IS NULL OR LEN(@Phone) NOT BETWEEN 8 AND 16 OR @Phone NOT LIKE ''+%'' OR SUBSTRING(@Phone,2,20) LIKE ''%[^0-9]%'') THROW 50002,''Use an international venue number, for example +961 followed by the real venue number.'',1;
 UPDATE dbo.Venues SET ContactPhoneNumber=NULLIF(@Phone,''''),IsVerified=@Verified WHERE VenueId=@VenueId;
 IF @@ROWCOUNT=0 THROW 50001,''Venue not found.'',1;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ListVenueContacts @UserId int AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Operator access required.'',1;
 SELECT TOP(200) VenueId,Name,Area,ContactPhoneNumber,IsVerified FROM dbo.Venues ORDER BY IsVerified,VenueId DESC;
END;');
 EXEC(N'CREATE OR ALTER TRIGGER dbo.DepositParticipationRemoved ON dbo.Participations AFTER DELETE AS
BEGIN
 SET NOCOUNT ON;
 UPDATE d SET DepositStatus=''REFUND_PENDING'',ReviewNote=N''Participant left; reconcile the actual transfer and any refund.'' FROM dbo.DepositBookings d JOIN deleted p ON p.GameId=d.GameId AND p.UserId=d.UserId WHERE d.DepositStatus=''PAID_HELD'';
 UPDATE g SET DepositBookingStatus=''OPEN_DEPOSITS_PENDING'' FROM dbo.GamesAndEvents g JOIN deleted p ON p.GameId=g.EventId;
END;');
 EXEC(N'CREATE OR ALTER TRIGGER dbo.DepositEventCancelled ON dbo.GamesAndEvents AFTER UPDATE AS
BEGIN
 SET NOCOUNT ON;
 IF NOT UPDATE(GameStatus) RETURN;
 UPDATE g SET DepositBookingStatus=''OPEN_DEPOSITS_PENDING'' FROM dbo.GamesAndEvents g JOIN inserted i ON i.EventId=g.EventId WHERE i.GameStatus=''Cancelled'';
 UPDATE d SET DepositStatus=''REFUND_PENDING'',ReviewNote=N''Event cancelled; reconcile actual funds before recording a refund.''
 FROM dbo.DepositBookings d JOIN inserted i ON i.EventId=d.GameId JOIN deleted o ON o.EventId=i.EventId
 WHERE i.GameStatus=''Cancelled'' AND o.GameStatus<>''Cancelled'' AND (d.DepositStatus=''PAID_HELD'' OR (d.DepositStatus=''PENDING'' AND d.TransferReference IS NOT NULL));
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetMyPayments @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(100) p.PaymentID AS PaymentId,p.GameID AS GameId,p.Amount,p.ServiceFee,p.TotalAmount,p.Currency,p.Mode,p.Status,
 p.RecipientNumber,p.TransferReference,p.ReviewNote,p.CreatedAt,s.Name AS Sport,v.Name AS Venue
 FROM dbo.Payments p JOIN dbo.GamesAndEvents g ON g.EventId=p.GameID JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId
 JOIN dbo.Venues v ON v.VenueId=g.VenueId WHERE p.UserID=@UserId AND NOT EXISTS(SELECT 1 FROM dbo.DepositBookings d WHERE d.PaymentId=p.PaymentID) ORDER BY p.CreatedAt DESC,p.PaymentID;
 SELECT CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THEN 1 ELSE 0 END AS bit) AS CanReview;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ListWhishReviews @UserId int AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Payment operator access required.'',1;
 SELECT TOP(100) p.PaymentID AS PaymentId,p.GameID AS GameId,p.TotalAmount,p.Currency,p.Status,p.TransferReference,p.RecipientNumber,
 p.CreatedAt,u.DisplayName,p.ReviewNote FROM dbo.Payments p JOIN dbo.Users u ON u.UserId=p.UserID
 WHERE NOT EXISTS(SELECT 1 FROM dbo.DepositBookings d WHERE d.PaymentId=p.PaymentID) AND p.Mode=''WhishManual'' AND p.Status IN(''AwaitingVerification'',''RefundReview'') ORDER BY p.CreatedAt;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.ReviewWhishTransfer @PaymentID uniqueidentifier,@UserId int,@Decision varchar(20),@Note nvarchar(400) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Payment operator access required.'',1;
 IF EXISTS(SELECT 1 FROM dbo.DepositBookings WHERE PaymentId=@PaymentID) THROW 50002,''Use deposit review for this booking.'',1;
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
 EXEC(N'GRANT EXECUTE ON dbo.GetDepositQuote TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.GetDepositBooking TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.InitializeDeposit TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.SubmitDepositTransfer TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.ReviewDeposit TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.GetMyDeposits TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.ListDepositReviews TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.SetVenueContact TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.ListVenueContacts TO gameon_executor;');
 INSERT dbo.PlatformMigrations(Version) VALUES(18);
 COMMIT;
 SELECT 'Migration 18 completed successfully' AS Result;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
