-- GameOn migration 37: remove the $1 commitment deposit, the wallet and in-app payments from every live flow;
-- self-service "List your venue" (courts with a price per duration, 10% GameOn commission per booking);
-- Free / Premium subscriptions (Premium = the existing Pro membership, with free water on 1h+ court bookings).
-- Requires migration 36. Back up GameOn and stop the API first.
-- Run from the REPOSITORY ROOT with a DBA identity (QUOTED_IDENTIFIER must be ON, hence -I):
--   sqlcmd -S localhost -E -I -b -i database/37-list-venue-subscriptions.sql
-- Old wallet / deposit / payment tables are kept as read-only history (nothing writes to them any more).
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF;
IF @@TRANCOUNT<>0 THROW 50002,'Open a fresh query with no active transaction.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=36) THROW 50002,'Install migration 36 first.',1;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=37) THROW 50002,'Migration 37 is already installed. Do not rerun it.',1;
BEGIN TRY
 BEGIN TRANSACTION;
 -- ===== No more $1 deposit: every game is joined directly =====
 DECLARE @df sysname=(SELECT d.name FROM sys.default_constraints d JOIN sys.columns c ON c.object_id=d.parent_object_id AND c.column_id=d.parent_column_id
  WHERE d.parent_object_id=OBJECT_ID('dbo.GamesAndEvents') AND c.name='RequiresDeposit');
 IF @df IS NOT NULL EXEC(N'ALTER TABLE dbo.GamesAndEvents DROP CONSTRAINT '+@df);
 EXEC(N'ALTER TABLE dbo.GamesAndEvents ADD CONSTRAINT DF_Games_RequiresDeposit DEFAULT 0 FOR RequiresDeposit;');
 EXEC(N'UPDATE dbo.GamesAndEvents SET RequiresDeposit=0 WHERE RequiresDeposit=1;');

 -- ===== Venues listed by their owners =====
 EXEC(N'ALTER TABLE dbo.Clubs ADD CommissionPct tinyint NOT NULL CONSTRAINT DF_Clubs_Commission DEFAULT 0 CONSTRAINT CK_Clubs_Commission CHECK(CommissionPct<=30),
  IsSelfListed bit NOT NULL CONSTRAINT DF_Clubs_SelfListed DEFAULT 0;');
 EXEC(N'CREATE TABLE dbo.CourtPrices(CourtId int NOT NULL CONSTRAINT FK_CourtPrices_Court REFERENCES dbo.Courts(CourtId),
  Minutes smallint NOT NULL CONSTRAINT CK_CourtPrices_Minutes CHECK(Minutes IN(30,60,90,120,150,180)),
  Price decimal(10,2) NOT NULL CONSTRAINT CK_CourtPrices_Price CHECK(Price>=0 AND Price<=10000),
  CONSTRAINT PK_CourtPrices PRIMARY KEY(CourtId,Minutes));');
 -- GameOn's share of each booking (CommissionPct of the price) and the Premium free-water perk.
 EXEC(N'ALTER TABLE dbo.CourtBookings ADD PlatformFee decimal(10,2) NOT NULL CONSTRAINT DF_CB_PlatformFee DEFAULT 0,
  FreeWater bit NOT NULL CONSTRAINT DF_CB_FreeWater DEFAULT 0;');
 INSERT dbo.PlatformMigrations(Version) VALUES(37);
 COMMIT;
END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
GO

-- Joining a game: no deposit, no in-app payment. Venue shares are settled with the host in person.
CREATE OR ALTER PROCEDURE dbo.sp_JoinGameOrActivity
 @GameId int,@UserId int,@ClaimSponsored bit=0,@PaymentMethod varchar(12)='Cash',@MockPaymentID uniqueidentifier=NULL,@CashIdempotencyKey uniqueidentifier=NULL,@ResultStatus varchar(20)=NULL OUTPUT,@ReturnResult bit=1,@DepositAuthorizationID uniqueidentifier=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Capacity int,@Start datetime2(3),@GameStatus varchar(12),@Host int,@Slots int,@Status varchar(20);
  SELECT @Capacity=Capacity,@Start=StartsAt,@GameStatus=GameStatus,@Host=HostUserId,@Slots=SponsoredSlots
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Capacity IS NULL THROW 50001,'Event not found.',1;
  IF @GameStatus<>'Open' OR @Start<=SYSUTCDATETIME() THROW 50002,'Event is no longer open.',1;
  IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId)
  BEGIN
   IF @ClaimSponsored=1 AND NOT EXISTS(SELECT 1 FROM dbo.SponsoredSeats WHERE GameId=@GameId AND UserId=@UserId)
    THROW 50004,'You already joined this game. No host-covered place was claimed.',1;
   SET @Status='Joined';
  END
  ELSE IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId)
  BEGIN
   IF @ClaimSponsored=1 THROW 50004,'You are already queued. No host-covered place was claimed.',1;
   SET @Status='Waitlisted';
  END
  ELSE
  BEGIN
   IF @ClaimSponsored=1 AND (@UserId=@Host OR @Slots<=(SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@GameId)
    OR @Capacity<=(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId))
     THROW 50004,'No host-covered place is available. Refresh to see current places.',1;
   IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)<@Capacity
   BEGIN
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@UserId,'Cash');
    IF @ClaimSponsored=1 INSERT dbo.SponsoredSeats(GameId,UserId) VALUES(@GameId,@UserId);
    SET @Status='Joined';
   END
   ELSE
   BEGIN
    INSERT dbo.Waitlists(GameId,UserId,PaymentMethod,AcceptedServiceFee) VALUES(@GameId,@UserId,'Cash',0);
    SET @Status='Waitlisted';
   END;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,@Status);
   INSERT dbo.UserActivityLogs(UserId,EventId,Action) VALUES(@UserId,@GameId,'JoinAttempt');
   IF @ClaimSponsored=1 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Sponsored');
   INSERT dbo.Notifications(UserId,GameId,Title,Body) VALUES(@UserId,@GameId,
    CASE WHEN @Status='Joined' THEN N'Your place is confirmed' ELSE N'You are on the waitlist' END,
    CASE WHEN @ClaimSponsored=1 THEN N'The host has agreed to cover your venue share.'
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

-- Court booking: always paid at the club. Courts with a price list are booked for one of their durations.
CREATE OR ALTER PROCEDURE dbo.BookCourt @CourtId int,@UserId int,@StartsAtUtc datetime2(0),@Key uniqueidentifier,@RedemptionCode char(10)=NULL,@GuestName nvarchar(80)=NULL,@PayFromWallet bit=0,@DurationMinutes smallint=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Club int,@Slot smallint,@Open tinyint,@Close tinyint,@Base decimal(10,2),@Peak decimal(10,2),@PS tinyint,@PE tinyint,@Active bit,@Approval bit;
  SELECT @Club=ClubId,@Slot=SlotMinutes,@Open=OpenHour,@Close=CloseHour,@Base=BasePrice,@Peak=PeakPrice,@PS=PeakStartHour,@PE=PeakEndHour,@Active=IsActive,@Approval=RequiresApproval
  FROM dbo.Courts WITH(UPDLOCK,HOLDLOCK) WHERE CourtId=@CourtId;
  IF @Club IS NULL OR @Active=0 THROW 50001,'Court not found.',1;
  DECLARE @Existing bigint=(SELECT BookingId FROM dbo.CourtBookings WHERE CreatedBy=@UserId AND IdempotencyKey=@Key);
  IF @Existing IS NOT NULL BEGIN COMMIT; SELECT BookingId,Price,ListPrice,Discount,StartsAt,EndsAt,Status,CAST(0 AS bit) AS PaidFromWallet,FreeWater FROM dbo.CourtBookings WHERE BookingId=@Existing; RETURN; END;
  DECLARE @Staff bit=CASE WHEN @GuestName IS NOT NULL THEN 1 ELSE 0 END;
  IF @Staff=1 AND dbo.ClubRoleRank(@Club,@UserId)<2 THROW 50003,'Only club staff can book for walk-in guests.',1;
  DECLARE @HasPrices bit=CASE WHEN EXISTS(SELECT 1 FROM dbo.CourtPrices WHERE CourtId=@CourtId) THEN 1 ELSE 0 END;
  DECLARE @Minutes smallint=CASE WHEN @HasPrices=1 THEN COALESCE(@DurationMinutes,(SELECT MIN(Minutes) FROM dbo.CourtPrices WHERE CourtId=@CourtId)) ELSE @Slot END;
  IF @HasPrices=1 AND NOT EXISTS(SELECT 1 FROM dbo.CourtPrices WHERE CourtId=@CourtId AND Minutes=@Minutes) THROW 50002,'Choose one of the durations this court offers.',1;
  DECLARE @Local datetime2(0)=dbo.ToBeirut(@StartsAtUtc),@End datetime2(0)=DATEADD(minute,@Minutes,@StartsAtUtc);
  DECLARE @Minute int=DATEPART(hour,@Local)*60+DATEPART(minute,@Local);
  IF @StartsAtUtc<=SYSUTCDATETIME() THROW 50002,'Choose a future time.',1;
  IF @StartsAtUtc>DATEADD(day,60,SYSUTCDATETIME()) THROW 50002,'Bookings open up to 60 days ahead.',1;
  IF @Minute<@Open*60 OR (@Minute-@Open*60)%@Slot<>0 OR DATEPART(second,@Local)<>0 THROW 50002,'Choose one of the listed time slots.',1;
  IF @Minute+@Minutes>@Close*60 THROW 50002,'That duration runs past closing time. Pick a shorter one or an earlier start.',1;
  IF EXISTS(SELECT 1 FROM dbo.CourtBlocks WHERE CourtId=@CourtId AND StartsAt<@End AND EndsAt>@StartsAtUtc) THROW 50004,'The club has blocked part of this time.',1;
  IF EXISTS(SELECT 1 FROM dbo.CourtBookings WHERE CourtId=@CourtId AND Status IN('Pending','Confirmed','Completed','NoShow') AND StartsAt<@End AND EndsAt>@StartsAtUtc) THROW 50004,'Part of this time is already booked. Pick another time or a shorter duration.',1;
  IF @Staff=0 AND (SELECT COUNT(*) FROM dbo.CourtBookings WHERE UserId=@UserId AND Status IN('Pending','Confirmed') AND StartsAt>SYSUTCDATETIME())>=6 THROW 50004,'You can hold up to 6 upcoming court bookings.',1;
  DECLARE @List decimal(10,2)=CASE WHEN @HasPrices=1 THEN (SELECT Price FROM dbo.CourtPrices WHERE CourtId=@CourtId AND Minutes=@Minutes)
   WHEN DATEPART(hour,@Local)>=@PS AND DATEPART(hour,@Local)<@PE THEN @Peak ELSE @Base END,@Discount decimal(10,2)=0,@ProUsed bit=0,@Redemption bigint=NULL;
  DECLARE @IsPro bit=CASE WHEN @Staff=0 THEN dbo.IsPro(@UserId) ELSE 0 END;
  IF @IsPro=1
  BEGIN
   DECLARE @ProPct tinyint=(SELECT CASE WHEN IsPartner=1 THEN ProDiscountPct ELSE 0 END FROM dbo.Clubs WHERE ClubId=@Club);
   IF @ProPct>0 BEGIN SET @Discount=ROUND(@List*@ProPct/100.0,2); SET @ProUsed=1; END;
  END;
  IF @RedemptionCode IS NOT NULL
  BEGIN
   DECLARE @Pct tinyint,@RClub int;
   SELECT @Redemption=x.RedemptionId,@Pct=r.DiscountPct,@RClub=r.ClubId FROM dbo.RewardRedemptions x WITH(UPDLOCK,HOLDLOCK) JOIN dbo.Rewards r ON r.RewardId=x.RewardId
   WHERE x.Code=@RedemptionCode AND x.UserId=@UserId AND x.Status='Issued' AND x.ExpiresAt>SYSUTCDATETIME() AND r.Kind='CourtDiscount';
   IF @Redemption IS NULL THROW 50002,'That reward code is not valid, already used, or expired.',1;
   IF @RClub IS NOT NULL AND @RClub<>@Club THROW 50002,'That reward is for a different club.',1;
   SET @Discount=@Discount+ROUND((@List-@Discount)*@Pct/100.0,2);
   UPDATE dbo.RewardRedemptions SET Status='Used',UsedAt=SYSUTCDATETIME() WHERE RedemptionId=@Redemption;
  END;
  DECLARE @FreeWater bit=CASE WHEN @IsPro=1 AND @Minutes>=60 THEN 1 ELSE 0 END;
  DECLARE @Commission tinyint=(SELECT CommissionPct FROM dbo.Clubs WHERE ClubId=@Club);
  DECLARE @Status varchar(10)=CASE WHEN @Staff=0 AND @Approval=1 THEN 'Pending' ELSE 'Confirmed' END;
  INSERT dbo.CourtBookings(CourtId,UserId,GuestName,StartsAt,EndsAt,ListPrice,Discount,Status,Source,CreatedBy,IdempotencyKey,RedemptionId,ProDiscount,PaidFromWallet,PlatformFee,FreeWater)
  VALUES(@CourtId,IIF(@Staff=1,NULL,@UserId),@GuestName,@StartsAtUtc,@End,@List,@Discount,@Status,IIF(@Staff=1,'Staff','Player'),@UserId,@Key,@Redemption,@ProUsed,0,
   ROUND((@List-@Discount)*@Commission/100.0,2),@FreeWater);
  DECLARE @Id bigint=SCOPE_IDENTITY();
  IF @Staff=1 EXEC dbo.LogStaff @Club,@UserId,'WalkInBooked',@GuestName;
  IF @Staff=0
  BEGIN
   DECLARE @Pts int=CASE WHEN @IsPro=1 THEN 30 ELSE 20 END;
   EXEC dbo.LoyaltyPost @UserId,@Pts,'CourtBooking','Booking',@Id,N'Court booking';
   INSERT dbo.UserActivityLogs(UserId,SubtypeId,Action) SELECT @UserId,SubtypeId,'CourtBooked' FROM dbo.Courts WHERE CourtId=@CourtId;
   INSERT dbo.Notifications(UserId,Title,Body) SELECT s.UserId,IIF(@Status='Pending',N'Booking request to approve',N'New court booking'),
    LEFT(N'A player booked '+k.Name+N' at '+FORMAT(@Local,'ddd d MMM HH:mm')+N' for '+CAST(@Minutes AS nvarchar(4))+N' min'
     +IIF(@FreeWater=1,N'. Premium member: include a free water bottle',N'')+IIF(@Status='Pending',N'. Approve or decline it in Club manager.',N'.'),800)
   FROM dbo.ClubStaff s JOIN dbo.Courts k ON k.ClubId=s.ClubId WHERE k.CourtId=@CourtId AND s.Role IN('Owner','Manager','Reception');
  END;
  COMMIT;
  SELECT BookingId,Price,ListPrice,Discount,StartsAt,EndsAt,Status,CAST(0 AS bit) AS PaidFromWallet,FreeWater FROM dbo.CourtBookings WHERE BookingId=@Id;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO

-- Club memberships and class packs are reserved in the app and paid at the club.
CREATE OR ALTER PROCEDURE dbo.BuyClubProduct @ProductId int,@UserId int,@Key uniqueidentifier AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id bigint=(SELECT PurchaseId FROM dbo.ClubPurchases WHERE UserId=@UserId AND IdempotencyKey=@Key);
  IF @Id IS NULL
  BEGIN
   DECLARE @Club int,@Kind varchar(10),@Price decimal(10,2),@Days smallint,@Credits smallint;
   SELECT @Club=ClubId,@Kind=Kind,@Price=Price,@Days=DurationDays,@Credits=Credits FROM dbo.ClubProducts WITH(UPDLOCK,HOLDLOCK) WHERE ProductId=@ProductId AND IsActive=1;
   IF @Club IS NULL THROW 50001,'This membership or pack is not on sale.',1;
   DECLARE @Start datetime2(3)=SYSUTCDATETIME();
   IF @Kind='Membership' SET @Start=COALESCE((SELECT MAX(EndsAt) FROM dbo.ClubPurchases WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId AND ClubId=@Club AND Kind='Membership' AND Status='Active' AND EndsAt>SYSUTCDATETIME()),@Start);
   INSERT dbo.ClubPurchases(ProductId,ClubId,UserId,Kind,Price,StartsAt,EndsAt,CreditsLeft,AccessCode,IdempotencyKey)
   VALUES(@ProductId,@Club,@UserId,@Kind,@Price,@Start,DATEADD(day,@Days,@Start),@Credits,UPPER(LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12)),@Key);
   SET @Id=SCOPE_IDENTITY();
   INSERT dbo.Notifications(UserId,Title,Body) SELECT s.UserId,N'New member purchase',LEFT(N'A player took '+p.Name+N'. Collect the payment at the club.',800) FROM dbo.ClubStaff s JOIN dbo.ClubProducts p ON p.ClubId=s.ClubId WHERE p.ProductId=@ProductId AND s.Role IN('Owner','Manager');
  END;
  COMMIT;
  SELECT x.PurchaseId,x.Kind,p.Name,x.StartsAt,x.EndsAt,x.CreditsLeft,x.AccessCode FROM dbo.ClubPurchases x JOIN dbo.ClubProducts p ON p.ProductId=x.ProductId WHERE x.PurchaseId=@Id;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO

