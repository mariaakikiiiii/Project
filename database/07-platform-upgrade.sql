-- SSMS: enable Query > SQLCMD Mode before executing, or use sqlcmd -b.
:ON ERROR EXIT
-- EXISTING INSTALLATIONS: backup GameOn, then run this file once as migration owner.
-- NEW INSTALLATIONS: run 01-04 first, then this file. Never rerun the original schema.
-- Version marker is written only after all DDL/procedures/grants succeed.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF OBJECT_ID('dbo.PlatformMigrations') IS NULL
 CREATE TABLE dbo.PlatformMigrations(Version int PRIMARY KEY, AppliedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=7)
 THROW 50002,'Upgrade 7 is already installed. No changes made.',1;
BEGIN TRANSACTION;
ALTER TABLE dbo.Users ADD Bio nvarchar(400) NOT NULL CONSTRAINT DF_Users_Bio DEFAULT N'',
 SecurityVersion int NOT NULL CONSTRAINT DF_Users_SecurityVersion DEFAULT 1;
ALTER TABLE dbo.Games ADD Description nvarchar(1000) NOT NULL CONSTRAINT DF_Games_Description DEFAULT N'',
 GameStatus varchar(12) NOT NULL CONSTRAINT DF_Games_Status DEFAULT 'Open' CONSTRAINT CK_Games_Status CHECK(GameStatus IN('Open','Cancelled')),
 CostPerPlayer decimal(10,2) NOT NULL CONSTRAINT DF_Games_Cost DEFAULT 0 CONSTRAINT CK_Games_Cost CHECK(CostPerPlayer>=0),
 Currency char(3) NOT NULL CONSTRAINT DF_Games_Currency DEFAULT 'USD' CONSTRAINT CK_Games_Currency CHECK(Currency IN('USD','LBP')),
 SponsoredSlots smallint NOT NULL CONSTRAINT DF_Games_Sponsored DEFAULT 0,
 Revision int NOT NULL CONSTRAINT DF_Games_Revision DEFAULT 1,
 CONSTRAINT CK_Games_Sponsored CHECK(SponsoredSlots>=0 AND SponsoredSlots<Capacity);
CREATE TABLE dbo.UserPreferences(
 UserId int PRIMARY KEY REFERENCES dbo.Users(UserId),
 Area nvarchar(80) NULL,
 SkillLevel varchar(16) NOT NULL DEFAULT 'All levels' CHECK(SkillLevel IN('All levels','Beginner','Intermediate','Advanced'))
);
CREATE TABLE dbo.UserSportPreferences(
 UserId int NOT NULL REFERENCES dbo.Users(UserId),
 SportId int NOT NULL REFERENCES dbo.Sports(SportId),
 PRIMARY KEY(UserId,SportId)
);
CREATE TABLE dbo.SponsoredSeats(
 GameId int NOT NULL, UserId int NOT NULL,
 ClaimedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
 PRIMARY KEY(GameId,UserId),
 CONSTRAINT FK_Sponsored_Participation FOREIGN KEY(GameId,UserId)
 REFERENCES dbo.Participations(GameId,UserId) ON DELETE CASCADE
);
CREATE TABLE dbo.Notifications(
 NotificationId bigint IDENTITY PRIMARY KEY,
 UserId int NOT NULL REFERENCES dbo.Users(UserId),
 GameId int NULL REFERENCES dbo.Games(GameId),
 Title nvarchar(120) NOT NULL, Body nvarchar(400) NOT NULL,
 CreatedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
 ReadAt datetime2(3) NULL
);
CREATE INDEX IX_Notifications_User_Page ON dbo.Notifications(UserId,NotificationId DESC)
 INCLUDE(GameId,Title,Body,CreatedAt,ReadAt);
