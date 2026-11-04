-- Development/test databases ONLY. Requires 01 + 02; reruns add only missing log rows.
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF NOT EXISTS(SELECT 1 FROM dbo.Sports)
 INSERT dbo.Sports(Name) VALUES(N'Basketball'),(N'Football'),(N'Padel');
IF NOT EXISTS(SELECT 1 FROM dbo.Venues)
 INSERT dbo.Venues(Name,Area,Address) VALUES
 (N'Central Court',N'Beirut',N'Central sports complex'),
 (N'North Field',N'Jounieh',N'North sports complex');
-- Sentinel is not a valid Identity password hash: this fixture account cannot log in.
IF NOT EXISTS(SELECT 1 FROM dbo.Users WHERE Email=N'fixture@gameon.invalid')
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(N'fixture@gameon.invalid',N'Fixture Host',N'DISABLED_FIXTURE');
DECLARE @UserId int=(SELECT UserId FROM dbo.Users WHERE Email=N'fixture@gameon.invalid');
IF NOT EXISTS(SELECT 1 FROM dbo.Games WHERE HostUserId=@UserId)
BEGIN
 DECLARE @SportId int=(SELECT MIN(SportId) FROM dbo.Sports),@VenueId int=(SELECT MIN(VenueId) FROM dbo.Venues);
 DECLARE @Start datetime2(3)=DATEADD(day,30,SYSUTCDATETIME());
 EXEC dbo.CreateGame @UserId,@SportId,@VenueId,@Start,10;
END;
DECLARE @GameId int=(SELECT MIN(GameId) FROM dbo.Games WHERE HostUserId=@UserId);
DECLARE @Remaining int=200000-(SELECT COUNT(*) FROM dbo.GameActivityLogs WHERE GameId=@GameId AND Details=N'Synthetic performance fixture');
IF @Remaining>0
BEGIN
 -- Six ten-row sets yield a million integers, avoiding row-by-row loops.
 ;WITH D(n) AS (SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) x(n)),
 N AS (SELECT TOP(@Remaining) ROW_NUMBER() OVER(ORDER BY a.n,b.n,c.n,d.n,e.n,f.n) AS n
 FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d CROSS JOIN D e CROSS JOIN D f)
 INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType,OccurredAt,Details)
 SELECT @GameId,@UserId,CASE n%3 WHEN 0 THEN 'Joined' WHEN 1 THEN 'Cancelled' ELSE 'Waitlisted' END,
 DATEADD(second,-CONVERT(int,n),SYSUTCDATETIME()),N'Synthetic performance fixture' FROM N;
END;
COMMIT;
UPDATE STATISTICS dbo.GameActivityLogs WITH FULLSCAN;
SELECT COUNT_BIG(*) AS ActivityRows FROM dbo.GameActivityLogs;
