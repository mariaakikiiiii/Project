-- GameOn performance data for the GIN401 study: makes CourtBookings (a CORE table) large.
-- SYNTHETIC DATA, clearly labelled, and kept away from real users:
--   * one venue "GameOn Performance Lab (synthetic data)" (hidden from venue search by migration 35),
--   * one INACTIVE club with 16 courts (players never see it, so no availability is invented),
--   * 2,000 fixture users (@fixtures.gameon.invalid, password disabled: nobody can sign in as them),
--   * about 127,000 bookings, ALL IN THE PAST 24 months (Completed, NoShow or Cancelled).
-- Requires migration 35. Safe to run twice (it skips what already exists). Run in SSMS with your Windows login.
-- To remove everything again, see the block at the end of this file.
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=35) THROW 50002,'Install migration 35 first.',1;
BEGIN TRANSACTION;
-- Fixture players with a realistic spread of genders and ages (needed by the admin analytics).
;WITH D(n) AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))v(n)),
 N AS(SELECT TOP(2000) ROW_NUMBER()OVER(ORDER BY a.n,b.n,c.n,d.n) n FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d)
INSERT dbo.Users(Email,DisplayName,PasswordHash,Gender,DateOfBirth)
SELECT N'perf-'+CONVERT(nvarchar(10),n)+N'@fixtures.gameon.invalid',N'Perf Fixture '+CONVERT(nvarchar(10),n),N'DISABLED_FIXTURE',
 CASE WHEN n%20=0 THEN 'PreferNotToSay' WHEN n%50=1 THEN 'NonBinary' WHEN n%3=0 THEN 'Female' ELSE 'Male' END,
 DATEADD(day,-((n*7919)%(365*45))-365*16,CONVERT(date,SYSUTCDATETIME()))
FROM N WHERE NOT EXISTS(SELECT 1 FROM dbo.Users u WHERE u.Email=N'perf-'+CONVERT(nvarchar(10),n)+N'@fixtures.gameon.invalid');

DECLARE @Venue int=(SELECT VenueId FROM dbo.Venues WHERE Name=N'GameOn Performance Lab (synthetic data)');
IF @Venue IS NULL
BEGIN
 INSERT dbo.Venues(Name,Area,Address,ListingStatus,DirectoryNote) VALUES(N'GameOn Performance Lab (synthetic data)',N'Beirut',N'Not a real venue','Demo',N'Synthetic performance data - not a real venue.');
 SET @Venue=SCOPE_IDENTITY();
END;
DECLARE @Owner int=(SELECT MIN(UserId) FROM dbo.Users WHERE Email LIKE N'perf-%@fixtures.gameon.invalid');
DECLARE @Club int=(SELECT ClubId FROM dbo.Clubs WHERE VenueId=@Venue);
IF @Club IS NULL
BEGIN
 INSERT dbo.Clubs(Name,VenueId,IsActive,CreatedBy) VALUES(N'GameOn Performance Lab (synthetic data)',@Venue,0,@Owner);
 SET @Club=SCOPE_IDENTITY();
END;
IF NOT EXISTS(SELECT 1 FROM dbo.Courts WHERE ClubId=@Club)
BEGIN
 DECLARE @Padel int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes WHERE Name LIKE N'Padel%'),@Tennis int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes WHERE Name LIKE N'Tennis%'),
  @Foot int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes WHERE Name LIKE N'Football%' OR Name LIKE N'%5-a-side%' ORDER BY SubtypeId),@Basket int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes WHERE Name LIKE N'Basketball%');
 INSERT dbo.Courts(ClubId,Name,SubtypeId,SlotMinutes,OpenHour,CloseHour,BasePrice,PeakPrice,PeakStartHour,PeakEndHour,IsActive)
 SELECT @Club,N'Lab court '+CONVERT(nvarchar(3),n),CASE WHEN n<=6 THEN @Padel WHEN n<=10 THEN COALESCE(@Foot,@Padel) WHEN n<=14 THEN @Tennis ELSE @Basket END,
  60,9,23,CASE WHEN n<=6 THEN 30 WHEN n<=10 THEN 50 WHEN n<=14 THEN 20 ELSE 25 END,CASE WHEN n<=6 THEN 40 WHEN n<=10 THEN 70 WHEN n<=14 THEN 28 ELSE 35 END,18,22,1
 FROM (VALUES(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16)) v(n);
