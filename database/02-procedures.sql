-- Every membership mutation locks the SAME game row first. READ COMMITTED is enough:
-- UPDLOCK,HOLDLOCK serializes changes per game until commit, including with RCSI enabled.
CREATE PROCEDURE dbo.JoinGame @GameId int,@UserId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Capacity int,@StartsAt datetime2(3),@Status varchar(20);
  SELECT @Capacity=Capacity,@StartsAt=StartsAt FROM dbo.Games WITH(UPDLOCK,HOLDLOCK) WHERE GameId=@GameId;
  IF @Capacity IS NULL THROW 50001,'Game not found.',1;
  IF @StartsAt<=SYSUTCDATETIME() THROW 50002,'Game has already started.',1;
  IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId=@UserId)
   SET @Status='Joined'; -- Idempotent retries do not append duplicate logs.
  ELSE IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId)
   SET @Status='Waitlisted';
  ELSE
  BEGIN
   IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId)<@Capacity
   BEGIN
    INSERT dbo.Participations(GameId,UserId) VALUES(@GameId,@UserId);
    SET @Status='Joined';
   END
   ELSE
   BEGIN
    INSERT dbo.Waitlists(GameId,UserId) VALUES(@GameId,@UserId);
    SET @Status='Waitlisted';
   END;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,@Status);
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
CREATE PROCEDURE dbo.CancelParticipation @GameId int,@UserId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int,@StartsAt datetime2(3),@NextUser int,@NextWaitlist bigint;
  SELECT @Id=GameId,@StartsAt=StartsAt FROM dbo.Games WITH(UPDLOCK,HOLDLOCK) WHERE GameId=@GameId;
  IF @Id IS NULL THROW 50001,'Game not found.',1;
  IF @StartsAt<=SYSUTCDATETIME() THROW 50002,'Game has already started.',1;
  DELETE dbo.Participations WHERE GameId=@GameId AND UserId=@UserId;
  IF @@ROWCOUNT=1
  BEGIN
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Cancelled');
   -- Identity order under the per-game lock is stable FIFO; no READPAST skips.
   SELECT TOP(1) @NextUser=UserId,@NextWaitlist=WaitlistId
   FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
   IF @NextUser IS NOT NULL
   BEGIN
    DELETE dbo.Waitlists WHERE WaitlistId=@NextWaitlist;
    INSERT dbo.Participations(GameId,UserId) VALUES(@GameId,@NextUser);
    INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@NextUser,'Promoted');
   END;
  END
  ELSE
  BEGIN
   DELETE dbo.Waitlists WHERE GameId=@GameId AND UserId=@UserId;
   IF @@ROWCOUNT=1
    INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'LeftWaitlist');
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
CREATE PROCEDURE dbo.CreateGame
 @HostUserId int,@SportId int,@VenueId int,@StartsAt datetime2(3),@Capacity smallint
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  IF @StartsAt<=SYSUTCDATETIME() THROW 50002,'Start must be in the future.',1;
  IF @Capacity NOT BETWEEN 2 AND 100 THROW 50002,'Capacity must be between 2 and 100.',1;
  INSERT dbo.Games(HostUserId,SportId,VenueId,StartsAt,Capacity)
  VALUES(@HostUserId,@SportId,@VenueId,@StartsAt,@Capacity);
  DECLARE @GameId int=CONVERT(int,SCOPE_IDENTITY());
  -- Host counts as a player, so capacity includes the host.
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
CREATE PROCEDURE dbo.DiscoverGames @SportId int=NULL,@Date date=NULL,@Area nvarchar(80)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(100) * FROM dbo.GameSummary
 WHERE StartsAt>SYSUTCDATETIME()
 AND (@SportId IS NULL OR SportId=@SportId)
 AND (@Date IS NULL OR (StartsAt>=CONVERT(datetime2,@Date) AND StartsAt<DATEADD(day,1,CONVERT(datetime2,@Date))))
 AND (@Area IS NULL OR Area=@Area)
 ORDER BY StartsAt,GameId OPTION(RECOMPILE);
END;
GO
CREATE PROCEDURE dbo.GetGame @GameId int
AS
BEGIN
 SET NOCOUNT ON;
 SELECT * FROM dbo.GameSummary WHERE GameId=@GameId;
 SELECT p.UserId,u.DisplayName,p.JoinedAt FROM dbo.Participations p
 JOIN dbo.Users u ON u.UserId=p.UserId WHERE p.GameId=@GameId ORDER BY p.JoinedAt,p.UserId;
END;
GO
CREATE PROCEDURE dbo.MyGames @UserId int
AS
BEGIN
 SET NOCOUNT ON;
 SELECT s.*,CAST('Joined' AS varchar(20)) AS Status,CAST(NULL AS bigint) AS QueuePosition
 FROM dbo.GameSummary s JOIN dbo.Participations p ON p.GameId=s.GameId WHERE p.UserId=@UserId
 UNION ALL
 SELECT s.*,'Waitlisted',dbo.WaitlistPosition(w.GameId,w.UserId)
 FROM dbo.GameSummary s JOIN dbo.Waitlists w ON w.GameId=s.GameId WHERE w.UserId=@UserId
 ORDER BY StartsAt;
END;
GO
CREATE PROCEDURE dbo.GetLookups
AS
BEGIN
 SET NOCOUNT ON;
 SELECT SportId,Name FROM dbo.Sports ORDER BY Name;
 SELECT VenueId,Name,Area FROM dbo.Venues ORDER BY Area,Name;
END;
GO
CREATE PROCEDURE dbo.RegisterUser @Email nvarchar(254),@DisplayName nvarchar(80),@PasswordHash nvarchar(512)
AS
BEGIN
 SET NOCOUNT ON;
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(@Email,@DisplayName,@PasswordHash);
 SELECT CONVERT(int,SCOPE_IDENTITY()) AS UserId;
END;
GO
CREATE PROCEDURE dbo.FindUserForLogin @Email nvarchar(254)
AS
BEGIN
 SET NOCOUNT ON;
 SELECT UserId,DisplayName,PasswordHash FROM dbo.Users WHERE Email=@Email;
END;
GO
CREATE PROCEDURE dbo.GetGameActivity
 @GameId int,@From datetime2(3),@Until datetime2(3),
 @BeforeTime datetime2(3)=NULL,@BeforeId bigint=NULL
AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(50) ActivityId,ActorUserId,ActivityType,OccurredAt
 FROM dbo.GameActivityLogs
 WHERE GameId=@GameId AND OccurredAt>=@From AND OccurredAt<@Until
 AND (@BeforeTime IS NULL OR OccurredAt<@BeforeTime OR (OccurredAt=@BeforeTime AND ActivityId<@BeforeId))
 ORDER BY OccurredAt DESC,ActivityId DESC OPTION(RECOMPILE);
END;
GO
