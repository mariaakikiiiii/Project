-- GameOn migration 40: remove the coaches feature (coach profiles and directory, the club "Coach" staff role,
-- the coach of a class, and coach commission in payroll). Back up first.
--   sqlcmd -S localhost -E -I -b -i database/40-remove-coaches.sql
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=39) THROW 50002,'Install migration 39 first.',1;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=40) THROW 50002,'Migration 40 is already installed.',1;
GO
CREATE OR ALTER FUNCTION dbo.ClubRoleRank(@ClubId int,@UserId int) RETURNS int AS
BEGIN
 -- 4 Owner, 3 Manager, 2 Reception, 0 none. GameOn operators act as owners of every club.
 IF EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) RETURN 4;
 RETURN COALESCE((SELECT CASE Role WHEN 'Owner' THEN 4 WHEN 'Manager' THEN 3 WHEN 'Reception' THEN 2 END FROM dbo.ClubStaff WHERE ClubId=@ClubId AND UserId=@UserId),0);
END;
GO
CREATE OR ALTER PROCEDURE dbo.SetClubStaff @ClubId int,@ActorId int,@UserId int,@Role varchar(12)=NULL AS
BEGIN
 SET NOCOUNT ON;
 IF dbo.ClubRoleRank(@ClubId,@ActorId)<4 THROW 50003,'Only the club owner can manage staff.',1;
 IF @UserId=@ActorId THROW 50002,'You cannot change your own role.',1;
 IF @Role IS NOT NULL AND @Role NOT IN('Manager','Reception') THROW 50002,'Choose Manager or Reception.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@UserId) THROW 50002,'No GameOn account with that email.',1;
 IF @Role IS NULL DELETE dbo.ClubStaff WHERE ClubId=@ClubId AND UserId=@UserId AND Role<>'Owner';
 ELSE MERGE dbo.ClubStaff AS t USING (SELECT @ClubId c,@UserId u) s ON t.ClubId=s.c AND t.UserId=s.u
  WHEN MATCHED AND t.Role<>'Owner' THEN UPDATE SET Role=@Role
  WHEN NOT MATCHED THEN INSERT(ClubId,UserId,Role,AddedBy) VALUES(@ClubId,@UserId,@Role,@ActorId);
 SELECT 'Saved' AS Status;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ClassRoster @ClassId int,@ActorId int AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @Club int=(SELECT ClubId FROM dbo.Classes WHERE ClassId=@ClassId);
 IF @Club IS NULL THROW 50001,'Class not found.',1;
 IF dbo.ClubRoleRank(@Club,@ActorId)<2 THROW 50003,'Only club staff.',1;
 SELECT r.UserId,u.DisplayName,r.Status,r.Attended,CAST(CASE WHEN r.PurchaseId IS NULL THEN 0 ELSE 1 END AS bit) AS PaidWithPack
 FROM dbo.ClassRegistrations r JOIN dbo.Users u ON u.UserId=r.UserId WHERE r.ClassId=@ClassId AND r.Status<>'Cancelled' ORDER BY r.Status,u.DisplayName;
END;
GO
CREATE OR ALTER PROCEDURE dbo.MarkClassAttendance @ClassId int,@ActorId int,@UserId int,@Attended bit AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @Club int,@Start datetime2(0);
 SELECT @Club=ClubId,@Start=StartsAt FROM dbo.Classes WHERE ClassId=@ClassId;
 IF @Club IS NULL THROW 50001,'Class not found.',1;
 IF dbo.ClubRoleRank(@Club,@ActorId)<2 THROW 50003,'Only club staff.',1;
 IF @Start>DATEADD(minute,30,SYSUTCDATETIME()) THROW 50002,'Attendance opens 30 minutes before the class.',1;
 UPDATE dbo.ClassRegistrations SET Attended=@Attended,AttendanceBy=@ActorId WHERE ClassId=@ClassId AND UserId=@UserId AND Status='Registered';
 IF @@ROWCOUNT=0 THROW 50001,'This player is not registered.',1;
 EXEC dbo.LogStaff @Club,@ActorId,'ClassAttendance',NULL;
 SELECT 'Saved' AS Status;
