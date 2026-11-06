-- Acceptance tests for migration 22. DISPOSABLE DATABASE ONLY (name must end in _Tests).
-- Example: restore a COPY_ONLY backup of GameOn as GameOn_Tests, apply migration 22 there, then:
--   sqlcmd -S localhost -E -C -b -d GameOn_Tests -i database\23-deposit-lifecycle-tests.sql
-- Creates fixture users/games (marked @gameon.invalid). Never run on your real database.
SET NOCOUNT ON; SET XACT_ABORT OFF;
IF DB_NAME() NOT LIKE N'%[_]Tests' THROW 50002,'Run these tests only on a disposable *_Tests database.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=22) THROW 50002,'Apply migration 22 to this test database first.',1;
DECLARE @tag nvarchar(12)=LEFT(REPLACE(CONVERT(nvarchar(36),NEWID()),'-',''),10);
DECLARE @H int,@P1 int,@P2 int,@P3 int,@O int,@V int,@G int,@G2 int,@G3 int,@Rev int,@D1 uniqueidentifier,@D2 uniqueidentifier,@D3 uniqueidentifier,@D4 uniqueidentifier,@D5 uniqueidentifier;
DECLARE @t TABLE(Name nvarchar(200),Pass bit);
DECLARE @TXA nvarchar(40)=N'TX-A-'+@tag,@TXB nvarchar(40)=N'TX-B-'+@tag,@TXC nvarchar(40)=N'TX-C-'+@tag,@TXD nvarchar(40)=N'TX-D-'+@tag,@RF1 nvarchar(40)=N'RF-1-'+@tag,@RF9 nvarchar(40)=N'RF-9-'+@tag,@RF2 nvarchar(40)=N'RF-2-'+@tag;
DECLARE @ok bit,@future datetime2(3)=DATEADD(day,3,SYSUTCDATETIME());
DECLARE @sink TABLE(x sql_variant);
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('h'+@tag+'@gameon.invalid','Test host','DISABLED_FIXTURE'); SET @H=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('p1'+@tag+'@gameon.invalid','Test P1','DISABLED_FIXTURE'); SET @P1=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('p2'+@tag+'@gameon.invalid','Test P2','DISABLED_FIXTURE'); SET @P2=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('p3'+@tag+'@gameon.invalid','Test P3','DISABLED_FIXTURE'); SET @P3=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('op'+@tag+'@gameon.invalid','Test operator','DISABLED_FIXTURE'); SET @O=SCOPE_IDENTITY();
INSERT dbo.PaymentOperators(UserId) VALUES(@O);
INSERT dbo.Venues(Name,Area,Address,ContactPhoneNumber,IsVerified,ListingStatus) VALUES(N'Test venue '+@tag,N'Testville',N'Test address','+96100000000',1,'Unverified'); SET @V=SCOPE_IDENTITY();
INSERT dbo.VenueSubtypes(VenueId,SubtypeId) SELECT TOP(1) @V,SubtypeId FROM dbo.Subtypes;
DECLARE @Sport int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes ORDER BY SubtypeId);
DECLARE @ids TABLE(id int);
INSERT @ids EXEC dbo.CreateGame @HostUserId=@H,@SportId=@Sport,@VenueId=@V,@StartsAt=@future,@Capacity=4,@CostPerPlayer=2; SELECT @G=id FROM @ids; DELETE @ids;
SELECT @Rev=Revision FROM dbo.GamesAndEvents WHERE EventId=@G;
-- Helper pattern: deposit for player, submit reference, operator verifies.
DECLARE @k uniqueidentifier=NEWID();
DECLARE @dep TABLE(DepositId uniqueidentifier,GameId int,b1 sql_variant,b2 sql_variant,b3 sql_variant,b4 sql_variant,b5 sql_variant,b6 sql_variant,b7 sql_variant,b8 sql_variant,b9 sql_variant,b10 sql_variant,b11 sql_variant,b12 sql_variant,b13 sql_variant,b14 sql_variant,b15 sql_variant,b16 sql_variant,b17 sql_variant,b18 sql_variant,b19 sql_variant);
INSERT @dep EXEC dbo.InitializeDeposit @GameId=@G,@UserId=@P1,@Revision=@Rev,@Key=@k; SELECT @D1=DepositId FROM @dep; DELETE @dep;
-- Same idempotency key twice returns the same deposit (no duplicate charge record).
INSERT @dep EXEC dbo.InitializeDeposit @GameId=@G,@UserId=@P1,@Revision=@Rev,@Key=@k;
INSERT @t SELECT 'Idempotent checkout returns same deposit',CASE WHEN (SELECT DepositId FROM @dep)=@D1 AND (SELECT COUNT(*) FROM dbo.DepositBookings WHERE GameId=@G AND UserId=@P1)=1 THEN 1 ELSE 0 END; DELETE @dep;
INSERT @dep EXEC dbo.SubmitDepositTransfer @DepositID=@D1,@UserId=@P1,@Reference=@TXA; DELETE @dep;
INSERT @t SELECT 'Submitted reference stays PENDING (not proof of payment)',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='PENDING' THEN 1 ELSE 0 END;
INSERT @dep EXEC dbo.ReviewDeposit @DepositID=@D1,@UserId=@O,@Decision='VERIFY',@Note=N'Matched statement'; DELETE @dep;
INSERT @t SELECT 'Operator verification holds deposit and seats player',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='PAID_HELD' AND EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@G AND UserId=@P1) THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D1,@UserId=@O,@Decision='VERIFY',@Note=N'again'; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @dep;
INSERT @t VALUES('Second verification rejected',@ok);
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D1,@UserId=@P1,@Decision='VERIFY',@Note=N'self'; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50003 THEN 1 ELSE 0 END; END CATCH; DELETE @dep;
INSERT @t VALUES('Non-operator cannot review',@ok);
-- Reused transfer reference cannot authorize a second booking.
SET @k=NEWID(); INSERT @dep EXEC dbo.InitializeDeposit @GameId=@G,@UserId=@P2,@Revision=@Rev,@Key=@k; SELECT @D2=DepositId FROM @dep; DELETE @dep;
INSERT @dep EXEC dbo.SubmitDepositTransfer @DepositID=@D2,@UserId=@P2,@Reference=@TXA; DELETE @dep;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D2,@UserId=@O,@Decision='VERIFY',@Note=N'reuse'; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @dep;
INSERT @t VALUES('Reused transfer reference blocked',@ok);
INSERT @dep EXEC dbo.ReviewDeposit @DepositID=@D2,@UserId=@O,@Decision='REJECT',@Note=N'Reference already used'; DELETE @dep;
SET @k=NEWID(); INSERT @dep EXEC dbo.InitializeDeposit @GameId=@G,@UserId=@P2,@Revision=@Rev,@Key=@k; SELECT @D2=DepositId FROM @dep; DELETE @dep;
INSERT @dep EXEC dbo.SubmitDepositTransfer @DepositID=@D2,@UserId=@P2,@Reference=@TXB; DELETE @dep;
INSERT @dep EXEC dbo.ReviewDeposit @DepositID=@D2,@UserId=@O,@Decision='VERIFY',@Note=N'Matched'; DELETE @dep;
-- Player leaves: no automatic refund or forfeiture.
EXEC dbo.CancelParticipation @GameId=@G,@UserId=@P2;
INSERT @t SELECT 'Player leaving keeps deposit held for policy review',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D2)='PAID_HELD' AND (SELECT PlayerLeftAt FROM dbo.DepositBookings WHERE DepositID=@D2) IS NOT NULL THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D2,@UserId=@O,@Decision='FORFEIT',@Note=N'no show'; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @dep;
INSERT @t VALUES('Forfeiture disabled until policy approved',@ok);
SET @ok=0; BEGIN TRY EXEC dbo.CancelParticipation @GameId=@G,@UserId=@H; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Host cannot leave own game (must cancel)',@ok);
-- Attendance before start rejected.
SET @ok=0; BEGIN TRY EXEC dbo.ConfirmAttendance @GameId=@G,@UserId=@P1,@Mark='Attended'; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Attendance before start rejected',@ok);
-- Simulate the game having started.
UPDATE dbo.GamesAndEvents SET StartsAt=DATEADD(hour,-2,SYSUTCDATETIME()) WHERE EventId=@G;
EXEC dbo.ConfirmAttendance @GameId=@G,@UserId=@P1,@Mark='Attended';
INSERT @t SELECT 'Player confirmation alone does not refund',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='PAID_HELD' THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.SubmitAttendance @GameId=@G,@HostUserId=@P1,@Outcome='Played',@MarksJson=N'[]'; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50003 THEN 1 ELSE 0 END; END CATCH;
INSERT @t VALUES('Only host can report completion',@ok);
DECLARE @marks nvarchar(200)=N'[{"userId":'+CONVERT(nvarchar,@P1)+N',"mark":"Attended"}]';
EXEC dbo.SubmitAttendance @GameId=@G,@HostUserId=@H,@Outcome='Played',@MarksJson=@marks;
INSERT @t SELECT 'Host + player agreement queues refund (not refunded)',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='REFUND_PENDING' THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.SubmitAttendance @GameId=@G,@HostUserId=@H,@Outcome='Played',@MarksJson=@marks; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Completion cannot be reported twice',@ok);
INSERT @dep EXEC dbo.ReviewDeposit @DepositID=@D1,@UserId=@O,@Decision='REFUND',@Note=N'Sent back via Whish',@RefundReference=@RF1; DELETE @dep;
INSERT @t SELECT 'Refund recorded with reference and time',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='REFUNDED' AND (SELECT RefundedAt FROM dbo.DepositBookings WHERE DepositID=@D1) IS NOT NULL THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D1,@UserId=@O,@Decision='REFUND',@Note=N'again',@RefundReference=@RF9; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @dep;
INSERT @t VALUES('Duplicate refund of same deposit blocked',@ok);
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D2,@UserId=@O,@Decision='REFUND',@Note=N'reuse ref',@RefundReference=@RF1; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @dep;
INSERT @t VALUES('Refund reference cannot be reused',@ok);
-- Refund not received -> dispute -> refund owed again.
EXEC dbo.OpenDispute @GameId=@G,@UserId=@P1,@Reason='RefundNotReceived',@Details=N'Nothing arrived in my Whish account.';
INSERT @t SELECT 'Refund-failure dispute marks deposit DISPUTED',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='DISPUTED' THEN 1 ELSE 0 END;
DECLARE @X bigint=(SELECT DisputeId FROM dbo.DepositDisputes WHERE DepositID=@D1 AND Status='Open');
EXEC dbo.ResolveDispute @DisputeId=@X,@UserId=@O,@Outcome='RefundOwed',@Note=N'Statement shows the refund bounced';
INSERT @t SELECT 'Resolved dispute requeues refund',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D1)='REFUND_PENDING' AND (SELECT RefundReference FROM dbo.DepositBookings WHERE DepositID=@D1) IS NULL THEN 1 ELSE 0 END;
-- Host cancels a future game: held deposits queue for refund.
INSERT @ids EXEC dbo.CreateGame @HostUserId=@H,@SportId=@Sport,@VenueId=@V,@StartsAt=@future,@Capacity=4; SELECT @G2=id FROM @ids; DELETE @ids;
SELECT @Rev=Revision FROM dbo.GamesAndEvents WHERE EventId=@G2;
SET @k=NEWID(); INSERT @dep EXEC dbo.InitializeDeposit @GameId=@G2,@UserId=@P3,@Revision=@Rev,@Key=@k; SELECT @D3=DepositId FROM @dep; DELETE @dep;
INSERT @dep EXEC dbo.SubmitDepositTransfer @DepositID=@D3,@UserId=@P3,@Reference=@TXC; DELETE @dep;
INSERT @dep EXEC dbo.ReviewDeposit @DepositID=@D3,@UserId=@O,@Decision='VERIFY',@Note=N'Matched'; DELETE @dep;
EXEC dbo.CancelGame @GameId=@G2,@HostUserId=@H;
INSERT @t SELECT 'Host cancellation queues refund',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D3)='REFUND_PENDING' THEN 1 ELSE 0 END;
-- Attendance mismatch opens a dispute automatically.
INSERT @ids EXEC dbo.CreateGame @HostUserId=@H,@SportId=@Sport,@VenueId=@V,@StartsAt=@future,@Capacity=4; SELECT @G3=id FROM @ids; DELETE @ids;
SELECT @Rev=Revision FROM dbo.GamesAndEvents WHERE EventId=@G3;
SET @k=NEWID(); INSERT @dep EXEC dbo.InitializeDeposit @GameId=@G3,@UserId=@P3,@Revision=@Rev,@Key=@k; SELECT @D4=DepositId FROM @dep; DELETE @dep;
INSERT @dep EXEC dbo.SubmitDepositTransfer @DepositID=@D4,@UserId=@P3,@Reference=@TXD; DELETE @dep;
INSERT @dep EXEC dbo.ReviewDeposit @DepositID=@D4,@UserId=@O,@Decision='VERIFY',@Note=N'Matched'; DELETE @dep;
UPDATE dbo.GamesAndEvents SET StartsAt=DATEADD(hour,-2,SYSUTCDATETIME()) WHERE EventId=@G3;
SET @marks=N'[{"userId":'+CONVERT(nvarchar,@P3)+N',"mark":"NoShow"}]';
EXEC dbo.SubmitAttendance @GameId=@G3,@HostUserId=@H,@Outcome='Played',@MarksJson=@marks;
INSERT @t SELECT 'Host no-show mark alone does not forfeit',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D4)='PAID_HELD' THEN 1 ELSE 0 END;
EXEC dbo.ConfirmAttendance @GameId=@G3,@UserId=@P3,@Mark='Attended';
INSERT @t SELECT 'Attendance mismatch opens dispute',CASE WHEN (SELECT DepositStatus FROM dbo.DepositBookings WHERE DepositID=@D4)='DISPUTED' AND EXISTS(SELECT 1 FROM dbo.DepositDisputes WHERE DepositID=@D4 AND Reason='AttendanceMismatch' AND Status='Open') THEN 1 ELSE 0 END;
SET @ok=0; BEGIN TRY EXEC dbo.ReviewDeposit @DepositID=@D4,@UserId=@O,@Decision='REFUND',@Note=N'skip',@RefundReference=@RF2; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @dep;
INSERT @t VALUES('Disputed deposit cannot be refunded before resolution',@ok);
-- Host fraud hold.
EXEC dbo.SetHostHold @UserId=@O,@HostUserId=@H,@Hold=1,@Reason=N'Multiple no-show reports';
SET @ok=0; BEGIN TRY EXEC dbo.CreateGame @HostUserId=@H,@SportId=@Sport,@VenueId=@V,@StartsAt=@future,@Capacity=4; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50003 THEN 1 ELSE 0 END; END CATCH; DELETE @ids;
INSERT @t VALUES('Held host cannot create games',@ok);
SET @ok=0; BEGIN TRY EXEC dbo.SetHostHold @UserId=@H,@HostUserId=@H,@Hold=0,@Reason=N'self release'; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Host cannot release own hold',@ok);
-- Venue directory rules.
SET @ok=0; BEGIN TRY EXEC dbo.AddDirectoryVenue @UserId=@O,@Name=N'X',@Area=N'Y',@Address=N'Z',@SportsJson=N'[1]',@ListingStatus='Verified'; END TRY BEGIN CATCH SET @ok=1; END CATCH; DELETE @ids;
INSERT @t VALUES('Verified listing requires source and date',@ok);
SET @ok=0; BEGIN TRY EXEC dbo.AddDirectoryVenue @UserId=@P1,@Name=N'X',@Area=N'Y',@Address=N'Z',@SportsJson=N'[1]'; END TRY BEGIN CATCH SET @ok=CASE WHEN ERROR_NUMBER()=50003 THEN 1 ELSE 0 END; END CATCH; DELETE @ids;
INSERT @t VALUES('Non-operator cannot add venues',@ok);
SELECT Name, CASE WHEN Pass=1 THEN 'PASS' ELSE 'FAIL' END AS Result FROM @t;
DECLARE @failed int=(SELECT COUNT(*) FROM @t WHERE Pass=0);
IF @failed>0 BEGIN DECLARE @m nvarchar(100)=CONCAT(@failed,' deposit lifecycle test(s) failed.'); THROW 50099,@m,1; END;
SELECT CONCAT((SELECT COUNT(*) FROM @t),' tests passed') AS Summary;
