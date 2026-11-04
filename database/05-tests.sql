-- Run as migration/test account on a disposable seeded database.
-- Test fixture mutations are rolled back; identity gaps are expected.
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Host int=(SELECT MIN(UserId) FROM dbo.Users),@Sport int=(SELECT MIN(SportId) FROM dbo.Sports),
 @Venue int=(SELECT MIN(VenueId) FROM dbo.Venues),@A int,@B int,@C int,@Game int;
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'A',N'DISABLED_FIXTURE');
 SET @A=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'B',N'DISABLED_FIXTURE');
 SET @B=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'C',N'DISABLED_FIXTURE');
 SET @C=CONVERT(int,SCOPE_IDENTITY());
 DECLARE @Start datetime2=DATEADD(day,1,SYSUTCDATETIME());
 EXEC dbo.CreateGame @Host,@Sport,@Venue,@Start,2;
 SELECT @Game=MAX(GameId) FROM dbo.Games WHERE HostUserId=@Host;
 EXEC dbo.JoinGame @Game,@A;
 EXEC dbo.JoinGame @Game,@A; -- retry must be idempotent
 EXEC dbo.JoinGame @Game,@B;
 EXEC dbo.JoinGame @Game,@C;
 IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game)<>2 THROW 51000,'Capacity/idempotency failed.',1;
 IF dbo.WaitlistPosition(@Game,@B)<>1 OR dbo.WaitlistPosition(@Game,@C)<>2 THROW 51000,'FIFO failed.',1;
 EXEC dbo.CancelParticipation @Game,@A;
 IF NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@B) THROW 51000,'Promotion failed.',1;
 IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@Game AND UserId=@B) THROW 51000,'Promotion left stale waitlist.',1;
 EXEC dbo.CancelParticipation @Game,@C;
 IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@Game) THROW 51000,'Leaving waitlist failed.',1;
 IF (SELECT COUNT(*) FROM dbo.GameActivityLogs WHERE GameId=@Game AND ActorUserId=@A AND ActivityType='Joined')<>1
  THROW 51000,'Idempotent join duplicated audit.',1;
 ROLLBACK;
 PRINT 'PASS: capacity, duplicate retry, FIFO, promotion, waitlist withdrawal and audit.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
