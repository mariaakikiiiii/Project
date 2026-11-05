-- Back up first. Requires versions 7 and 9. Execute WHOLE file in SQLCMD Mode.
:ON ERROR EXIT
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=9) THROW 50002,'Install upgrade 9 first.',1;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=13) THROW 50002,'Commercial upgrade 13 is already installed.',1;
BEGIN TRANSACTION;
CREATE TABLE dbo.Payments(
 PaymentID uniqueidentifier NOT NULL CONSTRAINT DF_Payments_ID DEFAULT NEWSEQUENTIALID() CONSTRAINT PK_Payments PRIMARY KEY,
 UserID int NOT NULL CONSTRAINT FK_Payments_User REFERENCES dbo.Users(UserId),
 GameID int NOT NULL CONSTRAINT FK_Payments_Event REFERENCES dbo.GamesAndEvents(EventId),
 Amount decimal(12,2) NOT NULL,
 ServiceFee decimal(12,2) NOT NULL,
 TotalAmount AS (Amount+ServiceFee) PERSISTED,
 Currency char(3) NOT NULL CONSTRAINT CK_Payments_Currency CHECK(Currency IN('USD','LBP')),
 Mode varchar(12) NOT NULL CONSTRAINT CK_Payments_Mode CHECK(Mode IN('Cash','WhishMock')),
 Status varchar(24) NOT NULL,
 GatewayTransactionID nvarchar(128) NULL,
 IdempotencyKey uniqueidentifier NOT NULL,
 EventRevision int NOT NULL,
 CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Payments_Created DEFAULT SYSUTCDATETIME(),
 ExpiresAt datetime2(3) NULL,
 CompletedAt datetime2(3) NULL,
 CONSTRAINT UQ_Payments_Idempotency UNIQUE(UserID,IdempotencyKey),
 CONSTRAINT CK_Payments_Amounts CHECK(Amount>=0 AND ServiceFee=CONVERT(decimal(12,2),ROUND(Amount*0.02,2))),
 CONSTRAINT CK_Payments_Expiry CHECK(ExpiresAt IS NULL OR ExpiresAt>CreatedAt),
 CONSTRAINT CK_Payments_State CHECK(
  (Mode='Cash' AND Status IN('PendingCash','Cancelled')) OR
  (Mode='WhishMock' AND Status IN('MockPending','MockSucceeded','MockFailed','Expired','Cancelled','MockCancelled')))
);
CREATE UNIQUE INDEX UX_Payments_Gateway ON dbo.Payments(GatewayTransactionID) WHERE GatewayTransactionID IS NOT NULL;
CREATE UNIQUE INDEX UX_Payments_PendingMock ON dbo.Payments(GameID,UserID) WHERE Status='MockPending';
CREATE UNIQUE INDEX UX_Payments_PendingCash ON dbo.Payments(GameID,UserID) WHERE Status='PendingCash';
CREATE INDEX IX_Payments_User_Created ON dbo.Payments(UserID,CreatedAt DESC) INCLUDE(GameID,Amount,ServiceFee,Status,Mode,Currency);
CREATE TABLE dbo.PaymentWebhookEvents(
 WebhookEventID uniqueidentifier CONSTRAINT PK_PaymentWebhookEvents PRIMARY KEY,
 PaymentID uniqueidentifier NOT NULL CONSTRAINT FK_Webhook_Payment REFERENCES dbo.Payments(PaymentID),
 PayloadHash binary(32) NOT NULL,
 ProcessedAt datetime2(3) NOT NULL CONSTRAINT DF_Webhook_Processed DEFAULT SYSUTCDATETIME()
);
CREATE TABLE dbo.SponsoredVenues(
 VenueID int CONSTRAINT PK_SponsoredVenues PRIMARY KEY CONSTRAINT FK_SponsoredVenue_Venue REFERENCES dbo.Venues(VenueId),
 Tier varchar(12) NOT NULL CONSTRAINT CK_SponsoredVenues_Tier CHECK(Tier IN('Gold','Silver','Bronze')),
 StartDate datetime2(3) NOT NULL,
 EndDate datetime2(3) NOT NULL,
 IsActive bit NOT NULL CONSTRAINT DF_SponsoredVenues_Active DEFAULT 1,
 CONSTRAINT CK_SponsoredVenues_Dates CHECK(EndDate>StartDate)
);
CREATE INDEX IX_SponsoredVenues_Active ON dbo.SponsoredVenues(IsActive,StartDate,EndDate) INCLUDE(Tier);
ALTER TABLE dbo.Waitlists ADD AcceptedServiceFee bit NOT NULL CONSTRAINT DF_Waitlists_AcceptedFee DEFAULT 0;
ALTER TABLE dbo.Participations DROP CONSTRAINT CK_Participations_Payment;
ALTER TABLE dbo.Participations ADD CONSTRAINT CK_Participations_Payment CHECK(PaymentMethod IN('Cash','Whish','WhishMock'));
GO
CREATE OR ALTER FUNCTION dbo.PlatformServiceFee(@Amount decimal(12,2)) RETURNS decimal(12,2) AS
BEGIN
 RETURN CONVERT(decimal(12,2),ROUND(@Amount*0.02,2));
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetSponsoredVenues AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(12) v.VenueId,v.Name,v.Area,v.Address,s.Tier,s.EndDate
 FROM dbo.SponsoredVenues s JOIN dbo.Venues v ON v.VenueId=s.VenueID
 WHERE s.IsActive=1 AND s.StartDate<=SYSUTCDATETIME() AND s.EndDate>SYSUTCDATETIME()
 ORDER BY CASE s.Tier WHEN 'Gold' THEN 1 WHEN 'Silver' THEN 2 ELSE 3 END,s.StartDate DESC,v.VenueId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetPaymentQuote @GameId int,@UserId int AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId) THROW 50001,'Event not found.',1;
 SELECT g.EventId AS GameId,g.CostPerPlayer AS Amount,dbo.PlatformServiceFee(g.CostPerPlayer) AS ServiceFee,
  CONVERT(decimal(12,2),g.CostPerPlayer+dbo.PlatformServiceFee(g.CostPerPlayer)) AS TotalAmount,
  g.Currency,g.Revision,
  CAST(CASE WHEN (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.EventId)>=g.Capacity THEN 1 ELSE 0 END AS bit) AS IsFull,
  CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.Participations p WHERE p.GameId=g.EventId AND p.UserId=@UserId)
   OR EXISTS(SELECT 1 FROM dbo.Waitlists w WHERE w.GameId=g.EventId AND w.UserId=@UserId) THEN 1 ELSE 0 END AS bit) AS AlreadyEnrolled,
  CAST(CASE WHEN g.GameStatus='Open' AND g.StartsAt>SYSUTCDATETIME() THEN 1 ELSE 0 END AS bit) AS IsOpen
 FROM dbo.GamesAndEvents g WHERE g.EventId=@GameId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetPayment @PaymentID uniqueidentifier,@UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT PaymentID AS PaymentId,GameID AS GameId,Amount,ServiceFee,TotalAmount,Currency,Mode,Status,GatewayTransactionID AS GatewayTransactionId,CreatedAt,ExpiresAt
 FROM dbo.Payments WHERE PaymentID=@PaymentID AND UserID=@UserId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_JoinGameOrActivity
 @GameId int,@UserId int,@ClaimSponsored bit=0,@PaymentMethod varchar(12)='Cash',@MockPaymentID uniqueidentifier=NULL,@CashIdempotencyKey uniqueidentifier=NULL,@ResultStatus varchar(20)=NULL OUTPUT,@ReturnResult bit=1
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Capacity int,@Start datetime2(3),@GameStatus varchar(12),@Host int,@Slots int,@Cost decimal(10,2),@Currency char(3),@Revision int,@Status varchar(20);
  SELECT @Capacity=Capacity,@Start=StartsAt,@GameStatus=GameStatus,@Host=HostUserId,@Slots=SponsoredSlots,@Cost=CostPerPlayer,@Currency=Currency,@Revision=Revision
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Capacity IS NULL THROW 50001,'Event not found.',1;
  IF @GameStatus<>'Open' OR @Start<=SYSUTCDATETIME() THROW 50002,'Event is no longer open.',1;
  IF @PaymentMethod IS NULL OR @PaymentMethod NOT IN('Cash','Whish','WhishMock') THROW 50002,'Unknown payment method.',1;
  -- Whish is a provider integration boundary. Never pretend that selecting it paid.
  IF @PaymentMethod='Whish' AND @Cost>0 AND @ClaimSponsored=0
   THROW 50005,'Whish checkout requires the verified merchant integration. Choose cash at the venue for now.',1;
  IF @PaymentMethod='WhishMock' AND NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@MockPaymentID AND GameID=@GameId AND UserID=@UserId AND Status='MockPending' AND Mode='WhishMock' AND Amount=@Cost AND Currency=@Currency AND EventRevision=@Revision AND ExpiresAt>SYSUTCDATETIME())
   THROW 50003,'A matching mock checkout is required.',1;
  IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId)
  BEGIN
   IF @ClaimSponsored=1 AND NOT EXISTS(SELECT 1 FROM dbo.SponsoredSeats WHERE GameId=@GameId AND UserId=@UserId)
    THROW 50004,'You already joined at the standard fee. No sponsored place was claimed.',1;
   SET @Status='Joined';
  END
  ELSE IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId)
  BEGIN
   IF @ClaimSponsored=1 THROW 50004,'You are already queued. No sponsored place was claimed.',1;
   SET @Status='Waitlisted';
  END
  ELSE
  BEGIN
   IF @ClaimSponsored=1 AND (@UserId=@Host OR @Slots<=(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@GameId)
    OR @Capacity<=(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId))
     THROW 50004,'No host-covered place is available. Refresh to see current places.',1;
   IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)<@Capacity
   BEGIN
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@UserId,@PaymentMethod);
    IF @ClaimSponsored=1 INSERT dbo.SponsoredSeats(GameId,UserId) VALUES(@GameId,@UserId);
    IF @Cost>0 AND @ClaimSponsored=0 AND @PaymentMethod='Cash'
     INSERT dbo.Payments(UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision)
     VALUES(@UserId,@GameId,@Cost,dbo.PlatformServiceFee(@Cost),@Currency,'Cash','PendingCash',COALESCE(@CashIdempotencyKey,NEWID()),@Revision);
    SET @Status='Joined';
   END
   ELSE
   BEGIN
    INSERT dbo.Waitlists(GameId,UserId,PaymentMethod,AcceptedServiceFee) VALUES(@GameId,@UserId,@PaymentMethod,1);
    SET @Status='Waitlisted';
   END;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,@Status);
   INSERT dbo.UserActivityLogs(UserId,EventId,Action) VALUES(@UserId,@GameId,'JoinAttempt');
   IF @ClaimSponsored=1 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Sponsored');
   INSERT dbo.Notifications(UserId,GameId,Title,Body) VALUES(@UserId,@GameId,
    CASE WHEN @Status='Joined' THEN N'Your place is confirmed' ELSE N'You are on the waitlist' END,
    CASE WHEN @ClaimSponsored=1 THEN N'The host has agreed to cover your venue share. No money is transferred in the app.'
     WHEN @Status='Joined' THEN N'Check your event time and venue. Any venue share is settled directly with the host.'
     ELSE N'We will notify you if a place opens.' END);
   IF @Host<>@UserId INSERT dbo.Notifications(UserId,GameId,Title,Body)
    VALUES(@Host,@GameId,N'Your event has a new player',N'Someone joined your event or its waitlist.');
  END;
  COMMIT;
  SET @ResultStatus=@Status;
  IF @ReturnResult=1 SELECT @Status AS Status;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CancelParticipation @GameId int,@UserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int,@Start datetime2(3),@Status varchar(12),@NextUser int,@Waitlist bigint,@Method varchar(12),@AcceptedFee bit;
  SELECT @Id=EventId,@Start=StartsAt,@Status=GameStatus FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Id IS NULL THROW 50001,'Event not found.',1;
  IF @Start<=SYSUTCDATETIME() OR @Status<>'Open' THROW 50002,'Event is no longer open.',1;
  DELETE dbo.Participations WHERE GameId=@GameId AND UserId=@UserId;
  IF @@ROWCOUNT=1
  BEGIN
   UPDATE dbo.Payments SET Status=CASE WHEN Status='MockSucceeded' THEN 'MockCancelled' ELSE 'Cancelled' END
    WHERE GameID=@GameId AND UserID=@UserId AND Status IN('PendingCash','MockPending','MockSucceeded');
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Cancelled');
   SELECT TOP(1) @NextUser=UserId,@Waitlist=WaitlistId,@Method=PaymentMethod,@AcceptedFee=AcceptedServiceFee FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
   IF @NextUser IS NOT NULL
   BEGIN
    DELETE dbo.Waitlists WHERE WaitlistId=@Waitlist;
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@NextUser,@Method);
    INSERT dbo.Payments(UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision)
     SELECT @NextUser,EventId,CostPerPlayer,dbo.PlatformServiceFee(CostPerPlayer),Currency,'Cash','PendingCash',NEWID(),Revision
     FROM dbo.GamesAndEvents WHERE EventId=@GameId AND CostPerPlayer>0 AND @AcceptedFee=1;
    INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@NextUser,'Promoted');
    INSERT dbo.Notifications(UserId,GameId,Title,Body)
     VALUES(@NextUser,@GameId,N'A place opened. You are in!',N'You moved from the waitlist to the roster. Your original venue share and payment preference apply.');
   END;
  END
  ELSE
  BEGIN
   DELETE dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId;
   IF @@ROWCOUNT=1 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'LeftWaitlist');
  END;
  COMMIT;
  SELECT 'Cancelled' AS Status;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.EditGame
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
  IF @Owner IS NULL THROW 50001,'Game not found.',1;
  IF @Owner<>@HostUserId THROW 50003,'Only the host can edit this game.',1;
  IF @CurrentRevision<>@Revision THROW 50004,'Game changed. Refresh and try again.',1;
  IF @Status<>'Open' OR @OldStart<=SYSUTCDATETIME() OR @StartsAt<=SYSUTCDATETIME() THROW 50002,'Game cannot be edited.',1;
  IF @Capacity NOT BETWEEN 2 AND 100 OR @Capacity<(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)
   OR @SponsoredSlots<0 OR @SponsoredSlots>=@Capacity OR @SponsoredSlots<(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@GameId)
   OR @CostPerPlayer<0 OR @Currency NOT IN('USD','LBP') THROW 50002,'Invalid capacity, price or sponsored places.',1;
  -- Avoid silently changing financial expectations after other players commit.
  IF (@OldCost<>@CostPerPlayer OR @OldCurrency<>@Currency) AND
   (EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId<>@HostUserId) OR EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId))
   THROW 50002,'Price and currency cannot change after other players join.',1;
  UPDATE dbo.Games SET StartsAt=@StartsAt,Capacity=@Capacity,Description=@Description,CostPerPlayer=@CostPerPlayer,
   Currency=@Currency,SponsoredSlots=@SponsoredSlots,Revision=Revision+1 WHERE GameId=@GameId;
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,'Edited');
  -- Increasing capacity fills newly available places in FIFO order, without a loop.
  DECLARE @Open int=@Capacity-(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId);
  DECLARE @Promoted TABLE(UserId int PRIMARY KEY,WaitlistId bigint,PaymentMethod varchar(12),AcceptedServiceFee bit);
  INSERT @Promoted(UserId,WaitlistId,PaymentMethod,AcceptedServiceFee)
   SELECT TOP(@Open) UserId,WaitlistId,PaymentMethod,AcceptedServiceFee FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
  DELETE w FROM dbo.Waitlists w JOIN @Promoted p ON p.WaitlistId=w.WaitlistId;
  INSERT dbo.Participations(GameId,UserId,PaymentMethod) SELECT @GameId,UserId,PaymentMethod FROM @Promoted;
  INSERT dbo.Payments(UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision)
   SELECT p.UserId,g.EventId,g.CostPerPlayer,dbo.PlatformServiceFee(g.CostPerPlayer),g.Currency,'Cash','PendingCash',NEWID(),g.Revision
   FROM @Promoted p CROSS JOIN dbo.GamesAndEvents g WHERE g.EventId=@GameId AND g.CostPerPlayer>0 AND p.AcceptedServiceFee=1;
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) SELECT @GameId,UserId,'Promoted' FROM @Promoted;
  INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT UserId,@GameId,N'A place opened. You are in!',N'The host opened more places and you moved from the waitlist to the roster. Your standard venue share applies.' FROM @Promoted;

  INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT UserId,@GameId,N'Your game was updated',N'The host changed the game details. Review the time and information before playing.'
   FROM (SELECT UserId FROM dbo.Participations WHERE GameId=@GameId UNION SELECT UserId FROM dbo.Waitlists WHERE GameId=@GameId) members
   WHERE UserId<>@HostUserId;
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CancelGame @GameId int,@HostUserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Owner int,@Status varchar(12),@Start datetime2(3);
  SELECT @Owner=HostUserId,@Status=GameStatus,@Start=StartsAt FROM dbo.Games WITH(UPDLOCK,HOLDLOCK) WHERE GameId=@GameId;
  IF @Owner IS NULL THROW 50001,'Game not found.',1;
  IF @Owner<>@HostUserId THROW 50003,'Only the host can cancel this game.',1;
  IF @Status='Open'
  BEGIN
   IF @Start<=SYSUTCDATETIME() THROW 50002,'Past games cannot be cancelled.',1;
   UPDATE dbo.Games SET GameStatus='Cancelled',Revision=Revision+1 WHERE GameId=@GameId;
   UPDATE dbo.Payments SET Status=CASE WHEN Status='MockSucceeded' THEN 'MockCancelled' ELSE 'Cancelled' END
    WHERE GameID=@GameId AND Status IN('PendingCash','MockPending','MockSucceeded');
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,'GameCancelled');
   INSERT dbo.Notifications(UserId,GameId,Title,Body)
    SELECT UserId,@GameId,N'Game cancelled',N'The host cancelled your game. Find another game in Discover.'
    FROM (SELECT UserId FROM dbo.Participations WHERE GameId=@GameId UNION SELECT UserId FROM dbo.Waitlists WHERE GameId=@GameId) members
    WHERE UserId<>@HostUserId;
  END;
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.InitializeCheckout
 @GameId int,@UserId int,@Mode varchar(12),@IdempotencyKey uniqueidentifier,@ExpectedRevision int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Cost decimal(12,2),@Currency char(3),@Revision int,@Capacity int,@Start datetime2(3),@State varchar(12),@ID uniqueidentifier;
  SELECT @Cost=CostPerPlayer,@Currency=Currency,@Revision=Revision,@Capacity=Capacity,@Start=StartsAt,@State=GameStatus
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Cost IS NULL THROW 50001,'Event not found.',1;
  IF @Mode NOT IN('Cash','WhishMock') OR @Mode IS NULL OR @IdempotencyKey IS NULL THROW 50002,'Invalid checkout.',1;
  SELECT @ID=PaymentID FROM dbo.Payments WHERE UserID=@UserId AND IdempotencyKey=@IdempotencyKey;
  IF @ID IS NOT NULL
  BEGIN
   IF NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@ID AND GameID=@GameId AND Mode=@Mode) THROW 50004,'Checkout key was used for a different booking.',1;
  END
  ELSE
  BEGIN
   IF @ExpectedRevision IS NULL OR @ExpectedRevision<>@Revision THROW 50004,'Event changed. Review the latest fee quote.',1;
   IF @State<>'Open' OR @Start<=SYSUTCDATETIME() THROW 50002,'Event is no longer open.',1;
   IF @Mode='Cash'
   BEGIN
    DECLARE @OutcomeStatus varchar(20);
    EXEC dbo.sp_JoinGameOrActivity @GameId=@GameId,@UserId=@UserId,@PaymentMethod='Cash',@CashIdempotencyKey=@IdempotencyKey,@ResultStatus=@OutcomeStatus OUTPUT,@ReturnResult=0;
    SELECT TOP(1) @ID=PaymentID FROM dbo.Payments WHERE GameID=@GameId AND UserID=@UserId AND Status IN('PendingCash','MockSucceeded') ORDER BY CreatedAt DESC;
    IF @ID IS NULL
    BEGIN
     COMMIT;
     SELECT @OutcomeStatus AS Status,CAST(NULL AS uniqueidentifier) AS PaymentId,
      @Cost AS Amount,dbo.PlatformServiceFee(@Cost) AS ServiceFee,@Cost+dbo.PlatformServiceFee(@Cost) AS TotalAmount,@Currency AS Currency,'Cash' AS Mode;
     RETURN;
    END;
   END
   ELSE
   BEGIN
    IF @Cost<=0 THROW 50002,'Free places do not require a payment checkout.',1;
    IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId)
     OR EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId) THROW 50004,'You are already enrolled or queued.',1;
    IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)>=@Capacity THROW 50004,'Event is full. Join the waitlist without payment.',1;
    UPDATE dbo.Payments SET Status='Expired' WHERE GameID=@GameId AND UserID=@UserId AND Status='MockPending' AND (ExpiresAt<=SYSUTCDATETIME() OR EventRevision<>@Revision);
    SELECT @ID=PaymentID FROM dbo.Payments WHERE GameID=@GameId AND UserID=@UserId AND Status='MockPending';
    IF @ID IS NULL
    BEGIN
     SET @ID=NEWID();
     INSERT dbo.Payments(PaymentID,UserID,GameID,Amount,ServiceFee,Currency,Mode,Status,IdempotencyKey,EventRevision,ExpiresAt)
      VALUES(@ID,@UserId,@GameId,@Cost,dbo.PlatformServiceFee(@Cost),@Currency,'WhishMock','MockPending',@IdempotencyKey,@Revision,DATEADD(minute,10,SYSUTCDATETIME()));
    END;
   END;
  END;
  COMMIT;
  SELECT PaymentID AS PaymentId,GameID AS GameId,Amount,ServiceFee,TotalAmount,Currency,Mode,Status,GatewayTransactionID AS GatewayTransactionId,CreatedAt,ExpiresAt FROM dbo.Payments WHERE PaymentID=@ID;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
