-- GameOn migration 39: delete the old payments, $1 deposits, wallet, Whish transfers and deposit disputes from the database.
-- Since migration 37 nothing writes to them. Live procedures that still touched them are rewritten first, then the
-- tables, triggers, views and procedures are dropped. Back up the database first (this cannot be undone).
--   sqlcmd -S localhost -E -I -b -i database/39-drop-payments-wallet.sql
-- Kept on purpose: PaymentOperators (it is the operator role), ClubLedger (club finances), and a few now-unused
-- columns on GamesAndEvents / Participations / CourtBookings that other procedures still read.
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET NOEXEC OFF;
-- Safety (added): this migration deletes money tables for good, so it only runs when a FULL backup of this database
-- was taken in the last 24 hours, and it runs as ONE transaction (any error = nothing changes).
IF @@TRANCOUNT<>0 BEGIN RAISERROR('Open a fresh query with no active transaction. Nothing was changed.',16,1); SET NOEXEC ON; END;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=38) BEGIN RAISERROR('Install migration 38 first. Nothing was changed.',16,1); SET NOEXEC ON; END;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=39) BEGIN RAISERROR('Migration 39 is already installed. Nothing was changed.',16,1); SET NOEXEC ON; END;
IF NOT EXISTS(SELECT 1 FROM msdb.dbo.backupset WHERE database_name=DB_NAME() AND type='D' AND backup_finish_date>DATEADD(hour,-24,GETDATE()))
BEGIN RAISERROR('Take a FULL backup of this database first (right-click the database > Tasks > Back Up...). Nothing was changed.',16,1); SET NOEXEC ON; END;
GO
BEGIN TRANSACTION;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

-- ===== 1. Rewrite live procedures without payment logic =====
CREATE OR ALTER PROCEDURE dbo.AdminStats @AdminId int AS
BEGIN
 SET NOCOUNT ON;
 IF dbo.IsAdmin(@AdminId)=0 THROW 50003,'Admins only.',1;
 SELECT (SELECT COUNT(*) FROM dbo.Users WHERE AccountStatus='Active' AND PasswordHash<>'DISABLED_FIXTURE') AS ActiveUsers,
  (SELECT COUNT(*) FROM dbo.Users WHERE AccountStatus='Suspended') AS SuspendedUsers,
  (SELECT COUNT(*) FROM dbo.Users WHERE CreatedAt>DATEADD(day,-7,SYSUTCDATETIME()) AND PasswordHash<>'DISABLED_FIXTURE') AS NewUsers7d,
  (SELECT COUNT(*) FROM dbo.Users WHERE LastLoginAt>DATEADD(day,-7,SYSUTCDATETIME())) AS ActiveLast7d,
  (SELECT COUNT(*) FROM dbo.GamesAndEvents WHERE GameStatus='Open' AND StartsAt>SYSUTCDATETIME()) AS UpcomingGames,
  (SELECT COUNT(*) FROM dbo.CourtBookings WHERE Status IN('Confirmed','Pending') AND StartsAt>SYSUTCDATETIME()) AS UpcomingCourtBookings,
  (SELECT COUNT(*) FROM dbo.Clubs WHERE IsActive=1) AS Clubs,
  (SELECT COUNT(*) FROM dbo.Clubs WHERE IsActive=1 AND IsSelfListed=1) AS SelfListedVenues,
  (SELECT COUNT(DISTINCT UserId) FROM dbo.Memberships WHERE StartsAt<=SYSUTCDATETIME() AND EndsAt>SYSUTCDATETIME()) AS PremiumMembers,
  (SELECT COUNT(DISTINCT ShotId) FROM dbo.ShotReports r WHERE EXISTS(SELECT 1 FROM dbo.Shots s WHERE s.ShotId=r.ShotId AND s.Hidden=0)) AS ReportedShots;
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