CREATE INDEX IX_Notifications_Unread ON dbo.Notifications(UserId,NotificationId DESC) WHERE ReadAt IS NULL;
CREATE TABLE dbo.PasswordResetTokens(
 TokenHash binary(32) PRIMARY KEY,
 UserId int NOT NULL REFERENCES dbo.Users(UserId),
 ExpiresAt datetime2(3) NOT NULL,
 UsedAt datetime2(3) NULL
);
CREATE INDEX IX_Reset_User ON dbo.PasswordResetTokens(UserId) INCLUDE(ExpiresAt,UsedAt);
CREATE TABLE dbo.ResetEmailOutbox(
 OutboxId bigint IDENTITY PRIMARY KEY,
 Recipient nvarchar(254) NOT NULL,
 ProtectedToken nvarchar(2000) NOT NULL,
 ExpiresAt datetime2(3) NOT NULL,
 NextAttemptAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
 Attempts int NOT NULL DEFAULT 0,
 Lease uniqueidentifier NULL,
 SentAt datetime2(3) NULL
);
CREATE INDEX IX_ResetEmail_Pending ON dbo.ResetEmailOutbox(NextAttemptAt,OutboxId) WHERE SentAt IS NULL;
ALTER TABLE dbo.GameActivityLogs DROP CONSTRAINT CK_Activity_Type;
ALTER TABLE dbo.GameActivityLogs ADD CONSTRAINT CK_Activity_Type CHECK
 (ActivityType IN('Created','Joined','Waitlisted','Cancelled','Promoted','LeftWaitlist','Edited','GameCancelled','Sponsored'));
GO
CREATE OR ALTER VIEW dbo.GameSummary AS
SELECT g.GameId,g.HostUserId,g.SportId,g.VenueId,g.StartsAt,g.Capacity,g.Description,g.GameStatus,
 g.CostPerPlayer,g.Currency,g.SponsoredSlots,g.Revision,s.Name AS Sport,v.Name AS Venue,v.Area,v.Address,
 (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.GameId) AS PlayerCount,
 (SELECT COUNT(*) FROM dbo.SponsoredSeats f WHERE f.GameId=g.GameId) AS SponsoredClaimed
FROM dbo.Games g JOIN dbo.Sports s ON s.SportId=g.SportId JOIN dbo.Venues v ON v.VenueId=g.VenueId;
GO
CREATE OR ALTER PROCEDURE dbo.GetProfile @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT u.UserId,u.Email,u.DisplayName,u.Bio,p.Area,COALESCE(p.SkillLevel,'All levels') AS SkillLevel
 FROM dbo.Users u LEFT JOIN dbo.UserPreferences p ON p.UserId=u.UserId WHERE u.UserId=@UserId;
 SELECT SportId FROM dbo.UserSportPreferences WHERE UserId=@UserId ORDER BY SportId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.SaveProfile
 @UserId int,@DisplayName nvarchar(80),@Bio nvarchar(400),@Area nvarchar(80),@SkillLevel varchar(16),@SportsJson nvarchar(2000)
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int;
  SELECT @Id=UserId FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId;
  IF @Id IS NULL THROW 50001,'User not found.',1;
  IF LEN(TRIM(@DisplayName))=0 OR @SkillLevel NOT IN('All levels','Beginner','Intermediate','Advanced')
   THROW 50002,'Invalid profile.',1;
  IF ISJSON(@SportsJson)<>1 OR LEFT(LTRIM(@SportsJson),1)<>'[' THROW 50002,'Invalid sports.',1;
  IF EXISTS(SELECT 1 FROM OPENJSON(@SportsJson) j LEFT JOIN dbo.Sports s ON s.SportId=TRY_CONVERT(int,j.value)
    WHERE j.type<>2 OR s.SportId IS NULL) THROW 50002,'Unknown sport.',1;
  UPDATE dbo.Users SET DisplayName=TRIM(@DisplayName),Bio=@Bio WHERE UserId=@UserId;
  UPDATE dbo.UserPreferences SET Area=NULLIF(TRIM(@Area),N''),SkillLevel=@SkillLevel WHERE UserId=@UserId;
  IF @@ROWCOUNT=0 INSERT dbo.UserPreferences(UserId,Area,SkillLevel) VALUES(@UserId,NULLIF(TRIM(@Area),N''),@SkillLevel);
  DELETE dbo.UserSportPreferences WHERE UserId=@UserId;
  INSERT dbo.UserSportPreferences(UserId,SportId) SELECT DISTINCT @UserId,CONVERT(int,value) FROM OPENJSON(@SportsJson);
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.DiscoverGames
 @SportId int=NULL,@Date date=NULL,@Area nvarchar(80)=NULL,@UserId int=NULL,@FreeOnly bit=0
AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(60) s.*,
 CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.UserSportPreferences p WHERE p.UserId=@UserId AND p.SportId=s.SportId) THEN 1 ELSE 0 END AS bit) AS MatchesSport,
 CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.UserPreferences p WHERE p.UserId=@UserId AND p.Area=s.Area) THEN 1 ELSE 0 END AS bit) AS MatchesArea
 FROM dbo.GameSummary s
 WHERE GameStatus='Open' AND StartsAt>SYSUTCDATETIME()
 AND (@SportId IS NULL OR SportId=@SportId)
 AND (@Date IS NULL OR (StartsAt>=CONVERT(datetime2,@Date) AND StartsAt<DATEADD(day,1,CONVERT(datetime2,@Date))))
 AND (@Area IS NULL OR Area=@Area)
 AND (@FreeOnly=0 OR CostPerPlayer=0 OR (SponsoredSlots>SponsoredClaimed AND PlayerCount<Capacity))
 ORDER BY MatchesSport DESC,MatchesArea DESC,StartsAt,GameId OPTION(RECOMPILE);
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetGame @GameId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.*,u.DisplayName AS HostName FROM dbo.GameSummary s JOIN dbo.Users u ON u.UserId=s.HostUserId WHERE GameId=@GameId;
 SELECT p.UserId,u.DisplayName,p.JoinedAt,CAST(CASE WHEN f.UserId IS NULL THEN 0 ELSE 1 END AS bit) AS IsSponsored
 FROM dbo.Participations p JOIN dbo.Users u ON u.UserId=p.UserId
 LEFT JOIN dbo.SponsoredSeats f ON f.GameId=p.GameId AND f.UserId=p.UserId
 WHERE p.GameId=@GameId ORDER BY p.JoinedAt,p.UserId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.MyGames @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.*,CAST(CASE WHEN p.UserId IS NOT NULL THEN 'Joined' WHEN w.UserId IS NOT NULL THEN 'Waitlisted' ELSE 'Hosting' END AS varchar(20)) AS Status,
 CASE WHEN w.UserId IS NOT NULL THEN dbo.WaitlistPosition(w.GameId,w.UserId) END AS QueuePosition,
 CAST(CASE WHEN f.UserId IS NOT NULL THEN 1 ELSE 0 END AS bit) AS IsSponsored
 FROM dbo.GameSummary s LEFT JOIN dbo.Participations p ON p.GameId=s.GameId AND p.UserId=@UserId
 LEFT JOIN dbo.Waitlists w ON w.GameId=s.GameId AND w.UserId=@UserId
 LEFT JOIN dbo.SponsoredSeats f ON f.GameId=s.GameId AND f.UserId=@UserId
 WHERE s.HostUserId=@UserId OR p.UserId IS NOT NULL OR w.UserId IS NOT NULL ORDER BY StartsAt DESC;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CreateGame
 @HostUserId int,@SportId int,@VenueId int,@StartsAt datetime2(3),@Capacity smallint,
 @Description nvarchar(1000)=N'',@CostPerPlayer decimal(10,2)=0,@Currency char(3)='USD',@SponsoredSlots smallint=0
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  IF @StartsAt<=SYSUTCDATETIME() OR @Capacity NOT BETWEEN 2 AND 100 OR @SponsoredSlots<0 OR @SponsoredSlots>=@Capacity
   OR @CostPerPlayer<0 OR @Currency NOT IN('USD','LBP') THROW 50002,'Invalid game details.',1;
  INSERT dbo.Games(HostUserId,SportId,VenueId,StartsAt,Capacity,Description,CostPerPlayer,Currency,SponsoredSlots)
  VALUES(@HostUserId,@SportId,@VenueId,@StartsAt,@Capacity,@Description,@CostPerPlayer,@Currency,@SponsoredSlots);
  DECLARE @GameId int=CONVERT(int,SCOPE_IDENTITY());
  INSERT dbo.Participations(GameId,UserId) VALUES(@GameId,@HostUserId);
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,'Created');
  COMMIT;
  SELECT @GameId AS GameId;
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
  DECLARE @Promoted TABLE(UserId int PRIMARY KEY,WaitlistId bigint);
  INSERT @Promoted(UserId,WaitlistId)
   SELECT TOP(@Open) UserId,WaitlistId FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
  DELETE w FROM dbo.Waitlists w JOIN @Promoted p ON p.WaitlistId=w.WaitlistId;
  INSERT dbo.Participations(GameId,UserId) SELECT @GameId,UserId FROM @Promoted;
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
CREATE OR ALTER PROCEDURE dbo.JoinGame @GameId int,@UserId int,@ClaimSponsored bit=0 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Capacity int,@Start datetime2(3),@GameStatus varchar(12),@Host int,@Slots int,@Status varchar(20);
  SELECT @Capacity=Capacity,@Start=StartsAt,@GameStatus=GameStatus,@Host=HostUserId,@Slots=SponsoredSlots
   FROM dbo.Games WITH(UPDLOCK,HOLDLOCK) WHERE GameId=@GameId;
  IF @Capacity IS NULL THROW 50001,'Game not found.',1;
  IF @GameStatus<>'Open' OR @Start<=SYSUTCDATETIME() THROW 50002,'Game is no longer open.',1;
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
    INSERT dbo.Participations(GameId,UserId) VALUES(@GameId,@UserId);
    IF @ClaimSponsored=1 INSERT dbo.SponsoredSeats(GameId,UserId) VALUES(@GameId,@UserId);
    SET @Status='Joined';
   END
   ELSE
   BEGIN
    INSERT dbo.Waitlists(GameId,UserId) VALUES(@GameId,@UserId);
    SET @Status='Waitlisted';
   END;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,@Status);
   IF @ClaimSponsored=1 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Sponsored');
   INSERT dbo.Notifications(UserId,GameId,Title,Body) VALUES(@UserId,@GameId,
    CASE WHEN @Status='Joined' THEN N'You are in!' ELSE N'You are on the waitlist' END,
    CASE WHEN @ClaimSponsored=1 THEN N'The host has agreed to cover your venue fee. No money is transferred in the app.'
     WHEN @Status='Joined' THEN N'Your place is confirmed. Check the venue and time before heading out.'
     ELSE N'We will notify you here if a place opens.' END);
   IF @Host<>@UserId INSERT dbo.Notifications(UserId,GameId,Title,Body)
    VALUES(@Host,@GameId,N'Your game has a new player',N'A player joined your game or its waitlist.');
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
CREATE OR ALTER PROCEDURE dbo.CancelParticipation @GameId int,@UserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int,@Start datetime2(3),@Status varchar(12),@NextUser int,@Waitlist bigint;
  SELECT @Id=GameId,@Start=StartsAt,@Status=GameStatus FROM dbo.Games WITH(UPDLOCK,HOLDLOCK) WHERE GameId=@GameId;
  IF @Id IS NULL THROW 50001,'Game not found.',1;
  IF @Start<=SYSUTCDATETIME() OR @Status<>'Open' THROW 50002,'Game is no longer open.',1;
  DELETE dbo.Participations WHERE GameId=@GameId AND UserId=@UserId; -- cascades sponsored claim
  IF @@ROWCOUNT=1
  BEGIN
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Cancelled');
   SELECT TOP(1) @NextUser=UserId,@Waitlist=WaitlistId FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
   IF @NextUser IS NOT NULL
   BEGIN
    DELETE dbo.Waitlists WHERE WaitlistId=@Waitlist;
    INSERT dbo.Participations(GameId,UserId) VALUES(@GameId,@NextUser);
    INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@NextUser,'Promoted');
    INSERT dbo.Notifications(UserId,GameId,Title,Body)
     VALUES(@NextUser,@GameId,N'A place opened. You are in!',N'You moved from the waitlist to the roster. Your original standard fee applies; sponsorship is not automatic.');
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
CREATE OR ALTER PROCEDURE dbo.GetNotifications @UserId int,@BeforeId bigint=NULL AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(30) NotificationId,GameId,Title,Body,CreatedAt,ReadAt FROM dbo.Notifications
 WHERE UserId=@UserId AND (@BeforeId IS NULL OR NotificationId<@BeforeId) ORDER BY NotificationId DESC;
 SELECT COUNT(*) AS UnreadCount FROM dbo.Notifications WHERE UserId=@UserId AND ReadAt IS NULL;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ReadNotification @UserId int,@NotificationId bigint AS
