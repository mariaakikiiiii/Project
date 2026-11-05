-- Existing databases: BACK UP, install version 7, then execute this WHOLE file once.
-- SSMS: Query > SQLCMD Mode. sqlcmd: -b. Never execute a selected fragment.
:ON ERROR EXIT
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=7)
 THROW 50002,'Install platform upgrade 7 first.',1;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=9)
 THROW 50002,'Category/event upgrade 9 is already installed.',1;
BEGIN TRANSACTION;
CREATE TABLE dbo.Categories(
 CategoryId int IDENTITY CONSTRAINT PK_Categories PRIMARY KEY,
 Name nvarchar(60) NOT NULL CONSTRAINT UQ_Categories_Name UNIQUE,
 Slug varchar(24) NOT NULL CONSTRAINT UQ_Categories_Slug UNIQUE,
 SortOrder smallint NOT NULL
);
INSERT dbo.Categories(Name,Slug,SortOrder) VALUES(N'Sports','sports',1),(N'Entertainment Activities','activities',2);
-- Rename the real storage, retaining existing primary keys and FK object references.
EXEC sys.sp_rename N'dbo.Sports',N'Subtypes';
EXEC sys.sp_rename N'dbo.Subtypes.SportId',N'SubtypeId',N'COLUMN';
EXEC sys.sp_rename N'dbo.Games',N'GamesAndEvents';
EXEC sys.sp_rename N'dbo.GamesAndEvents.GameId',N'EventId',N'COLUMN';
EXEC sys.sp_rename N'dbo.GamesAndEvents.SportId',N'SubtypeId',N'COLUMN';
ALTER TABLE dbo.Subtypes ADD CategoryId int NULL,Slug varchar(80) NULL,
 SortOrder smallint NOT NULL CONSTRAINT DF_Subtypes_Order DEFAULT 100;
ALTER TABLE dbo.Participations ADD PaymentMethod varchar(12) NOT NULL CONSTRAINT DF_Participations_Payment DEFAULT 'Cash'
 CONSTRAINT CK_Participations_Payment CHECK(PaymentMethod IN('Cash','Whish'));
ALTER TABLE dbo.Waitlists ADD PaymentMethod varchar(12) NOT NULL CONSTRAINT DF_Waitlists_Payment DEFAULT 'Cash'
 CONSTRAINT CK_Waitlists_Payment CHECK(PaymentMethod IN('Cash','Whish'));
GO
DECLARE @Sports int=(SELECT CategoryId FROM dbo.Categories WHERE Slug='sports');
UPDATE dbo.Subtypes SET CategoryId=@Sports,Slug=CASE Name WHEN N'Football' THEN 'football' WHEN N'Basketball' THEN 'basketball' WHEN N'Padel' THEN 'padel' ELSE 'legacy-'+CONVERT(varchar(12),SubtypeId) END;
DECLARE @Seed TABLE(CategorySlug varchar(24),Slug varchar(80),Name nvarchar(60),SortOrder smallint);
INSERT @Seed VALUES
 ('sports','football',N'Football (Soccer)',1),('sports','basketball',N'Basketball',2),
 ('sports','padel',N'Padel',3),('sports','tennis',N'Tennis',4),('sports','volleyball',N'Volleyball',5),
 ('sports','badminton',N'Badminton',6),('sports','table-tennis',N'Table Tennis (Ping Pong)',7),
 ('sports','squash',N'Squash',8),('sports','swimming',N'Swimming',9),
 ('activities','paintball',N'Paintball',1),('activities','laser-tag',N'Laser Tag',2),
 ('activities','icombat',N'iCombat / Tactical Laser Tag',3),('activities','escape-rooms',N'Escape Rooms',4),
 ('activities','go-karting',N'Go-Karting',5),('activities','bowling',N'Bowling',6),
 ('activities','archery-tag',N'Archery Tag',7),('activities','airsoft',N'Airsoft',8);
-- Match preserved legacy ids by slug or exact name; no duplicate physical catalog.
UPDATE t SET Name=s.Name,CategoryId=c.CategoryId,Slug=s.Slug,SortOrder=s.SortOrder
 FROM dbo.Subtypes t JOIN @Seed s ON t.Slug=s.Slug OR t.Name=s.Name
 JOIN dbo.Categories c ON c.Slug=s.CategorySlug;