CREATE OR ALTER PROCEDURE dbo.AdminListUsers @AdminId int,@Query nvarchar(100)=NULL,@Status varchar(10)=NULL AS
BEGIN
 SET NOCOUNT ON;
 IF dbo.IsAdmin(@AdminId)=0 THROW 50003,'Admins only.',1;
 DECLARE @Q nvarchar(100)=NULLIF(TRIM(@Query),N'');
 SELECT TOP(200) u.UserId,u.DisplayName,u.Email,u.CreatedAt,u.LastLoginAt,u.AccountStatus,u.StatusReason,
  dbo.IsAdmin(u.UserId) AS IsAdmin,CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.PaymentOperators o WHERE o.UserId=u.UserId) THEN 1 ELSE 0 END AS bit) AS IsOperator,
  CAST(dbo.IsPro(u.UserId) AS bit) AS IsPro,
  (SELECT COUNT(*) FROM dbo.GamesAndEvents g WHERE g.HostUserId=u.UserId) AS GamesHosted,
  (SELECT COUNT(*) FROM dbo.Participations p WHERE p.UserId=u.UserId) AS GamesJoined,
  (SELECT COUNT(*) FROM dbo.ShotReports r JOIN dbo.Shots s ON s.ShotId=r.ShotId WHERE s.UserId=u.UserId) AS ReportsAgainst,
  (SELECT STRING_AGG(c.Name+N' ('+s.Role+N')',N', ') FROM dbo.ClubStaff s JOIN dbo.Clubs c ON c.ClubId=s.ClubId WHERE s.UserId=u.UserId) AS Clubs
 FROM dbo.Users u
 WHERE u.PasswordHash<>'DISABLED_FIXTURE' AND (@Status IS NULL OR u.AccountStatus=@Status)
  AND (@Q IS NULL OR CHARINDEX(@Q,u.DisplayName)>0 OR CHARINDEX(@Q,u.Email)>0 OR CONVERT(nvarchar(12),u.UserId)=@Q)
 ORDER BY u.UserId DESC;
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

-- Cancelling / declining a court booking: give back points and reward codes (no money is held in the app).
CREATE OR ALTER PROCEDURE dbo.ReleaseCourtBooking @BookingId bigint,@NewStatus varchar(10),@ActorId int AS
BEGIN
 SET NOCOUNT ON;
 -- Caller owns the transaction and the booking lock.
 DECLARE @Owner int=(SELECT UserId FROM dbo.CourtBookings WHERE BookingId=@BookingId);
 UPDATE dbo.CourtBookings SET Status=@NewStatus,CancelledAt=IIF(@NewStatus='Cancelled',SYSUTCDATETIME(),CancelledAt),DecidedBy=IIF(@NewStatus='Declined',@ActorId,DecidedBy),DecidedAt=IIF(@NewStatus='Declined',SYSUTCDATETIME(),DecidedAt) WHERE BookingId=@BookingId;
 DECLARE @Earned int=(SELECT Points FROM dbo.LoyaltyLedger WHERE Reason='CourtBooking' AND RefType='Booking' AND RefId=@BookingId AND UserId=@Owner);
 IF @Owner IS NOT NULL AND @Earned>0 BEGIN SET @Earned=-@Earned; EXEC dbo.LoyaltyPost @Owner,@Earned,'Reversal','Booking',@BookingId,N'Court booking cancelled'; END;
 UPDATE x SET Status='Issued',UsedAt=NULL FROM dbo.RewardRedemptions x JOIN dbo.CourtBookings b ON b.RedemptionId=x.RedemptionId WHERE b.BookingId=@BookingId AND x.ExpiresAt>SYSUTCDATETIME();
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

-- Leaving a game: free the place and promote the first player on the waitlist.
CREATE OR ALTER PROCEDURE dbo.CancelParticipation @GameId int,@UserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int,@Start datetime2(3),@Status varchar(12),@Host int,@NextUser int,@Waitlist bigint;
  SELECT @Id=EventId,@Start=StartsAt,@Status=GameStatus,@Host=HostUserId FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Id IS NULL THROW 50001,'Event not found.',1;
  IF @Start<=SYSUTCDATETIME() OR @Status<>'Open' THROW 50002,'Event is no longer open.',1;
  IF @UserId=@Host THROW 50002,'Hosts cannot leave their own game. Cancel the game instead.',1;
  DELETE dbo.Participations WHERE GameId=@GameId AND UserId=@UserId;
  IF @@ROWCOUNT=1
  BEGIN
   DELETE dbo.SponsoredSeats WHERE GameId=@GameId AND UserId=@UserId;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@UserId,'Cancelled');
   SELECT TOP(1) @NextUser=UserId,@Waitlist=WaitlistId FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
   IF @NextUser IS NOT NULL
   BEGIN
    DELETE dbo.Waitlists WHERE WaitlistId=@Waitlist;
    INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@GameId,@NextUser,'Cash');
    INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@NextUser,'Promoted');
    INSERT dbo.Notifications(UserId,GameId,Title,Body)
    VALUES(@NextUser,@GameId,N'A place opened. You are in!',N'You moved from the waitlist to the roster.');
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
 BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