END;
GO
-- Payroll: salary only (coach commission removed).
CREATE OR ALTER PROCEDURE dbo.AddStaffPay @ClubId int,@ActorId int,@UserId int,@PeriodMonth date,@Salary decimal(10,2),@Note nvarchar(120)=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF dbo.ClubRoleRank(@ClubId,@ActorId)<4 THROW 50003,'Only the club owner runs payroll.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.ClubStaff WHERE ClubId=@ClubId AND UserId=@UserId) THROW 50002,'Choose a staff member of this club.',1;
 IF @Salary<=0 THROW 50002,'Enter a salary above zero.',1;
 SET @PeriodMonth=DATEFROMPARTS(YEAR(@PeriodMonth),MONTH(@PeriodMonth),1);
 IF @PeriodMonth>CAST(SYSUTCDATETIME() AS date) THROW 50002,'Run payroll for the current or a past month.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  INSERT dbo.ClubExpenses(ClubId,Amount,Category,SpentOn,Note,CreatedBy)
  SELECT @ClubId,@Salary,'Staff',@PeriodMonth,LEFT(N'Payroll: '+u.DisplayName,200),@ActorId FROM dbo.Users u WHERE u.UserId=@UserId;
  DECLARE @Exp bigint=SCOPE_IDENTITY();
  INSERT dbo.StaffPay(ClubId,UserId,PeriodMonth,Salary,Note,ExpenseId,CreatedBy) VALUES(@ClubId,@UserId,@PeriodMonth,@Salary,@Note,@Exp,@ActorId);
  EXEC dbo.LogStaff @ClubId,@ActorId,'Payroll',NULL;
  COMMIT;
  SELECT @Salary AS Salary,@Salary AS Total;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ClubBackOffice @ClubId int,@ActorId int AS
BEGIN
 SET NOCOUNT ON;
 IF dbo.ClubRoleRank(@ClubId,@ActorId)<4 THROW 50003,'Only the club owner sees payroll and the activity log.',1;
 SELECT Balance,(SELECT COALESCE(SUM(Amount),0) FROM dbo.ClubLedger WHERE ClubId=@ClubId AND Kind='Payout') AS PaidOut FROM dbo.Clubs WHERE ClubId=@ClubId;
 SELECT TOP(100) a.ActivityId,u.DisplayName,a.Action,a.Detail,a.At FROM dbo.StaffActivity a JOIN dbo.Users u ON u.UserId=a.ActorId WHERE a.ClubId=@ClubId ORDER BY a.ActivityId DESC;
 SELECT TOP(60) p.PayId,u.DisplayName,p.PeriodMonth,p.Salary,p.Note FROM dbo.StaffPay p JOIN dbo.Users u ON u.UserId=p.UserId WHERE p.ClubId=@ClubId ORDER BY p.PeriodMonth DESC,u.DisplayName;
 SELECT s.UserId,u.DisplayName,s.Role FROM dbo.ClubStaff s JOIN dbo.Users u ON u.UserId=s.UserId WHERE s.ClubId=@ClubId ORDER BY s.Role,u.DisplayName;
 SELECT TOP(50) EntryId,Amount,BalanceAfter,Kind,RefType,Reference,CreatedAt FROM dbo.ClubLedger WHERE ClubId=@ClubId ORDER BY EntryId DESC;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetCourtSchedule @ClubId int,@Day date,@UserId int=NULL,@CourtId int=NULL,@IncludeClasses bit=1 AS