-- Premium subscription (stored as a Pro membership). Demo: no money is collected in the app.
CREATE OR ALTER PROCEDURE dbo.ActivatePremium @UserId int,@Key uniqueidentifier,@Price decimal(10,2),@Days int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @Price<0 OR @Days NOT BETWEEN 1 AND 366 THROW 50002,'Invalid Premium plan.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id bigint=(SELECT MembershipId FROM dbo.Memberships WHERE UserId=@UserId AND IdempotencyKey=@Key);
  IF @Id IS NULL
  BEGIN
   -- Renewals extend from the current end date, never overlapping.
   DECLARE @Start datetime2(3)=(SELECT MAX(EndsAt) FROM dbo.Memberships WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId AND EndsAt>SYSUTCDATETIME());
   DECLARE @First bit=CASE WHEN @Start IS NULL THEN 1 ELSE 0 END;
   SET @Start=COALESCE(@Start,SYSUTCDATETIME());
   INSERT dbo.Memberships(UserId,Tier,StartsAt,EndsAt,PricePaid,IdempotencyKey) VALUES(@UserId,'Pro',@Start,DATEADD(day,@Days,@Start),@Price,@Key);
   SET @Id=SCOPE_IDENTITY();
   IF @First=1 EXEC dbo.LoyaltyPost @UserId,100,'ProBonus','Membership',@Id,N'Welcome to GameOn Premium';
   INSERT dbo.Notifications(UserId,Title,Body) VALUES(@UserId,N'GameOn Premium is active',N'Enjoy partner-court discounts, free water on 1h+ court bookings and extra points.');
  END;
  COMMIT;
  SELECT MembershipId,StartsAt,EndsAt FROM dbo.Memberships WHERE MembershipId=@Id;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.CancelPremium @UserId int AS