CREATE OR ALTER PROCEDURE dbo.CancelGame @GameId int,@HostUserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Owner int,@Status varchar(12),@Start datetime2(3);
  SELECT @Owner=HostUserId,@Status=GameStatus,@Start=StartsAt FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@GameId;
  IF @Owner IS NULL THROW 50001,'Game not found.',1;
  IF @Owner<>@HostUserId THROW 50003,'Only the host can cancel this game.',1;
  IF @Status='Open'
  BEGIN
   IF @Start<=SYSUTCDATETIME() THROW 50002,'This game has already started.',1;
   UPDATE dbo.GamesAndEvents SET GameStatus='Cancelled',Revision=Revision+1 WHERE EventId=@GameId;
   INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,'GameCancelled');
   INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT m.UserId,@GameId,N'Game cancelled',N'The host cancelled your game. Find another game in Discover.'
   FROM (SELECT UserId FROM dbo.Participations WHERE GameId=@GameId UNION SELECT UserId FROM dbo.Waitlists WHERE GameId=@GameId) m
   WHERE m.UserId<>@HostUserId;
  END;
  COMMIT;
 END TRY
 BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
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
  -- Avoid silently changing what players agreed to pay the host.
  IF (@OldCost<>@CostPerPlayer OR @OldCurrency<>@Currency) AND
   (EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@GameId AND UserId<>@HostUserId) OR EXISTS(SELECT 1 FROM dbo.Waitlists WHERE GameId=@GameId))
   THROW 50002,'Price and currency cannot change after other players join.',1;
  UPDATE dbo.Games SET StartsAt=@StartsAt,Capacity=@Capacity,Description=@Description,CostPerPlayer=@CostPerPlayer,
   Currency=@Currency,SponsoredSlots=@SponsoredSlots,Revision=Revision+1 WHERE GameId=@GameId;
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) VALUES(@GameId,@HostUserId,'Edited');
  -- Increasing capacity fills newly available places in FIFO order.
  DECLARE @Open int=@Capacity-(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@GameId);
  DECLARE @Promoted TABLE(UserId int PRIMARY KEY,WaitlistId bigint);
  INSERT @Promoted(UserId,WaitlistId) SELECT TOP(@Open) UserId,WaitlistId FROM dbo.Waitlists WHERE GameId=@GameId ORDER BY WaitlistId;
  DELETE w FROM dbo.Waitlists w JOIN @Promoted p ON p.WaitlistId=w.WaitlistId;
  INSERT dbo.Participations(GameId,UserId,PaymentMethod) SELECT @GameId,UserId,'Cash' FROM @Promoted;
  INSERT dbo.GameActivityLogs(GameId,ActorUserId,ActivityType) SELECT @GameId,UserId,'Promoted' FROM @Promoted;
  INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT UserId,@GameId,N'A place opened. You are in!',N'The host opened more places and you moved from the waitlist to the roster.' FROM @Promoted;
  INSERT dbo.Notifications(UserId,GameId,Title,Body)
   SELECT UserId,@GameId,N'Your game was updated',N'The host changed the game details. Review the time and information before playing.'
   FROM (SELECT UserId FROM dbo.Participations WHERE GameId=@GameId UNION SELECT UserId FROM dbo.Waitlists WHERE GameId=@GameId) members
   WHERE UserId<>@HostUserId;
  COMMIT;
 END TRY
 BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
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
  DELETE dbo.CoachSports WHERE UserId=@UserId;
  DELETE dbo.CoachProfiles WHERE UserId=@UserId;
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
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