INSERT dbo.Subtypes(Name,CategoryId,Slug,SortOrder)
 SELECT s.Name,c.CategoryId,s.Slug,s.SortOrder FROM @Seed s JOIN dbo.Categories c ON c.Slug=s.CategorySlug
 WHERE NOT EXISTS(SELECT 1 FROM dbo.Subtypes t WHERE t.Slug=s.Slug);
ALTER TABLE dbo.Subtypes ALTER COLUMN CategoryId int NOT NULL;
ALTER TABLE dbo.Subtypes ALTER COLUMN Slug varchar(80) NOT NULL;
ALTER TABLE dbo.Subtypes ADD CONSTRAINT FK_Subtypes_Category FOREIGN KEY(CategoryId) REFERENCES dbo.Categories(CategoryId),
 CONSTRAINT UQ_Subtypes_Slug UNIQUE(Slug);
CREATE INDEX IX_Subtypes_Category ON dbo.Subtypes(CategoryId,SortOrder) INCLUDE(Name,Slug);
CREATE INDEX IX_Events_Subtype_Start ON dbo.GamesAndEvents(SubtypeId,StartsAt,EventId) INCLUDE(VenueId,Capacity,GameStatus);
CREATE INDEX IX_Events_Host_Time ON dbo.GamesAndEvents(HostUserId,StartsAt DESC,EventId DESC) INCLUDE(GameStatus);
CREATE TABLE dbo.UserActivityLogs(
 LogId bigint IDENTITY CONSTRAINT PK_UserActivityLogs PRIMARY KEY CLUSTERED,
 UserId int NULL CONSTRAINT FK_UserActivity_User REFERENCES dbo.Users(UserId),
 SubtypeId int NULL CONSTRAINT FK_UserActivity_Subtype REFERENCES dbo.Subtypes(SubtypeId),
 EventId int NULL CONSTRAINT FK_UserActivity_Event REFERENCES dbo.GamesAndEvents(EventId),
 Action varchar(24) NOT NULL CONSTRAINT CK_UserActivity_Action CHECK(Action IN('DiscoverySearch','EventViewed','FilterApplied','JoinAttempt','PaymentOptionsViewed')),
 Area nvarchar(80) NULL,
 OccurredAt datetime2(3) NOT NULL CONSTRAINT DF_UserActivity_Time DEFAULT SYSUTCDATETIME(),
 IsSynthetic bit NOT NULL CONSTRAINT DF_UserActivity_Synthetic DEFAULT 0
);
CREATE INDEX IX_UserActivity_User_Time ON dbo.UserActivityLogs(UserId,OccurredAt DESC,LogId DESC) INCLUDE(SubtypeId,Action,Area);
CREATE INDEX IX_UserActivity_Subtype_Time ON dbo.UserActivityLogs(SubtypeId,OccurredAt DESC,LogId DESC) INCLUDE(UserId,Action,Area);
CREATE INDEX IX_UserActivity_Time ON dbo.UserActivityLogs(OccurredAt) INCLUDE(Action,SubtypeId);
GO
-- These single-table, updateable views preserve the first release's procedure/API
-- names without duplicating storage. All locking resolves to GamesAndEvents.
CREATE VIEW dbo.Sports AS SELECT SubtypeId AS SportId,Name FROM dbo.Subtypes;
GO
CREATE VIEW dbo.Games AS
SELECT EventId AS GameId,HostUserId,SubtypeId AS SportId,VenueId,StartsAt,Capacity,CreatedAt,
 Description,GameStatus,CostPerPlayer,Currency,SponsoredSlots,Revision FROM dbo.GamesAndEvents;
GO
CREATE OR ALTER VIEW dbo.GameSummary AS
SELECT g.EventId AS GameId,g.HostUserId,g.SubtypeId AS SportId,g.SubtypeId,g.VenueId,g.StartsAt,g.Capacity,
 g.Description,g.GameStatus,g.CostPerPlayer,g.Currency,g.SponsoredSlots,g.Revision,
 s.Name AS Sport,s.Slug AS SubtypeSlug,c.CategoryId,c.Name AS CategoryName,c.Slug AS CategorySlug,
 v.Name AS Venue,v.Area,v.Address,
 (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.EventId) AS PlayerCount,
 (SELECT COUNT(*) FROM dbo.SponsoredSeats f WHERE f.GameId=g.EventId) AS SponsoredClaimed