BEGIN
 SET NOCOUNT ON;
 -- @Day is a Beirut calendar day. Every slot is computed in Beirut time and returned with its UTC start.
 DECLARE @Rank int=dbo.ClubRoleRank(@ClubId,@UserId),@Pro bit=CASE WHEN @UserId IS NULL THEN 0 ELSE dbo.IsPro(@UserId) END;
 DECLARE @ProPct tinyint=(SELECT CASE WHEN IsPartner=1 THEN ProDiscountPct ELSE 0 END FROM dbo.Clubs WHERE ClubId=@ClubId);
 WITH n AS (SELECT TOP(48) ROW_NUMBER() OVER(ORDER BY (SELECT NULL))-1 AS i FROM sys.all_objects),
 slots AS (
  SELECT k.CourtId,k.Name AS Court,k.SubtypeId,k.SlotMinutes,DATEADD(minute,k.OpenHour*60+n.i*k.SlotMinutes,CAST(@Day AS datetime2(0))) AS LocalStart,k.BasePrice,k.PeakPrice,k.PeakStartHour,k.PeakEndHour
  FROM dbo.Courts k CROSS JOIN n WHERE k.ClubId=@ClubId AND k.IsActive=1 AND (@CourtId IS NULL OR k.CourtId=@CourtId) AND k.OpenHour*60+(n.i+1)*k.SlotMinutes<=k.CloseHour*60)
 SELECT s.CourtId,s.Court,s.SubtypeId,s.LocalStart,DATEADD(minute,s.SlotMinutes,s.LocalStart) AS LocalEnd,dbo.FromBeirut(s.LocalStart) AS StartsAtUtc,
  CAST(CASE WHEN DATEPART(hour,s.LocalStart)>=s.PeakStartHour AND DATEPART(hour,s.LocalStart)<s.PeakEndHour THEN 1 ELSE 0 END AS bit) AS IsPeak,
  CASE WHEN DATEPART(hour,s.LocalStart)>=s.PeakStartHour AND DATEPART(hour,s.LocalStart)<s.PeakEndHour THEN s.PeakPrice ELSE s.BasePrice END AS ListPrice,
  CASE WHEN @Pro=1 THEN @ProPct ELSE 0 END AS ProDiscountPct,
  CASE WHEN dbo.FromBeirut(s.LocalStart)<=SYSUTCDATETIME() THEN 'Past'
   WHEN EXISTS(SELECT 1 FROM dbo.CourtBlocks b WHERE b.CourtId=s.CourtId AND b.StartsAt<dbo.FromBeirut(DATEADD(minute,s.SlotMinutes,s.LocalStart)) AND b.EndsAt>dbo.FromBeirut(s.LocalStart)) THEN 'Blocked'
   WHEN EXISTS(SELECT 1 FROM dbo.CourtBookings cb WHERE cb.CourtId=s.CourtId AND cb.Status IN('Pending','Confirmed','Completed','NoShow') AND cb.StartsAt<dbo.FromBeirut(DATEADD(minute,s.SlotMinutes,s.LocalStart)) AND cb.EndsAt>dbo.FromBeirut(s.LocalStart))
    THEN CASE WHEN EXISTS(SELECT 1 FROM dbo.CourtBookings cb WHERE cb.CourtId=s.CourtId AND cb.UserId=@UserId AND cb.Status IN('Pending','Confirmed') AND cb.StartsAt=dbo.FromBeirut(s.LocalStart)) THEN 'Mine' WHEN @Rank>=2 AND EXISTS(SELECT 1 FROM dbo.CourtBookings cb WHERE cb.CourtId=s.CourtId AND cb.Status='Pending' AND cb.StartsAt=dbo.FromBeirut(s.LocalStart)) THEN 'Pending' ELSE 'Booked' END
   ELSE 'Free' END AS SlotStatus,
  -- Staff see who booked and why a slot is blocked; players never see other players' names.
  CASE WHEN @Rank>=2 THEN (SELECT TOP(1) COALESCE(u.DisplayName,cb.GuestName) FROM dbo.CourtBookings cb LEFT JOIN dbo.Users u ON u.UserId=cb.UserId WHERE cb.CourtId=s.CourtId AND cb.Status IN('Pending','Confirmed','Completed','NoShow') AND cb.StartsAt=dbo.FromBeirut(s.LocalStart)) END AS BookedBy,
  CASE WHEN @Rank>=2 THEN (SELECT TOP(1) cb.BookingId FROM dbo.CourtBookings cb WHERE cb.CourtId=s.CourtId AND cb.Status IN('Pending','Confirmed','Completed','NoShow') AND cb.StartsAt=dbo.FromBeirut(s.LocalStart))
   ELSE (SELECT TOP(1) cb.BookingId FROM dbo.CourtBookings cb WHERE cb.CourtId=s.CourtId AND cb.UserId=@UserId AND cb.Status IN('Pending','Confirmed') AND cb.StartsAt=dbo.FromBeirut(s.LocalStart)) END AS BookingId,
  CASE WHEN @Rank>=2 THEN (SELECT TOP(1) b.BlockId FROM dbo.CourtBlocks b WHERE b.CourtId=s.CourtId AND b.StartsAt<=dbo.FromBeirut(s.LocalStart) AND b.EndsAt>=dbo.FromBeirut(DATEADD(minute,s.SlotMinutes,s.LocalStart))) END AS BlockId,
  CASE WHEN @Rank>=2 THEN (SELECT TOP(1) b.Reason FROM dbo.CourtBlocks b WHERE b.CourtId=s.CourtId AND b.StartsAt<dbo.FromBeirut(DATEADD(minute,s.SlotMinutes,s.LocalStart)) AND b.EndsAt>dbo.FromBeirut(s.LocalStart)) END AS BlockReason
 FROM slots s ORDER BY s.CourtId,s.LocalStart;
 IF @IncludeClasses=1
 SELECT ClassId,Title,s.Name AS Sport,dbo.ToBeirut(StartsAt) AS LocalStart,DurationMinutes,Capacity,Price,CourtId,
  (SELECT COUNT(*) FROM dbo.ClassRegistrations r WHERE r.ClassId=c.ClassId AND r.Status='Registered') AS Registered,
  (SELECT Status FROM dbo.ClassRegistrations r WHERE r.ClassId=c.ClassId AND r.UserId=@UserId AND r.Status<>'Cancelled') AS MyStatus
 FROM dbo.Classes c JOIN dbo.Subtypes s ON s.SubtypeId=c.SubtypeId
 WHERE c.ClubId=@ClubId AND c.Status='Scheduled' AND dbo.ToBeirut(c.StartsAt)>=CAST(@Day AS datetime2(0)) AND dbo.ToBeirut(c.StartsAt)<DATEADD(day,1,CAST(@Day AS datetime2(0))) ORDER BY c.StartsAt;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CreateClassSeries @ClubId int,@ActorId int,@Title nvarchar(120),@SubtypeId int,@CourtId int=NULL,
 @FirstStartsAtUtc datetime2(0),@DurationMinutes smallint,@Capacity smallint,@Price decimal(10,2),@Weeks tinyint=1 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Rank int=dbo.ClubRoleRank(@ClubId,@ActorId);
 IF @Rank<3 THROW 50003,'Managers and owners can schedule classes.',1;
 IF NULLIF(TRIM(@Title),N'') IS NULL OR @Weeks NOT BETWEEN 1 AND 26 OR @FirstStartsAtUtc<=SYSUTCDATETIME() THROW 50002,'Check the title, first date and number of weeks (1-26).',1;
 IF @CourtId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Courts WHERE CourtId=@CourtId AND ClubId=@ClubId) THROW 50002,'Choose a court of this club.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Series uniqueidentifier=NEWID(),@i int=0,@Local datetime2(0)=dbo.ToBeirut(@FirstStartsAtUtc),@S datetime2(0);
  WHILE @i<@Weeks
  BEGIN
   -- Weekly at the same Beirut wall-clock time (correct across daylight-saving changes).
   SET @S=dbo.FromBeirut(DATEADD(week,@i,@Local));
   INSERT dbo.Classes(ClubId,CourtId,Title,SubtypeId,StartsAt,DurationMinutes,Capacity,Price,SeriesId,CreatedBy)
   VALUES(@ClubId,@CourtId,TRIM(@Title),@SubtypeId,@S,@DurationMinutes,@Capacity,@Price,@Series,@ActorId);
   -- A class on a court reserves that court.
   IF @CourtId IS NOT NULL
   BEGIN
    IF EXISTS(SELECT 1 FROM dbo.CourtBookings WHERE CourtId=@CourtId AND Status='Confirmed' AND StartsAt<DATEADD(minute,@DurationMinutes,@S) AND EndsAt>@S)
     THROW 50004,'A player booking overlaps one of these class times.',1;
    INSERT dbo.CourtBlocks(CourtId,StartsAt,EndsAt,Reason,CreatedBy) VALUES(@CourtId,@S,DATEADD(minute,@DurationMinutes,@S),N'Class: '+TRIM(@Title),@ActorId);
   END;
   SET @i+=1;
  END;
  COMMIT;
  SELECT @Series AS SeriesId,@Weeks AS Created;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.AdminDeleteUser @AdminId int,@UserId int,@Reason nvarchar(300) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF dbo.IsAdmin(@AdminId)=0 THROW 50003,'Admins only.',1;
 IF @UserId=@AdminId THROW 50002,'You cannot delete your own account here.',1;
 IF @Reason IS NULL OR LEN(TRIM(@Reason))<4 THROW 50002,'Write the reason for deleting this account.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Status varchar(10)=(SELECT AccountStatus FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId);
  IF @Status IS NULL THROW 50001,'User not found.',1;
  IF @Status='Deleted' THROW 50004,'This account is already deleted.',1;
  IF dbo.IsAdmin(@UserId)=1 THROW 50004,'Remove the admin role before deleting this account.',1;
  IF EXISTS(SELECT 1 FROM dbo.ClubStaff WHERE UserId=@UserId AND Role='Owner') THROW 50004,'This user owns a club. Give the club a new owner first.',1;
  -- Cancel their upcoming hosted games (players are notified).
  DECLARE @G int;
  DECLARE g CURSOR LOCAL FAST_FORWARD FOR SELECT EventId FROM dbo.GamesAndEvents WHERE HostUserId=@UserId AND GameStatus='Open' AND StartsAt>SYSUTCDATETIME();
  OPEN g; FETCH NEXT FROM g INTO @G;
  WHILE @@FETCH_STATUS=0 BEGIN EXEC dbo.CancelGame @GameId=@G,@HostUserId=@UserId; FETCH NEXT FROM g INTO @G; END;
  CLOSE g; DEALLOCATE g;
  -- Leave upcoming games and waitlists, cancel upcoming court bookings and classes.
  DELETE w FROM dbo.Waitlists w JOIN dbo.GamesAndEvents e ON e.EventId=w.GameId WHERE w.UserId=@UserId AND e.StartsAt>SYSUTCDATETIME();
  DECLARE @LeftGames TABLE(GameId int PRIMARY KEY);
  DELETE p OUTPUT deleted.GameId INTO @LeftGames FROM dbo.Participations p JOIN dbo.GamesAndEvents e ON e.EventId=p.GameId WHERE p.UserId=@UserId AND e.StartsAt>SYSUTCDATETIME() AND e.HostUserId<>@UserId;
  UPDATE dbo.CourtBookings SET Status='Cancelled',CancelledAt=SYSUTCDATETIME() WHERE UserId=@UserId AND Status IN('Pending','Confirmed') AND StartsAt>SYSUTCDATETIME() AND PaidFromWallet=0;
  IF EXISTS(SELECT 1 FROM dbo.CourtBookings WHERE UserId=@UserId AND Status IN('Pending','Confirmed') AND StartsAt>SYSUTCDATETIME()) THROW 50004,'This user has paid court bookings coming up. Cancel them (refund) first.',1;
  DECLARE @PaidClasses TABLE(ClassId int PRIMARY KEY);
  INSERT @PaidClasses SELECT r.ClassId FROM dbo.ClassRegistrations r JOIN dbo.Classes c ON c.ClassId=r.ClassId WHERE r.UserId=@UserId AND r.Status='Registered' AND c.StartsAt>SYSUTCDATETIME();
  UPDATE r SET Status='Cancelled' FROM dbo.ClassRegistrations r JOIN dbo.Classes c ON c.ClassId=r.ClassId WHERE r.UserId=@UserId AND r.Status<>'Cancelled' AND c.StartsAt>SYSUTCDATETIME();
  DECLARE @Cl int;
  WHILE EXISTS(SELECT 1 FROM @PaidClasses) BEGIN SELECT TOP(1) @Cl=ClassId FROM @PaidClasses; EXEC dbo.ReturnClassCredit @Cl,@UserId; DELETE @PaidClasses WHERE ClassId=@Cl; END;
  -- Erase personal data; keep the anonymous row so bookings, payments and ledgers stay consistent.
  DELETE dbo.UserSportPreferences WHERE UserId=@UserId;
  UPDATE dbo.UserPreferences SET Area=NULL WHERE UserId=@UserId;
  DELETE dbo.Friendships WHERE @UserId IN(UserLow,UserHigh);
  DELETE dbo.PlayerGroupMembers WHERE UserId=@UserId;
  DELETE dbo.ClubStaff WHERE UserId=@UserId;
  DELETE dbo.PaymentOperators WHERE UserId=@UserId;
  UPDATE dbo.Shots SET Hidden=1,Caption=N'' WHERE UserId=@UserId;
  UPDATE dbo.Messages SET Body=N'(message from a deleted account)',BodyCipher=NULL WHERE SenderId=@UserId;
  UPDATE dbo.Users SET AccountStatus='Deleted',DisplayName=N'Deleted user',Email=N'deleted-'+CONVERT(nvarchar(12),@UserId)+N'@gameon.invalid',
   PasswordHash='DISABLED_FIXTURE',Bio=N'',Gender=NULL,DateOfBirth=NULL,StatusReason=TRIM(@Reason),StatusChangedAt=SYSUTCDATETIME(),StatusChangedBy=@AdminId,
   SecurityVersion=SecurityVersion+1,SessionStamp=NEWID() WHERE UserId=@UserId;
  INSERT dbo.AdminAudit(AdminId,Action,TargetUserId,Detail) VALUES(@AdminId,'Delete',@UserId,TRIM(@Reason));
  COMMIT;
  SELECT 'Deleted' AS AccountStatus;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