CREATE OR ALTER PROCEDURE dbo.AdminAnalytics @AdminId int,@Months int=12 AS
BEGIN
 SET NOCOUNT ON;
 IF dbo.IsAdmin(@AdminId)=0 THROW 50003,'Admins only.',1;
 IF @Months IS NULL OR @Months NOT BETWEEN 1 AND 36 SET @Months=12;
 DECLARE @Now datetime2(3)=SYSUTCDATETIME();
 DECLARE @From datetime2(3)=DATEADD(month,1-@Months,DATEFROMPARTS(YEAR(@Now),MONTH(@Now),1));
 DECLARE @MinGroup int=5; -- privacy: age/gender groups with fewer players are hidden
 -- Every booking activity in the period: court bookings that were kept, and players joining games.
 CREATE TABLE #Act(Kind varchar(5) NOT NULL,UserId int NOT NULL,At datetime2(3) NOT NULL,SubtypeId int NULL,ClubId int NULL,Value decimal(12,2) NOT NULL,NoShow bit NOT NULL);
 INSERT #Act SELECT 'Court',b.UserId,b.StartsAt,c.SubtypeId,c.ClubId,b.Price,IIF(b.Status='NoShow',1,0)
 FROM dbo.CourtBookings b JOIN dbo.Courts c ON c.CourtId=b.CourtId
 WHERE b.StartsAt>=@From AND b.StartsAt<@Now AND b.Status IN('Confirmed','Completed','NoShow') AND b.UserId IS NOT NULL;
 INSERT #Act SELECT 'Game',p.UserId,g.StartsAt,g.SubtypeId,NULL,g.CostPerPlayer,0
 FROM dbo.Participations p JOIN dbo.GamesAndEvents g ON g.EventId=p.GameId
 WHERE g.StartsAt>=@From AND g.StartsAt<@Now AND g.GameStatus<>'Cancelled' AND p.UserId<>g.HostUserId;
 CREATE TABLE #U(UserId int PRIMARY KEY,AgeGroup varchar(12) NOT NULL,AgeOrder tinyint NOT NULL,Gender varchar(20) NOT NULL);
 INSERT #U SELECT u.UserId,
  CASE WHEN x.Age IS NULL THEN 'Not given' WHEN x.Age<18 THEN 'Under 18' WHEN x.Age<25 THEN '18-24' WHEN x.Age<35 THEN '25-34' WHEN x.Age<45 THEN '35-44' ELSE '45+' END,
  CASE WHEN x.Age IS NULL THEN 9 WHEN x.Age<18 THEN 1 WHEN x.Age<25 THEN 2 WHEN x.Age<35 THEN 3 WHEN x.Age<45 THEN 4 ELSE 5 END,
  CASE u.Gender WHEN 'Female' THEN 'Female' WHEN 'Male' THEN 'Male' WHEN 'NonBinary' THEN 'Non-binary' ELSE 'Not given' END
 FROM dbo.Users u CROSS APPLY(SELECT DATEDIFF(year,u.DateOfBirth,@Now)-IIF(DATEADD(year,DATEDIFF(year,u.DateOfBirth,@Now),u.DateOfBirth)>@Now,1,0) AS Age) x
 WHERE u.UserId IN(SELECT DISTINCT UserId FROM #Act);
 -- 1. Month by month: activity, value booked at clubs, GameOn's own income, sign-ups (one grouped pass per source).
 CREATE TABLE #M(MonthStart date PRIMARY KEY);
 INSERT #M SELECT TOP(@Months) DATEADD(month,ROW_NUMBER() OVER(ORDER BY (SELECT 1))-1,CONVERT(date,@From)) FROM sys.all_objects;
 SELECT FORMAT(m.MonthStart,'yyyy-MM') AS Month,COALESCE(a.CourtBookings,0) AS CourtBookings,COALESCE(a.GameJoins,0) AS GameJoins,
  COALESCE(a.CourtValue,0) AS CourtValue,COALESCE(f.Fees,0) AS PlatformFees,COALESCE(p.Pro,0) AS ProSales,COALESCE(n.NewUsers,0) AS NewUsers
 FROM #M m
 LEFT JOIN (SELECT DATEFROMPARTS(YEAR(At),MONTH(At),1) AS M,SUM(IIF(Kind='Court',1,0)) AS CourtBookings,SUM(IIF(Kind='Game',1,0)) AS GameJoins,SUM(IIF(Kind='Court',Value,0)) AS CourtValue
  FROM #Act GROUP BY DATEFROMPARTS(YEAR(At),MONTH(At),1)) a ON a.M=m.MonthStart
 LEFT JOIN (SELECT DATEFROMPARTS(YEAR(StartsAt),MONTH(StartsAt),1) AS M,SUM(PlatformFee) AS Fees FROM dbo.CourtBookings WHERE StartsAt>=@From AND StartsAt<@Now AND Status IN('Confirmed','Completed')
  GROUP BY DATEFROMPARTS(YEAR(StartsAt),MONTH(StartsAt),1)) f ON f.M=m.MonthStart
 LEFT JOIN (SELECT DATEFROMPARTS(YEAR(CreatedAt),MONTH(CreatedAt),1) AS M,SUM(PricePaid) AS Pro FROM dbo.Memberships WHERE CreatedAt>=@From
  GROUP BY DATEFROMPARTS(YEAR(CreatedAt),MONTH(CreatedAt),1)) p ON p.M=m.MonthStart
 LEFT JOIN (SELECT DATEFROMPARTS(YEAR(CreatedAt),MONTH(CreatedAt),1) AS M,COUNT(*) AS NewUsers FROM dbo.Users WHERE CreatedAt>=@From AND PasswordHash<>N'DISABLED_FIXTURE'
  GROUP BY DATEFROMPARTS(YEAR(CreatedAt),MONTH(CreatedAt),1)) n ON n.M=m.MonthStart
 ORDER BY m.MonthStart;
 -- 2. By age group and 3. by gender (counts hidden when fewer than @MinGroup players).
 SELECT u.AgeGroup AS [Group],IIF(COUNT(DISTINCT a.UserId)<@MinGroup,NULL,COUNT(*)) AS Bookings,IIF(COUNT(DISTINCT a.UserId)<@MinGroup,NULL,COUNT(DISTINCT a.UserId)) AS Players
 FROM #Act a JOIN #U u ON u.UserId=a.UserId GROUP BY u.AgeGroup,u.AgeOrder ORDER BY u.AgeOrder;
 SELECT u.Gender AS [Group],IIF(COUNT(DISTINCT a.UserId)<@MinGroup,NULL,COUNT(*)) AS Bookings,IIF(COUNT(DISTINCT a.UserId)<@MinGroup,NULL,COUNT(DISTINCT a.UserId)) AS Players
 FROM #Act a JOIN #U u ON u.UserId=a.UserId GROUP BY u.Gender ORDER BY COUNT(*) DESC;
 -- 4. By sport.
 SELECT s.Name AS Sport,SUM(IIF(a.Kind='Court',1,0)) AS CourtBookings,SUM(IIF(a.Kind='Game',1,0)) AS GameJoins,SUM(IIF(a.Kind='Court',a.Value,0)) AS CourtValue
 FROM #Act a JOIN dbo.Subtypes s ON s.SubtypeId=a.SubtypeId GROUP BY s.Name ORDER BY COUNT(*) DESC;
 -- 5. By hour of day in Beirut (peak-price planning).
 -- Group by UTC day+hour first, then convert each group once (time-zone conversion per row is slow).
 SELECT DATEPART(hour,dbo.ToBeirut(g.H)) AS Hour,SUM(g.N) AS Bookings
 FROM (SELECT DATEADD(hour,DATEPART(hour,At),CONVERT(datetime2(3),CONVERT(date,At))) AS H,COUNT(*) AS N FROM #Act GROUP BY CONVERT(date,At),DATEPART(hour,At)) g
 GROUP BY DATEPART(hour,dbo.ToBeirut(g.H)) ORDER BY Hour;
 -- 6. Health of the marketplace.
 SELECT
  (SELECT COUNT(*) FROM dbo.CourtBookings b WHERE b.StartsAt>=@From AND b.StartsAt<@Now) AS CourtBookingsAll,
  (SELECT COUNT(*) FROM dbo.CourtBookings b WHERE b.StartsAt>=@From AND b.StartsAt<@Now AND b.Status='Cancelled') AS CourtCancelled,
  (SELECT COUNT(*) FROM #Act WHERE NoShow=1) AS NoShows,
  (SELECT COUNT(DISTINCT UserId) FROM #Act) AS ActivePlayers,
  (SELECT COUNT(*) FROM (SELECT UserId FROM #Act GROUP BY UserId HAVING COUNT(*)>=2) r) AS RepeatPlayers;
 -- 7. Top clubs by value booked.
 SELECT TOP(10) c.Name AS Club,COUNT(*) AS Bookings,SUM(a.Value) AS CourtValue,SUM(CONVERT(int,a.NoShow)) AS NoShows
 FROM #Act a JOIN dbo.Clubs c ON c.ClubId=a.ClubId WHERE a.Kind='Court' GROUP BY c.Name ORDER BY SUM(a.Value) DESC;
END;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO

-- ===== 2. Drop everything that only served payments / deposits / wallet / disputes =====
DECLARE @sql nvarchar(max)=N'';
-- Triggers and view first
SELECT @sql+=N'DROP TRIGGER dbo.'+QUOTENAME(name)+N';' FROM sys.triggers WHERE parent_class=1 AND OBJECT_NAME(parent_id) IN
 ('WalletAccounts','WalletLedger','WalletTopUps','WalletWithdrawals','DepositBookings','DepositDisputes','DepositReviews','Payments','PaymentReviews','PaymentWebhookEvents','VerifiedWhishTransfers');
IF OBJECT_ID('dbo.WalletLedgerTotals','V') IS NOT NULL SET @sql+=N'DROP VIEW dbo.WalletLedgerTotals;';
-- Procedures (payment flows, wallet, deposits, attendance-for-deposit and disputes)
SELECT @sql+=N'DROP PROCEDURE dbo.'+QUOTENAME(name)+N';' FROM sys.procedures WHERE name IN
 ('ApplyMockPaymentWebhook','BuyPro','CancelTopUp','CheckWalletIntegrity','ConfirmAttendance','CreateTopUp','EvaluateAttendance','GetDepositBooking','GetDepositQuote',
  'GetGameTrust','GetMyDeposits','GetMyPayments','GetPayment','GetPaymentQuote','GetWallet','InitializeCheckout','InitializeDeposit','JoinWithWallet','ListDepositReviews',
  'ListDisputes','ListWalletReviews','ListWhishReviews','OpenDispute','OpenDisputeInternal','RequestWithdrawal','ResolveDispute','ReviewDeposit','ReviewTopUp',
  'ReviewWhishTransfer','ReviewWithdrawal','SettleWalletDepositRefunds','SubmitDepositTransfer','SubmitTopUpReference','SubmitWhishTransfer','WalletDebit','WalletPost',
  'RefreshDepositEvent','SubmitAttendance','HoldHost');
EXEC sp_executesql @sql;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO
-- Tables, children before parents (foreign keys)
DROP TABLE IF EXISTS dbo.WalletLedger, dbo.WalletTopUps, dbo.WalletWithdrawals, dbo.WalletAccounts,
 dbo.DepositReviews, dbo.DepositDisputes, dbo.DepositBookings,
 dbo.PaymentWebhookEvents, dbo.PaymentReviews, dbo.VerifiedWhishTransfers, dbo.Payments;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO
IF OBJECT_ID('dbo.PlatformServiceFee') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM sys.sql_expression_dependencies WHERE referenced_entity_name='PlatformServiceFee')
 DROP FUNCTION dbo.PlatformServiceFee;
GO
IF @@TRANCOUNT=0 SET NOEXEC ON; -- an earlier step failed: skip the rest
GO
INSERT dbo.PlatformMigrations(Version) VALUES(39);
GO
IF @@TRANCOUNT>0 COMMIT;
GO
-- Anything (only reached when everything above succeeded) left that still points at a dropped table would fail at run time: list it.
SELECT o.name AS StillReferencesDroppedObject, d.referenced_entity_name AS Missing
FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id=d.referencing_id
WHERE d.referenced_id IS NULL AND d.referenced_entity_name IN ('WalletAccounts','WalletLedger','WalletTopUps','WalletWithdrawals','DepositBookings','DepositDisputes',
 'DepositReviews','Payments','PaymentReviews','PaymentWebhookEvents','VerifiedWhishTransfers','WalletDebit','WalletPost','RefreshDepositEvent','SettleWalletDepositRefunds',
 'EvaluateAttendance','OpenDisputeInternal','PlatformServiceFee');
SELECT 'Migration 39 completed successfully' AS Result;
GO
SET NOEXEC OFF;
GO
