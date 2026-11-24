-- GameOn migration 38: approving a join request now puts the player in the game right away
-- (or on the waitlist when it is full). Before, approval only unlocked the old $1-deposit checkout, removed in 37.
-- Also adds players who were already approved but never got in.
--   sqlcmd -S localhost -E -I -b -i database/38-approve-joins.sql
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=37) THROW 50002,'Install migration 37 first.',1;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=38) THROW 50002,'Migration 38 is already installed.',1;
GO
CREATE OR ALTER PROCEDURE dbo.DecideJoinRequest @GameId int,@HostUserId int,@UserId int,@Approve bit AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  IF NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId AND HostUserId=@HostUserId) THROW 50003,'Only the host can decide.',1;
  UPDATE dbo.GameJoinRequests SET Status=IIF(@Approve=1,'Approved','Declined'),DecidedBy=@HostUserId,DecidedAt=SYSUTCDATETIME() WHERE GameId=@GameId AND UserId=@UserId AND Status='Pending';
  IF @@ROWCOUNT=0 THROW 50004,'This request was already handled.',1;
  DECLARE @Result varchar(20)='Declined';
  IF @Approve=1
   -- Joins the game, or the waitlist when full. Sends the player their "place confirmed" / "waitlist" notification.
   EXEC dbo.sp_JoinGameOrActivity @GameId=@GameId,@UserId=@UserId,@ResultStatus=@Result OUTPUT,@ReturnResult=0;
  ELSE
   INSERT dbo.Notifications(UserId,GameId,Title,Body) VALUES(@UserId,@GameId,N'Request declined',N'The host could not take you this time. Find another game in Discover.');
  COMMIT;
  SELECT CASE WHEN @Approve=0 THEN 'Declined' WHEN @Result='Waitlisted' THEN 'Waitlisted' ELSE 'Approved' END AS Status;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
-- Backfill: approved players of upcoming open games who are not in yet.
DECLARE @G int,@U int,@S varchar(20);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
 SELECT r.GameId,r.UserId FROM dbo.GameJoinRequests r JOIN dbo.GamesAndEvents g ON g.EventId=r.GameId
 WHERE r.Status='Approved' AND g.GameStatus='Open' AND g.StartsAt>SYSUTCDATETIME()
  AND NOT EXISTS(SELECT 1 FROM dbo.Participations p WHERE p.GameId=r.GameId AND p.UserId=r.UserId)
  AND NOT EXISTS(SELECT 1 FROM dbo.Waitlists w WHERE w.GameId=r.GameId AND w.UserId=r.UserId);
OPEN c; FETCH NEXT FROM c INTO @G,@U;
WHILE @@FETCH_STATUS=0
BEGIN
 BEGIN TRY EXEC dbo.sp_JoinGameOrActivity @GameId=@G,@UserId=@U,@ResultStatus=@S OUTPUT,@ReturnResult=0; PRINT CONCAT('Added user ',@U,' to game ',@G,': ',@S); END TRY
 BEGIN CATCH PRINT CONCAT('Skipped user ',@U,' game ',@G,': ',ERROR_MESSAGE()); END CATCH;
 FETCH NEXT FROM c INTO @G,@U;
END;
CLOSE c; DEALLOCATE c;
INSERT dbo.PlatformMigrations(Version) VALUES(38);
GO
SELECT 'Migration 38 completed successfully' AS Result;
GO