-- Drop coach objects, the class coach column, commission columns and the Coach staff role.
DROP PROCEDURE IF EXISTS dbo.ListCoaches, dbo.SaveCoachProfile, dbo.SetStaffCommission;
DROP TABLE IF EXISTS dbo.CoachSports, dbo.CoachProfiles;
GO
DECLARE @sql nvarchar(max)=N'';
-- foreign keys, defaults, indexes and checks on the columns being dropped
SELECT @sql+=N'ALTER TABLE dbo.'+QUOTENAME(OBJECT_NAME(fk.parent_object_id))+N' DROP CONSTRAINT '+QUOTENAME(fk.name)+N';'
 FROM sys.foreign_keys fk JOIN sys.foreign_key_columns c ON c.constraint_object_id=fk.object_id
 WHERE fk.parent_object_id=OBJECT_ID('dbo.Classes') AND COL_NAME(c.parent_object_id,c.parent_column_id)='CoachUserId';
SELECT @sql+=N'ALTER TABLE dbo.'+QUOTENAME(OBJECT_NAME(d.parent_object_id))+N' DROP CONSTRAINT '+QUOTENAME(d.name)+N';'
 FROM sys.default_constraints d WHERE (d.parent_object_id=OBJECT_ID('dbo.ClubStaff') AND COL_NAME(d.parent_object_id,d.parent_column_id)='CommissionPct')
  OR (d.parent_object_id=OBJECT_ID('dbo.StaffPay') AND COL_NAME(d.parent_object_id,d.parent_column_id)='Commission');