BEGIN
 SET NOCOUNT ON;
 UPDATE dbo.Notifications SET ReadAt=COALESCE(ReadAt,SYSUTCDATETIME()) WHERE UserId=@UserId AND NotificationId=@NotificationId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.FindUserForLogin @Email nvarchar(254) AS
BEGIN
 SET NOCOUNT ON;
 SELECT UserId,DisplayName,PasswordHash,SecurityVersion FROM dbo.Users WHERE Email=@Email;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CheckSession @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT UserId,SecurityVersion FROM dbo.Users WHERE UserId=@UserId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.RequestPasswordReset @Email nvarchar(254),@TokenHash binary(32),@ProtectedToken nvarchar(2000) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @UserId int;
  SELECT @UserId=UserId FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE Email=@Email AND PasswordHash<>N'DISABLED_FIXTURE';
  IF @UserId IS NOT NULL
  BEGIN
   DELETE dbo.PasswordResetTokens WHERE UserId=@UserId;
   DELETE dbo.ResetEmailOutbox WHERE Recipient=@Email AND SentAt IS NULL;
   INSERT dbo.PasswordResetTokens(TokenHash,UserId,ExpiresAt) VALUES(@TokenHash,@UserId,DATEADD(minute,30,SYSUTCDATETIME()));
   INSERT dbo.ResetEmailOutbox(Recipient,ProtectedToken,ExpiresAt) VALUES(@Email,@ProtectedToken,DATEADD(minute,30,SYSUTCDATETIME()));
  END;
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ResetPassword @TokenHash binary(32),@PasswordHash nvarchar(512) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @UserId int,@Id int;
  SELECT @UserId=UserId FROM dbo.PasswordResetTokens WHERE TokenHash=@TokenHash;
  IF @UserId IS NULL THROW 50002,'Reset link is invalid or expired.',1;
  SELECT @Id=UserId FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId;
  IF NOT EXISTS(SELECT 1 FROM dbo.PasswordResetTokens WHERE TokenHash=@TokenHash AND UsedAt IS NULL AND ExpiresAt>SYSUTCDATETIME())
   THROW 50002,'Reset link is invalid or expired.',1;
  UPDATE dbo.Users SET PasswordHash=@PasswordHash,SecurityVersion=SecurityVersion+1 WHERE UserId=@UserId;
  UPDATE dbo.PasswordResetTokens SET UsedAt=SYSUTCDATETIME() WHERE UserId=@UserId AND UsedAt IS NULL;
  INSERT dbo.Notifications(UserId,Title,Body) VALUES(@UserId,N'Password changed',N'Your password was reset and all previous sessions were signed out.');
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ClaimResetEmail @Lease uniqueidentifier AS
BEGIN
 SET NOCOUNT ON;
 ;WITH NextEmail AS(
  SELECT TOP(1) * FROM dbo.ResetEmailOutbox WITH(UPDLOCK,READPAST,READCOMMITTEDLOCK)
  WHERE SentAt IS NULL AND NextAttemptAt<=SYSUTCDATETIME() AND ExpiresAt>SYSUTCDATETIME() AND Attempts<5
  ORDER BY NextAttemptAt,OutboxId
 )
 UPDATE NextEmail SET Lease=@Lease,Attempts=Attempts+1,NextAttemptAt=DATEADD(minute,2,SYSUTCDATETIME())
 OUTPUT inserted.OutboxId,inserted.Recipient,inserted.ProtectedToken;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CompleteResetEmail @Id bigint,@Lease uniqueidentifier,@Sent bit AS
