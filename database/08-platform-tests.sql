-- Disposable upgraded database, migration/test account. All fixtures are rolled back.
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Host int=(SELECT MIN(UserId) FROM dbo.Users),@Sport int=(SELECT MIN(SportId) FROM dbo.Sports),
 @Venue int=(SELECT MIN(VenueId) FROM dbo.Venues),@A int,@B int,@C int,@D int,@Game int;
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Covered player',N'DISABLED_FIXTURE');
 SET @A=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Player B',N'DISABLED_FIXTURE');
 SET @B=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Queued player',N'DISABLED_FIXTURE');
 SET @C=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Next covered player',N'DISABLED_FIXTURE');
 SET @D=CONVERT(int,SCOPE_IDENTITY());
 DECLARE @Start datetime2(3)=DATEADD(day,10,SYSUTCDATETIME());
 EXEC dbo.CreateGame @Host,@Sport,@Venue,@Start,3,N'Test game',20,'USD',1;
 SELECT @Game=MAX(GameId) FROM dbo.Games WHERE HostUserId=@Host;
 EXEC dbo.JoinGame @Game,@A,1;
 EXEC dbo.JoinGame @Game,@A,1;
 EXEC dbo.JoinGame @Game,@B;
 EXEC dbo.JoinGame @Game,@C;
 IF (SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@Game)<>1 THROW 51000,'Sponsor claim/idempotency failed.',1;
 EXEC dbo.CancelParticipation @Game,@A;
 IF EXISTS(SELECT 1 FROM dbo.SponsoredSeats WHERE GameId=@Game) THROW 51000,'Sponsor release failed.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@C) THROW 51000,'Promotion failed.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Notifications WHERE GameId=@Game AND UserId=@C AND Title=N'A place opened. You are in!') THROW 51000,'Promotion notification missing.',1;
 EXEC dbo.CancelParticipation @Game,@B;
 EXEC dbo.JoinGame @Game,@D,1;
 IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game)<>3 THROW 51000,'Capacity broken.',1;
 DECLARE @Sports nvarchar(2000)=N'['+CONVERT(nvarchar(12),@Sport)+N']';
 EXEC dbo.SaveProfile @A,N'Player A',N'Weekend sports',N'Beirut','Beginner',@Sports;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserSportPreferences WHERE UserId=@A AND SportId=@Sport) THROW 51000,'Preference persistence failed.',1;
 EXEC dbo.JoinGame @Game,@B; -- full roster; B queues again
 EXEC dbo.EditGame @Game,@Host,1,@Start,4,N'Updated test game',20,'USD',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@B) THROW 51000,'Capacity increase did not promote queued player.',1;
 IF EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@Game AND UserId=@B) THROW 51000,'Capacity increase left stale queue membership.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Notifications WHERE GameId=@Game AND UserId=@D AND Title=N'Your game was updated') THROW 51000,'Edit notification missing.',1;
 EXEC dbo.CancelGame @Game,@Host;
 EXEC dbo.CancelGame @Game,@Host;
 IF (SELECT GameStatus FROM dbo.Games WHERE GameId=@Game)<>'Cancelled' THROW 51000,'Game cancellation failed.',1;
 IF (SELECT COUNT(*) FROM dbo.GameActivityLogs WHERE GameId=@Game AND ActivityType='GameCancelled')<>1 THROW 51000,'Cancellation was not idempotent.',1;
 DECLARE @Notification bigint=(SELECT MAX(NotificationId) FROM dbo.Notifications WHERE UserId=@D);
 EXEC dbo.ReadNotification @D,@Notification;
 IF NOT EXISTS(SELECT 1 FROM dbo.Notifications WHERE NotificationId=@Notification AND ReadAt IS NOT NULL) THROW 51000,'Read notification failed.',1;
 -- Password work uses a disabled fixture updated only within this rolled-back transaction.
 UPDATE dbo.Users SET PasswordHash=N'TEST_HASH' WHERE UserId=@A;
 DECLARE @Email nvarchar(254)=(SELECT Email FROM dbo.Users WHERE UserId=@A),@Token binary(32)=CRYPT_GEN_RANDOM(32);
 EXEC dbo.RequestPasswordReset @Email,@Token,N'protected-fixture-token';
 IF NOT EXISTS(SELECT 1 FROM dbo.ResetEmailOutbox WHERE Recipient=@Email) THROW 51000,'Reset outbox missing.',1;
 EXEC dbo.ResetPassword @Token,N'NEW_TEST_HASH';
 IF (SELECT SecurityVersion FROM dbo.Users WHERE UserId=@A)<>2 THROW 51000,'Sessions were not revoked.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.PasswordResetTokens WHERE TokenHash=@Token AND UsedAt IS NOT NULL) THROW 51000,'Reset token not consumed.',1;
 ROLLBACK;
 PRINT 'PASS: host-covered places, idempotency, release, promotion, preferences, notifications, editing, cancellation and reset token/session revocation.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