BEGIN
 SET NOCOUNT ON;
 -- Ends the subscription now (no renewals are ever charged).
 UPDATE dbo.Memberships SET EndsAt=SYSUTCDATETIME() WHERE UserId=@UserId AND EndsAt>SYSUTCDATETIME() AND StartsAt<=SYSUTCDATETIME();
 DELETE dbo.Memberships WHERE UserId=@UserId AND StartsAt>SYSUTCDATETIME();
 SELECT CAST(dbo.IsPro(@UserId) AS bit) AS IsPro;
END;
GO

-- Price list per court (for the booking sheet).
CREATE OR ALTER PROCEDURE dbo.GetCourtPrices @ClubId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT p.CourtId,p.Minutes,p.Price FROM dbo.CourtPrices p JOIN dbo.Courts k ON k.CourtId=p.CourtId WHERE k.ClubId=@ClubId AND k.IsActive=1 ORDER BY p.CourtId,p.Minutes;
END;
GO

-- Create or update a venue listed by its owner. Courts not sent are removed (kept inactive for booking history).
-- @CourtsJson: [{"courtId":null|int,"name":"Court 1","subtypeId":3,"prices":[{"minutes":60,"price":30}, ...]}, ...]
CREATE OR ALTER PROCEDURE dbo.SaveMyVenue @UserId int,@ClubId int=NULL,@Name nvarchar(120),@Area nvarchar(80),@Address nvarchar(250),
 @Latitude decimal(10,7)=NULL,@Longitude decimal(10,7)=NULL,@Phone varchar(20)=NULL,@OpenHour tinyint,@CloseHour tinyint,@CourtsJson nvarchar(max),@AcceptFee bit=0 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NULLIF(TRIM(@Name),N'') IS NULL OR NULLIF(TRIM(@Area),N'') IS NULL OR NULLIF(TRIM(@Address),N'') IS NULL THROW 50002,'Enter the venue name, town and address.',1;
 IF @OpenHour>=@CloseHour OR @CloseHour>24 THROW 50002,'Opening hour must be before closing hour.',1;
 IF (@Latitude IS NULL AND @Longitude IS NOT NULL) OR (@Latitude IS NOT NULL AND @Longitude IS NULL) OR (@Latitude IS NOT NULL AND (@Latitude NOT BETWEEN 33 AND 34.8 OR @Longitude NOT BETWEEN 35 AND 36.7)) THROW 50002,'Pick a location inside Lebanon.',1;
 IF ISJSON(@CourtsJson)<>1 THROW 50002,'Add at least one court.',1;
 DECLARE @Courts TABLE(Idx int PRIMARY KEY,CourtId int NULL,Name nvarchar(80),SubtypeId int,Prices nvarchar(max));
 INSERT @Courts SELECT CAST([key] AS int),TRY_CONVERT(int,JSON_VALUE(value,'$.courtId')),LEFT(TRIM(JSON_VALUE(value,'$.name')),80),TRY_CONVERT(int,JSON_VALUE(value,'$.subtypeId')),JSON_QUERY(value,'$.prices') FROM OPENJSON(@CourtsJson);
 DECLARE @Prices TABLE(Idx int,Minutes smallint,Price decimal(10,2),PRIMARY KEY(Idx,Minutes));
 BEGIN TRY
  INSERT @Prices SELECT c.Idx,TRY_CONVERT(smallint,JSON_VALUE(p.value,'$.minutes')),TRY_CONVERT(decimal(10,2),JSON_VALUE(p.value,'$.price')) FROM @Courts c CROSS APPLY OPENJSON(c.Prices) p;
 END TRY BEGIN CATCH THROW 50002,'Each court can list each duration only once.',1; END CATCH;
 IF NOT EXISTS(SELECT 1 FROM @Courts) OR (SELECT COUNT(*) FROM @Courts)>20 THROW 50002,'List between 1 and 20 courts.',1;
 IF EXISTS(SELECT 1 FROM @Courts c WHERE NULLIF(c.Name,N'') IS NULL OR c.SubtypeId IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.Subtypes s WHERE s.SubtypeId=c.SubtypeId)) THROW 50002,'Give every court a name and a sport.',1;
 IF EXISTS(SELECT 1 FROM @Courts c WHERE NOT EXISTS(SELECT 1 FROM @Prices p WHERE p.Idx=c.Idx)) THROW 50002,'Give every court at least one price.',1;
 IF EXISTS(SELECT 1 FROM @Prices WHERE Minutes IS NULL OR Minutes NOT IN(30,60,90,120,150,180) OR Price IS NULL OR Price<0 OR Price>10000) THROW 50002,'Prices must be for 30 min to 3 h, between $0 and $10,000.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Venue int;
  IF @ClubId IS NULL
  BEGIN
   IF @AcceptFee<>1 THROW 50002,'Accept the 10% GameOn fee on bookings to list your venue.',1;
   IF (SELECT COUNT(*) FROM dbo.Clubs WHERE CreatedBy=@UserId AND IsSelfListed=1 AND IsActive=1)>=5 THROW 50004,'You can list up to 5 venues.',1;
   INSERT dbo.Venues(Name,Area,Address,Latitude,Longitude,ContactPhoneNumber,IsVerified,ListingStatus,ReservationMode,SourceName)
   VALUES(TRIM(@Name),TRIM(@Area),TRIM(@Address),@Latitude,@Longitude,@Phone,0,'Unverified','OnlineBooking',N'Listed by owner on GameOn');
   SET @Venue=SCOPE_IDENTITY();
   INSERT dbo.Clubs(Name,VenueId,IsPartner,ProDiscountPct,CreatedBy,CommissionPct,IsSelfListed) VALUES(TRIM(@Name),@Venue,0,0,@UserId,10,1);
   SET @ClubId=SCOPE_IDENTITY();
   INSERT dbo.ClubStaff(ClubId,UserId,Role,AddedBy) VALUES(@ClubId,@UserId,'Owner',@UserId);
   INSERT dbo.Notifications(UserId,Title,Body) VALUES(@UserId,N'Your venue is listed',N'Players can now book your courts in Courts. GameOn keeps 10% of every booking. Manage bookings in Club manager.');
  END
  ELSE
  BEGIN
   IF NOT EXISTS(SELECT 1 FROM dbo.ClubStaff WHERE ClubId=@ClubId AND UserId=@UserId AND Role='Owner') THROW 50003,'Only the venue owner can edit this listing.',1;
   SET @Venue=(SELECT VenueId FROM dbo.Clubs WHERE ClubId=@ClubId);
   UPDATE dbo.Clubs SET Name=TRIM(@Name) WHERE ClubId=@ClubId;
   UPDATE dbo.Venues SET Name=TRIM(@Name),Area=TRIM(@Area),Address=TRIM(@Address),Latitude=@Latitude,Longitude=@Longitude,ContactPhoneNumber=@Phone WHERE VenueId=@Venue;
  END;
  IF EXISTS(SELECT 1 FROM @Courts c WHERE c.CourtId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Courts k WHERE k.CourtId=c.CourtId AND k.ClubId=@ClubId)) THROW 50002,'One of the courts does not belong to this venue.',1;
  -- Removed courts: hidden from players, kept for past bookings.
  UPDATE dbo.Courts SET IsActive=0,Revision=Revision+1 WHERE ClubId=@ClubId AND IsActive=1 AND CourtId NOT IN(SELECT CourtId FROM @Courts WHERE CourtId IS NOT NULL);
  DECLARE @Idx int=(SELECT MIN(Idx) FROM @Courts),@Cid int,@CName nvarchar(80),@Sub int,@From decimal(10,2);
  WHILE @Idx IS NOT NULL
  BEGIN
   SELECT @Cid=CourtId,@CName=Name,@Sub=SubtypeId FROM @Courts WHERE Idx=@Idx;
   SET @From=(SELECT TOP(1) Price FROM @Prices WHERE Idx=@Idx ORDER BY Minutes);
   IF @Cid IS NULL
   BEGIN
    INSERT dbo.Courts(ClubId,Name,SubtypeId,SlotMinutes,OpenHour,CloseHour,BasePrice,PeakPrice,PeakStartHour,PeakEndHour,IsActive)
    VALUES(@ClubId,@CName,@Sub,30,@OpenHour,@CloseHour,@From,@From,0,0,1);
    SET @Cid=SCOPE_IDENTITY();
   END
   ELSE
    UPDATE dbo.Courts SET Name=@CName,SubtypeId=@Sub,SlotMinutes=30,OpenHour=@OpenHour,CloseHour=@CloseHour,BasePrice=@From,PeakPrice=@From,PeakStartHour=0,PeakEndHour=0,IsActive=1,Revision=Revision+1 WHERE CourtId=@Cid;
   DELETE dbo.CourtPrices WHERE CourtId=@Cid;
   INSERT dbo.CourtPrices(CourtId,Minutes,Price) SELECT @Cid,Minutes,Price FROM @Prices WHERE Idx=@Idx;
   INSERT dbo.VenueSubtypes(VenueId,SubtypeId) SELECT @Venue,@Sub WHERE NOT EXISTS(SELECT 1 FROM dbo.VenueSubtypes WHERE VenueId=@Venue AND SubtypeId=@Sub);
   SET @Idx=(SELECT MIN(Idx) FROM @Courts WHERE Idx>@Idx);
  END;
  COMMIT;
  SELECT @ClubId AS ClubId;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO

-- Venues the user owns, with their courts, prices and what is owed to GameOn.
CREATE OR ALTER PROCEDURE dbo.ListMyVenues @UserId int AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @Mine TABLE(ClubId int PRIMARY KEY);
 INSERT @Mine SELECT s.ClubId FROM dbo.ClubStaff s JOIN dbo.Clubs c ON c.ClubId=s.ClubId WHERE s.UserId=@UserId AND s.Role='Owner' AND c.IsActive=1;
 SELECT c.ClubId,c.Name,c.CommissionPct,c.IsSelfListed,v.Area,v.Address,v.Latitude,v.Longitude,v.ContactPhoneNumber AS Phone,
  COALESCE((SELECT MIN(OpenHour) FROM dbo.Courts k WHERE k.ClubId=c.ClubId AND k.IsActive=1),8) AS OpenHour,
  COALESCE((SELECT MAX(CloseHour) FROM dbo.Courts k WHERE k.ClubId=c.ClubId AND k.IsActive=1),23) AS CloseHour,
  (SELECT COUNT(*) FROM dbo.CourtBookings b JOIN dbo.Courts k ON k.CourtId=b.CourtId WHERE k.ClubId=c.ClubId AND b.Source='Player' AND b.Status IN('Confirmed','Completed') AND b.EndsAt<=SYSUTCDATETIME()) AS PlayedBookings,
  (SELECT COUNT(*) FROM dbo.CourtBookings b JOIN dbo.Courts k ON k.CourtId=b.CourtId WHERE k.ClubId=c.ClubId AND b.Status IN('Pending','Confirmed') AND b.StartsAt>SYSUTCDATETIME()) AS UpcomingBookings,
  COALESCE((SELECT SUM(b.Price) FROM dbo.CourtBookings b JOIN dbo.Courts k ON k.CourtId=b.CourtId WHERE k.ClubId=c.ClubId AND b.Source='Player' AND b.Status IN('Confirmed','Completed') AND b.EndsAt<=SYSUTCDATETIME()),0) AS Revenue,
  COALESCE((SELECT SUM(b.PlatformFee) FROM dbo.CourtBookings b JOIN dbo.Courts k ON k.CourtId=b.CourtId WHERE k.ClubId=c.ClubId AND b.Source='Player' AND b.Status IN('Confirmed','Completed') AND b.EndsAt<=SYSUTCDATETIME()),0) AS CommissionOwed
 FROM dbo.Clubs c JOIN dbo.Venues v ON v.VenueId=c.VenueId JOIN @Mine m ON m.ClubId=c.ClubId ORDER BY c.Name;
 SELECT k.CourtId,k.ClubId,k.Name,k.SubtypeId,s.Name AS Sport,k.BasePrice,k.SlotMinutes FROM dbo.Courts k JOIN @Mine m ON m.ClubId=k.ClubId JOIN dbo.Subtypes s ON s.SubtypeId=k.SubtypeId WHERE k.IsActive=1 ORDER BY k.ClubId,k.CourtId;
 SELECT p.CourtId,p.Minutes,p.Price FROM dbo.CourtPrices p JOIN dbo.Courts k ON k.CourtId=p.CourtId JOIN @Mine m ON m.ClubId=k.ClubId WHERE k.IsActive=1 ORDER BY p.CourtId,p.Minutes;
END;
GO

GRANT EXECUTE ON dbo.ActivatePremium TO gameon_executor;
GRANT EXECUTE ON dbo.CancelPremium TO gameon_executor;
GRANT EXECUTE ON dbo.GetCourtPrices TO gameon_executor;
GRANT EXECUTE ON dbo.SaveMyVenue TO gameon_executor;
GRANT EXECUTE ON dbo.ListMyVenues TO gameon_executor;
GO
SELECT 'Migration 37 completed successfully' AS Result;
GO