FROM dbo.GamesAndEvents g JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId
JOIN dbo.Categories c ON c.CategoryId=s.CategoryId JOIN dbo.Venues v ON v.VenueId=g.VenueId;
GO
CREATE OR ALTER PROCEDURE dbo.GetLookups AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.SubtypeId AS SportId,s.SubtypeId,s.Name,s.Slug,c.CategoryId,c.Name AS CategoryName,c.Slug AS CategorySlug
 FROM dbo.Subtypes s JOIN dbo.Categories c ON c.CategoryId=s.CategoryId ORDER BY c.SortOrder,s.SortOrder,s.Name;
 SELECT VenueId,Name,Area,Address FROM dbo.Venues ORDER BY Area,Name;
 SELECT CategoryId,Name,Slug FROM dbo.Categories ORDER BY SortOrder;
END;
GO
CREATE OR ALTER PROCEDURE dbo.DiscoverGames
 @SportId int=NULL,@Date date=NULL,@Area nvarchar(80)=NULL,@UserId int=NULL,@FreeOnly bit=0,
 @CategorySlug varchar(24)=NULL,@OpenOnly bit=0
AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(60) s.*,
 CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.UserSportPreferences p WHERE p.UserId=@UserId AND p.SportId=s.SportId) THEN 1 ELSE 0 END AS bit) AS MatchesSport,
 CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.UserPreferences p WHERE p.UserId=@UserId AND p.Area=s.Area) THEN 1 ELSE 0 END AS bit) AS MatchesArea
 FROM dbo.GameSummary s
 WHERE GameStatus='Open' AND StartsAt>SYSUTCDATETIME()
 AND (@CategorySlug IS NULL OR CategorySlug=@CategorySlug)
 AND (@SportId IS NULL OR SportId=@SportId)
 AND (@Date IS NULL OR (StartsAt>=CONVERT(datetime2,@Date) AND StartsAt<DATEADD(day,1,CONVERT(datetime2,@Date))))
 AND (@Area IS NULL OR Area=@Area)
 AND (@OpenOnly=0 OR PlayerCount<Capacity)
 AND (@FreeOnly=0 OR CostPerPlayer=0 OR (SponsoredSlots>SponsoredClaimed AND PlayerCount<Capacity))
 ORDER BY MatchesSport DESC,MatchesArea DESC,StartsAt,GameId OPTION(RECOMPILE);
 INSERT dbo.UserActivityLogs(UserId,SubtypeId,Action,Area) VALUES(@UserId,@SportId,'DiscoverySearch',@Area);
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetGame @GameId int,@UserId int=NULL AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.*,u.DisplayName AS HostName FROM dbo.GameSummary s JOIN dbo.Users u ON u.UserId=s.HostUserId WHERE GameId=@GameId;
 SELECT p.UserId,u.DisplayName,p.JoinedAt,CAST(CASE WHEN f.UserId IS NULL THEN 0 ELSE 1 END AS bit) AS IsSponsored
 FROM dbo.Participations p JOIN dbo.Users u ON u.UserId=p.UserId
 LEFT JOIN dbo.SponsoredSeats f ON f.GameId=p.GameId AND f.UserId=p.UserId
 WHERE p.GameId=@GameId ORDER BY p.JoinedAt,p.UserId;
 SELECT CAST('Joined' AS varchar(20)) AS Status,p.PaymentMethod,CAST(NULL AS bigint) AS QueuePosition
 FROM dbo.Participations p WHERE p.GameId=@GameId AND p.UserId=@UserId
 UNION ALL SELECT 'Waitlisted',w.PaymentMethod,dbo.WaitlistPosition(w.GameId,w.UserId)
 FROM dbo.Waitlists w WHERE w.GameId=@GameId AND w.UserId=@UserId;
 IF EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@GameId)
  INSERT dbo.UserActivityLogs(UserId,EventId,SubtypeId,Action) SELECT @UserId,EventId,SubtypeId,'EventViewed' FROM dbo.GamesAndEvents WHERE EventId=@GameId;