END;
-- One row per (court, day, hour) over the past 730 days, 9:00 to 22:00 Beirut; about 78% of slots booked.
IF NOT EXISTS(SELECT 1 FROM dbo.CourtBookings b JOIN dbo.Courts c ON c.CourtId=b.CourtId WHERE c.ClubId=@Club)
BEGIN
 ;WITH D(n) AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))v(n)),
  Days AS(SELECT TOP(730) ROW_NUMBER()OVER(ORDER BY a.n,b.n,c.n) d FROM D a CROSS JOIN D b CROSS JOIN D c),
  Hours AS(SELECT h FROM(VALUES(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22))v(h)),
  U AS(SELECT UserId,ROW_NUMBER()OVER(ORDER BY UserId)-1 rn FROM dbo.Users WHERE Email LIKE N'perf-%@fixtures.gameon.invalid'),
  S AS(
   SELECT c.CourtId,c.BasePrice,c.PeakPrice,c.PeakStartHour,c.PeakEndHour,h.h,
    DATEADD(hour,h.h-2,CONVERT(datetime2(3),DATEADD(day,-dd.d,CONVERT(date,SYSUTCDATETIME())))) AS StartsAt,
    ABS(CHECKSUM(c.CourtId,dd.d,h.h))%100 AS r1, ABS(CHECKSUM(dd.d,h.h,c.CourtId,7))%100 AS r2, ABS(CHECKSUM(c.CourtId*31+dd.d*17+h.h))%2000 AS ur
   FROM dbo.Courts c CROSS JOIN Days dd CROSS JOIN Hours h WHERE c.ClubId=@Club)
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey,CreatedAt,CancelledAt)
 SELECT s.CourtId,u.UserId,s.StartsAt,DATEADD(minute,60,s.StartsAt),
  IIF(s.h>=s.PeakStartHour AND s.h<s.PeakEndHour,s.PeakPrice,s.BasePrice),
  CASE WHEN s.r2<85 THEN 'Completed' WHEN s.r2<92 THEN 'NoShow' ELSE 'Cancelled' END,'Player',u.UserId,NEWID(),
  DATEADD(hour,-(1+s.r1%96),s.StartsAt),IIF(s.r2>=92,DATEADD(hour,-(s.r1%12),s.StartsAt),NULL)
 FROM S s JOIN U u ON u.rn=s.ur WHERE s.r1<78;
END;
COMMIT;
SELECT (SELECT COUNT(*) FROM dbo.CourtBookings) AS CourtBookingsTotal,
 (SELECT COUNT(*) FROM dbo.CourtBookings b JOIN dbo.Courts c ON c.CourtId=b.CourtId WHERE c.ClubId=@Club) AS SyntheticBookings;
GO
/* ---------- To remove the synthetic data later (run separately) ----------
BEGIN TRANSACTION;
DECLARE @V int=(SELECT VenueId FROM dbo.Venues WHERE Name=N'GameOn Performance Lab (synthetic data)'),@C int;
SET @C=(SELECT ClubId FROM dbo.Clubs WHERE VenueId=@V);
DELETE b FROM dbo.CourtBookings b JOIN dbo.Courts c ON c.CourtId=b.CourtId WHERE c.ClubId=@C;
DELETE dbo.Courts WHERE ClubId=@C; DELETE dbo.Clubs WHERE ClubId=@C; DELETE dbo.Venues WHERE VenueId=@V;
DELETE dbo.Users WHERE Email LIKE N'perf-%@fixtures.gameon.invalid';
COMMIT;
*/