BEGIN
 SET NOCOUNT ON;
 UPDATE dbo.ResetEmailOutbox SET SentAt=CASE WHEN @Sent=1 THEN SYSUTCDATETIME() ELSE NULL END,
 ProtectedToken=CASE WHEN @Sent=1 THEN N'' ELSE ProtectedToken END,
 Lease=NULL,NextAttemptAt=DATEADD(minute,1,SYSUTCDATETIME()) WHERE OutboxId=@Id AND Lease=@Lease;
END;
GO
GRANT EXECUTE ON dbo.ClaimResetEmail TO gameon_executor;
GRANT EXECUTE ON dbo.CompleteResetEmail TO gameon_executor;
GRANT EXECUTE ON dbo.GetProfile TO gameon_executor;
GRANT EXECUTE ON dbo.SaveProfile TO gameon_executor;
GRANT EXECUTE ON dbo.EditGame TO gameon_executor;
GRANT EXECUTE ON dbo.CancelGame TO gameon_executor;
GRANT EXECUTE ON dbo.GetNotifications TO gameon_executor;
GRANT EXECUTE ON dbo.ReadNotification TO gameon_executor;
GRANT EXECUTE ON dbo.CheckSession TO gameon_executor;
GRANT EXECUTE ON dbo.RequestPasswordReset TO gameon_executor;
GRANT EXECUTE ON dbo.ResetPassword TO gameon_executor;
INSERT dbo.PlatformMigrations(Version) VALUES(7);
COMMIT;
GO
