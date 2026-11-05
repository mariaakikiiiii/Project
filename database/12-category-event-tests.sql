-- Run as migration owner on a DISPOSABLE database after 09 and 10. Rolls fixtures back.
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 IF (SELECT COUNT(*) FROM dbo.Subtypes s JOIN dbo.Categories c ON c.CategoryId=s.CategoryId WHERE c.Slug='sports'
  AND s.Slug IN('football','basketball','padel','tennis','volleyball','badminton','table-tennis','squash','swimming'))<>9
  THROW 51000,'Nine required sports are missing.',1;
 IF (SELECT COUNT(*) FROM dbo.Subtypes s JOIN dbo.Categories c ON c.CategoryId=s.CategoryId WHERE c.Slug='activities'
  AND s.Slug IN('paintball','laser-tag','icombat','escape-rooms','go-karting','bowling','archery-tag','airsoft'))<>8
  THROW 51000,'Eight required activities are missing.',1;
 IF (SELECT COUNT_BIG(*) FROM dbo.UserActivityLogs WHERE IsSynthetic=1)<100001 THROW 51000,'Large analytics seed must exceed 100,000 rows.',1;
 DECLARE @Host int=(SELECT MIN(UserId) FROM dbo.Users),@Subtype int=(SELECT SubtypeId FROM dbo.Subtypes WHERE Slug='paintball'),
 @Venue int=(SELECT MIN(VenueId) FROM dbo.Venues),@A int,@B int,@Event int,@Start datetime2=DATEADD(day,7,SYSUTCDATETIME());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Activity player A',N'DISABLED_FIXTURE');
 SET @A=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Activity player B',N'DISABLED_FIXTURE');
 SET @B=CONVERT(int,SCOPE_IDENTITY());
 EXEC dbo.CreateGame @Host,@Subtype,@Venue,@Start,2,N'Paintball fixture',15,'USD',0;
 SELECT @Event=MAX(EventId) FROM dbo.GamesAndEvents WHERE HostUserId=@Host;
 IF NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@Event AND SubtypeId=@Subtype) THROW 51000,'Event stored in wrong subtype.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Games WHERE GameId=@Event) THROW 51000,'Compatibility view lost event.',1;
 EXEC dbo.sp_JoinGameOrActivity @Event,@A,0,'Cash';
 EXEC dbo.sp_JoinGameOrActivity @Event,@A,0,'Cash';
 EXEC dbo.sp_JoinGameOrActivity @Event,@B,0,'Cash';
 IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Event)<>2 THROW 51000,'Activity capacity/idempotency failed.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@Event AND UserId=@B AND PaymentMethod='Cash') THROW 51000,'Waitlist payment preference missing.',1;
 EXEC dbo.CancelParticipation @Event,@A;
 IF NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Event AND UserId=@B AND PaymentMethod='Cash') THROW 51000,'Promotion/payment preservation failed.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.GameSummary WHERE GameId=@Event AND CategorySlug='activities') THROW 51000,'Activity category missing from summary.',1;
 EXEC dbo.DiscoverGames @CategorySlug='activities',@OpenOnly=1,@UserId=@A;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserActivityLogs WHERE UserId=@A AND Action='DiscoverySearch') THROW 51000,'Discovery analytics missing.',1;
 ROLLBACK;
 PRINT 'PASS: 9 sports, 8 activities, 100k+ analytics, normalized storage, cash preference, idempotency, waitlist and promotion.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
