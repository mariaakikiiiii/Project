-- GIN401 performance study on the large CORE table dbo.CourtBookings (about 127,000 rows after
-- perf-court-bookings-seed.sql). Each key query of the app runs twice:
--   (A) normally, so SQL Server uses the index designed for it, and
--   (B) forced to scan the whole table with INDEX(1) (the clustered primary key), as if the index did not exist.
-- In SSMS: press Ctrl+M ("Include Actual Execution Plan"), run the file, then compare the Messages tab
-- (logical reads from STATISTICS IO) and the plans (Index Seek vs Clustered Index Scan).
USE GameOn;
GO
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; -- required to use indexes on computed (Price) and filtered columns
DECLARE @Court int=(SELECT TOP(1) c.CourtId FROM dbo.Courts c JOIN dbo.Clubs k ON k.ClubId=c.ClubId WHERE k.Name=N'GameOn Performance Lab (synthetic data)' ORDER BY c.CourtId);
DECLARE @Club int=(SELECT ClubId FROM dbo.Courts WHERE CourtId=@Court);
DECLARE @User int=(SELECT TOP(1) UserId FROM dbo.CourtBookings WHERE CourtId=@Court ORDER BY BookingId);
DECLARE @Day datetime2(3)=DATEADD(day,-30,CONVERT(date,SYSUTCDATETIME()));
DECLARE @From datetime2(3)=DATEADD(month,-1,DATEFROMPARTS(YEAR(SYSUTCDATETIME()),MONTH(SYSUTCDATETIME()),1));
DECLARE @To datetime2(3)=DATEADD(month,1,@From);
-- OPTION(RECOMPILE) lets the optimizer see the variable values, exactly like the app's parameters (local variables would
-- otherwise be planned with blind guesses). Statistics are switched on only after the setup lookups above.
SET STATISTICS IO ON; SET STATISTICS TIME ON;

PRINT '== Q1 Court schedule for one day (GetCourtSchedule): index IX_CB_Court_Time (CourtId, StartsAt)';
SELECT BookingId,StartsAt,EndsAt,Status FROM dbo.CourtBookings WHERE CourtId=@Court AND StartsAt>=@Day AND StartsAt<DATEADD(day,1,@Day) OPTION(RECOMPILE);
SELECT BookingId,StartsAt,EndsAt,Status FROM dbo.CourtBookings WITH(INDEX(1)) WHERE CourtId=@Court AND StartsAt>=@Day AND StartsAt<DATEADD(day,1,@Day) OPTION(RECOMPILE);

PRINT '== Q2 A player''s booking history (MyCourtBookings): index IX_CB_User (UserId, StartsAt)';
SELECT TOP(20) BookingId,CourtId,StartsAt,Status FROM dbo.CourtBookings WHERE UserId=@User ORDER BY StartsAt DESC OPTION(RECOMPILE);
SELECT TOP(20) BookingId,CourtId,StartsAt,Status FROM dbo.CourtBookings WITH(INDEX(1)) WHERE UserId=@User ORDER BY StartsAt DESC OPTION(RECOMPILE);

PRINT '== Q3 Club revenue last month (club dashboard): index IX_CB_Court_Time, one seek per court';
SELECT SUM(b.Price) AS Revenue,COUNT(*) AS Bookings FROM dbo.Courts c JOIN dbo.CourtBookings b ON b.CourtId=c.CourtId
WHERE c.ClubId=@Club AND b.StartsAt>=@From AND b.StartsAt<@To AND b.Status IN('Completed','NoShow') OPTION(RECOMPILE);
SELECT SUM(b.Price) AS Revenue,COUNT(*) AS Bookings FROM dbo.Courts c JOIN dbo.CourtBookings b WITH(INDEX(1)) ON b.CourtId=c.CourtId
WHERE c.ClubId=@Club AND b.StartsAt>=@From AND b.StartsAt<@To AND b.Status IN('Completed','NoShow') OPTION(RECOMPILE);

PRINT '== Q4 Platform bookings per day last month (admin analytics): index IX_CB_Start (StartsAt) from migration 35';
SELECT CONVERT(date,StartsAt) AS Day,COUNT(*) AS Bookings,SUM(Price) AS Value FROM dbo.CourtBookings
WHERE StartsAt>=@From AND StartsAt<@To AND Status IN('Confirmed','Completed','NoShow') GROUP BY CONVERT(date,StartsAt) ORDER BY Day OPTION(RECOMPILE);
SELECT CONVERT(date,StartsAt) AS Day,COUNT(*) AS Bookings,SUM(Price) AS Value FROM dbo.CourtBookings WITH(INDEX(1))
WHERE StartsAt>=@From AND StartsAt<@To AND Status IN('Confirmed','Completed','NoShow') GROUP BY CONVERT(date,StartsAt) ORDER BY Day OPTION(RECOMPILE);

PRINT '== Q5 Double-booking guard (BookCourt): unique filtered index UX_CB_Slot (CourtId, StartsAt) WHERE active';
SELECT COUNT(*) AS ActiveBookingsInSlot FROM dbo.CourtBookings WHERE CourtId=@Court AND StartsAt=@Day AND Status IN('Pending','Confirmed','Completed','NoShow') OPTION(RECOMPILE);
SET STATISTICS IO OFF; SET STATISTICS TIME OFF;