END;
GO
-- Required GIN401 entry point: every join path takes this exact same row lock.
CREATE OR ALTER PROCEDURE dbo.sp_JoinGameOrActivity
 @GameId int,@UserId int,@ClaimSponsored bit=0,@PaymentMethod varchar(12)='Cash'
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Capacity int,@Start datetime2(3),@GameStatus varchar(12),@Host int,@Slots int,@Cost decimal(10,2),@Status varchar(20);
  SELECT @Capacity=Capacity,@Start=StartsAt,@GameStatus=GameStatus,@Host=HostUserId,@Slots=SponsoredSlots,@Cost=CostPerPlayer
   FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Capacity IS NULL THROW 50001,'Event not found.',1;
  IF @GameStatus<>'Open' OR @Start<=SYSUTCDATETIME() THROW 50002,'Event is no longer open.',1;
  IF @PaymentMethod IS NULL OR @PaymentMethod NOT IN('Cash','Whish') THROW 50002,'Unknown payment method.',1;
  -- Whish is a provider integration boundary. Never pretend that selecting it paid.
  IF @PaymentMethod='Whish' AND @Cost>0 AND @ClaimSponsored=0
   THROW 50005,'Whish checkout requires the verified merchant integration. Choose cash at the venue for now.',1;
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
    SET @Status='Joined';
   END
   ELSE
   BEGIN
    INSERT dbo.Waitlists(GameId,UserId,PaymentMethod) VALUES(@GameId,@UserId,@PaymentMethod);
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
  SELECT @Status AS Status;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.JoinGame @GameId int,@UserId int,@ClaimSponsored bit=0 AS
BEGIN
 SET NOCOUNT ON;
 EXEC dbo.sp_JoinGameOrActivity @GameId,@UserId,@ClaimSponsored,'Cash';
END;
GO
CREATE OR ALTER PROCEDURE dbo.CancelParticipation @GameId int,@UserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int,@Start datetime2(3),@Status varchar(12),@NextUser int,@Waitlist bigint,@Method varchar(12);
  SELECT @Id=EventId,@Start=StartsAt,@Status=GameStatus FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Id IS NULL THROW 50001,'Event not found.',1;
  IF @Start<=SYSUTCDATETIME() OR @Status<>'Open' THROW 50002,'Event is no longer open.',1;
  DELETE dbo.Participations WHERE GameId=@GameId AND UserId=@UserId;
  IF @@ROWCOUNT=1
  BEGIN
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Cancelled');
   SELECT TOP(1) @NextUser=UserId,@Waitlist=WaitlistId,@Method=PaymentMethod FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
   IF @NextUser IS NOT NULL
   BEGIN
    DELETE dbo.Waitlists WHERE WaitlistId=@Waitlist;
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@NextUser,@Method);
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
  DECLARE @Promoted TABLE(UserId int PRIMARY KEY,WaitlistId bigint,PaymentMethod varchar(12));
  INSERT @Promoted(UserId,WaitlistId,PaymentMethod)
   SELECT TOP(@Open) UserId,WaitlistId,PaymentMethod FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
  DELETE w FROM dbo.Waitlists w JOIN @Promoted p ON p.WaitlistId=w.WaitlistId;
  INSERT dbo.Participations(GameId,UserId,PaymentMethod) SELECT @GameId,UserId,PaymentMethod FROM @Promoted;
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
CREATE OR ALTER PROCEDURE dbo.MyGames @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.*,CAST(CASE WHEN p.UserId IS NOT NULL THEN 'Joined' WHEN w.UserId IS NOT NULL THEN 'Waitlisted' ELSE 'Hosting' END AS varchar(20)) AS Status,
 CASE WHEN w.UserId IS NOT NULL THEN dbo.WaitlistPosition(w.GameId,w.UserId) END AS QueuePosition,
 CAST(CASE WHEN f.UserId IS NOT NULL THEN 1 ELSE 0 END AS bit) AS IsSponsored,
 COALESCE(p.PaymentMethod,w.PaymentMethod) AS PaymentMethod
 FROM dbo.GameSummary s LEFT JOIN dbo.Participations p ON p.GameId=s.GameId AND p.UserId=@UserId
 LEFT JOIN dbo.Waitlists w ON w.GameId=s.GameId AND w.UserId=@UserId
 LEFT JOIN dbo.SponsoredSeats f ON f.GameId=s.GameId AND f.UserId=@UserId
 WHERE s.HostUserId=@UserId OR p.UserId IS NOT NULL OR w.UserId IS NOT NULL ORDER BY StartsAt DESC;
END;
GO
GRANT EXECUTE ON dbo.sp_JoinGameOrActivity TO gameon_executor;
INSERT dbo.PlatformMigrations(Version) VALUES(9);
COMMIT;
GO