-- Called ONLY after the API validates the mock provider's raw-body HMAC.
CREATE OR ALTER PROCEDURE dbo.ApplyMockPaymentWebhook
 @WebhookEventID uniqueidentifier,@PaymentID uniqueidentifier,@GatewayTransactionID nvarchar(128),
 @Outcome varchar(12),@TotalAmount decimal(12,2),@Currency char(3),@PayloadHash binary(32)
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Game int,@User int,@Amount decimal(12,2),@Expected decimal(13,2),@StoredCurrency char(3),@Status varchar(24),@Expiry datetime2(3),@Revision int,
   @ActualRevision int,@GameStatus varchar(12),@Start datetime2(3),@Capacity int;
  SELECT @Game=GameID FROM dbo.Payments WHERE PaymentID=@PaymentID AND Mode='WhishMock';
  IF @Game IS NULL THROW 50001,'Mock payment not found.',1;
  SELECT @ActualRevision=Revision,@GameStatus=GameStatus,@Start=StartsAt,@Capacity=Capacity
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@Game;
  SELECT @User=UserID,@Amount=Amount,@Expected=TotalAmount,@StoredCurrency=Currency,@Status=Status,@Expiry=ExpiresAt,@Revision=EventRevision
   FROM dbo.Payments WITH(UPDLOCK,HOLDLOCK) WHERE PaymentID=@PaymentID;
  IF @Outcome IS NULL OR @Outcome NOT IN('success','failed') OR @TotalAmount IS NULL OR @TotalAmount<>@Expected OR @Currency IS NULL OR @Currency<>@StoredCurrency OR @GatewayTransactionID IS NULL OR LEN(TRIM(@GatewayTransactionID))=0
   THROW 50002,'Payment verification fields do not match the checkout.',1;
  IF @Status<>'MockPending' AND EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@PaymentID AND GatewayTransactionID IS NOT NULL AND GatewayTransactionID<>@GatewayTransactionID)
   THROW 50004,'Gateway reference conflicts with the existing result.',1;
  IF EXISTS(SELECT 1 FROM dbo.PaymentWebhookEvents WHERE WebhookEventID=@WebhookEventID)
  BEGIN
   IF NOT EXISTS(SELECT 1 FROM dbo.PaymentWebhookEvents WHERE WebhookEventID=@WebhookEventID AND PaymentID=@PaymentID AND PayloadHash=@PayloadHash)
    THROW 50004,'Webhook id was reused with a different payload.',1;
  END
  ELSE
  BEGIN
   INSERT dbo.PaymentWebhookEvents(WebhookEventID,PaymentID,PayloadHash) VALUES(@WebhookEventID,@PaymentID,@PayloadHash);
   IF @Status='MockPending'
   BEGIN
    IF @Expiry<=SYSUTCDATETIME() SET @Status='Expired';
    ELSE IF @Outcome='failed' OR @GameStatus<>'Open' OR @Start<=SYSUTCDATETIME() OR @Revision<>@ActualRevision
     OR (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game)>=@Capacity
     OR EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@User)
     OR EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@Game AND UserId=@User) SET @Status='MockFailed';
    ELSE
    BEGIN
     DECLARE @JoinedStatus varchar(20);
     EXEC dbo.sp_JoinGameOrActivity @GameId=@Game,@UserId=@User,@PaymentMethod='WhishMock',@MockPaymentID=@PaymentID,@ResultStatus=@JoinedStatus OUTPUT,@ReturnResult=0;
     IF @JoinedStatus<>'Joined' THROW 50004,'A place is no longer available.',1;
     SET @Status='MockSucceeded';
    END;
    UPDATE dbo.Payments SET Status=@Status,GatewayTransactionID=@GatewayTransactionID,CompletedAt=SYSUTCDATETIME() WHERE PaymentID=@PaymentID;
   END;
  END;
  COMMIT;
  SELECT PaymentID AS PaymentId,GameID AS GameId,Amount,ServiceFee,TotalAmount,Currency,Mode,Status,GatewayTransactionID AS GatewayTransactionId FROM dbo.Payments WHERE PaymentID=@PaymentID;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
GRANT EXECUTE ON dbo.GetSponsoredVenues TO gameon_executor;
GRANT EXECUTE ON dbo.GetPaymentQuote TO gameon_executor;
GRANT EXECUTE ON dbo.GetPayment TO gameon_executor;
GRANT EXECUTE ON dbo.InitializeCheckout TO gameon_executor;
GRANT EXECUTE ON dbo.ApplyMockPaymentWebhook TO gameon_executor;
INSERT dbo.PlatformMigrations(Version) VALUES(13);
COMMIT;
GO