SELECT @sql+=N'ALTER TABLE dbo.'+QUOTENAME(OBJECT_NAME(k.parent_object_id))+N' DROP CONSTRAINT '+QUOTENAME(k.name)+N';'
 FROM sys.check_constraints k WHERE k.parent_object_id IN(OBJECT_ID('dbo.ClubStaff'),OBJECT_ID('dbo.StaffPay'),OBJECT_ID('dbo.Classes'))
  AND (k.definition LIKE '%Commission%' OR k.definition LIKE '%Coach%');
SELECT @sql+=N'DROP INDEX '+QUOTENAME(i.name)+N' ON dbo.Classes;' FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
 WHERE i.object_id=OBJECT_ID('dbo.Classes') AND COL_NAME(ic.object_id,ic.column_id)='CoachUserId' AND i.is_primary_key=0;
EXEC sp_executesql @sql;
GO
DELETE dbo.ClubStaff WHERE Role='Coach';
ALTER TABLE dbo.ClubStaff ADD CONSTRAINT CK_ClubStaff_Role CHECK(Role IN('Owner','Manager','Reception'));
ALTER TABLE dbo.Classes DROP COLUMN CoachUserId;
ALTER TABLE dbo.ClubStaff DROP COLUMN CommissionPct;
ALTER TABLE dbo.StaffPay DROP COLUMN Commission;
INSERT dbo.PlatformMigrations(Version) VALUES(40);
GO
SELECT 'Migration 40 completed successfully' AS Result;
GO