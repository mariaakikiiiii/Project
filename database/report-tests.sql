-- GameOn report tests: constraints, procedures, trigger, query correctness and database security.
-- DISPOSABLE *_Tests DATABASE ONLY. Every test runs in its own transaction and is ROLLED BACK: nothing is kept.
--   sqlcmd -S localhost -E -C -I -d GameOn_Tests -i database\report-tests.sql
SET NOCOUNT ON; SET XACT_ABORT OFF; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF DB_NAME() NOT LIKE N'%[_]Tests' THROW 50002,'Run these tests only on a disposable *_Tests database.',1;
DECLARE @R TABLE(Id varchar(4), Area varchar(12), Tested nvarchar(200), Expected nvarchar(120), Actual nvarchar(300), Pass bit);
DECLARE @ok bit, @act nvarchar(300), @n int;
-- Fixtures that already exist in the test database
DECLARE @Court int=(SELECT TOP(1) c.CourtId FROM dbo.Courts c JOIN dbo.Clubs k ON k.ClubId=c.ClubId WHERE k.IsActive=1 AND c.IsActive=1 AND c.OpenHour<=10 AND c.CloseHour>=12 AND c.SlotMinutes=60 ORDER BY c.CourtId);
DECLARE @U1 int=(SELECT TOP(1) UserId FROM dbo.Users WHERE AccountStatus='Active' AND PasswordHash<>N'DISABLED_FIXTURE' ORDER BY UserId DESC);
DECLARE @U2 int=(SELECT TOP(1) UserId FROM dbo.Users WHERE AccountStatus='Active' AND PasswordHash<>N'DISABLED_FIXTURE' AND UserId<>@U1 ORDER BY UserId DESC);
DECLARE @Sport int=(SELECT MIN(SubtypeId) FROM dbo.Subtypes), @Venue int=(SELECT MIN(VenueId) FROM dbo.Venues);
-- A future 10:00 (Beirut) slot, 20 days ahead, on the slot grid
DECLARE @Slot datetime2(0)=dbo.FromBeirut(DATEADD(hour,10,CONVERT(datetime2(0),CONVERT(date,DATEADD(day,20,SYSUTCDATETIME())))));
DECLARE @Past datetime2(0)=dbo.FromBeirut(DATEADD(hour,10,CONVERT(datetime2(0),CONVERT(date,DATEADD(day,-2,SYSUTCDATETIME())))));

-- ===== Constraint tests (invalid rows must be rejected) =====
BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,@U1,@Slot,@Slot,30,'Confirmed','Player',@U1,NEWID());
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C01','Constraint',N'Booking that ends when it starts (CK_CB_Times)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_CB_Times%',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Discount,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,@U1,@Slot,DATEADD(hour,1,@Slot),30,45,'Confirmed','Player',@U1,NEWID());
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C02','Constraint',N'Discount 45 larger than list price 30 (CK_CB_Discount)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_CB_Discount%',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,@U1,@Slot,DATEADD(hour,1,@Slot),30,'Maybe','Player',@U1,NEWID());
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C03','Constraint',N'Unknown booking status ''Maybe'' (CK_CB_Status)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_CB_Status%',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,GuestName,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,NULL,NULL,@Slot,DATEADD(hour,1,@Slot),30,'Confirmed','Staff',@U1,NEWID());
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C04','Constraint',N'Booking with neither a user nor a guest name (CK_CB_Who)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_CB_Who%',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,@U1,@Slot,DATEADD(hour,1,@Slot),30,'Confirmed','Player',@U1,NEWID());
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,@U2,@Slot,DATEADD(hour,1,@Slot),30,'Confirmed','Player',@U2,NEWID());
 SET @act=N'both inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C05','Constraint',N'Two active bookings for the same court and time (UX_CB_Slot)',N'Second rejected (error 2601)',@act,IIF(@act LIKE N'error 2601%UX_CB_Slot%',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey,CancelledAt) VALUES(@Court,@U1,@Slot,DATEADD(hour,1,@Slot),30,'Cancelled','Player',@U1,NEWID(),SYSUTCDATETIME());
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(@Court,@U2,@Slot,DATEADD(hour,1,@Slot),30,'Confirmed','Player',@U2,NEWID());
 SET @act=N'both inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C06','Constraint',N'Cancelled booking + new booking on the same slot (filtered index ignores cancelled)',N'Both accepted',@act,IIF(@act=N'both inserted',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.Friendships(UserLow,UserHigh,RequestedBy) VALUES(IIF(@U1>@U2,@U1,@U2),IIF(@U1>@U2,@U2,@U1),@U1);
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C07','Constraint',N'Friendship stored with UserLow > UserHigh (CK_Friend_Order)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_Friend_Order%',1,0));

BEGIN TRAN; BEGIN TRY
 INSERT dbo.CourtBookings(CourtId,UserId,StartsAt,EndsAt,ListPrice,Status,Source,CreatedBy,IdempotencyKey) VALUES(-5,@U1,@Slot,DATEADD(hour,1,@Slot),30,'Confirmed','Player',@U1,NEWID());
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C08','Constraint',N'Booking for a court that does not exist (foreign key)',N'Rejected (error 547, FOREIGN KEY)',@act,IIF(@act LIKE N'error 547%FOREIGN KEY%',1,0));

BEGIN TRAN; BEGIN TRY
 DECLARE @Conv bigint=(SELECT TOP(1) ConversationId FROM dbo.Conversations);
 INSERT dbo.Messages(ConversationId,SenderId,Body,ClientKey) VALUES(@Conv,@U1,N'plain text secret',NEWID());
 SET @act=N'inserted'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C09','Constraint',N'Plain-text chat message written directly to the table (CK_Msg_Body)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_Msg_Body%',1,0));

BEGIN TRAN; BEGIN TRY
 UPDATE dbo.Clubs SET Balance=-1 WHERE ClubId=(SELECT MIN(ClubId) FROM dbo.Clubs);
 SET @act=N'updated'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('C10','Constraint',N'Club balance set to -1 (CK_Clubs_Balance)',N'Rejected (error 547)',@act,IIF(@act LIKE N'error 547%CK_Clubs_Balance%',1,0));

-- ===== Procedure and trigger tests =====
DECLARE @Bk TABLE(BookingId bigint,Price decimal(10,2),ListPrice decimal(10,2),Discount decimal(10,2),StartsAt datetime2,EndsAt datetime2,Status varchar(10),PaidFromWallet bit);
DECLARE @K uniqueidentifier=NEWID();
-- (BookCourt is called directly: INSERT...EXEC cannot capture a procedure that may roll back.)
BEGIN TRAN; BEGIN TRY
 EXEC dbo.BookCourt @CourtId=@Court,@UserId=@U1,@StartsAtUtc=@Slot,@Key=@K;
 EXEC dbo.BookCourt @CourtId=@Court,@UserId=@U1,@StartsAtUtc=@Slot,@Key=@K;
 SELECT @n=COUNT(*) FROM dbo.CourtBookings WHERE CreatedBy=@U1 AND IdempotencyKey=@K;
 SET @act=CONCAT(N'2 calls with the same key; bookings stored: ',@n);
 END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('P01','Procedure',N'BookCourt called twice with the same request key (idempotency)',N'One booking stored',@act,IIF(@act LIKE N'%bookings stored: 1',1,0));
DELETE @Bk;

BEGIN TRAN; BEGIN TRY
 EXEC dbo.BookCourt @CourtId=@Court,@UserId=@U1,@StartsAtUtc=@Past,@Key=@K;
 SET @act=N'booked'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('P02','Procedure',N'BookCourt for a time in the past',N'Rejected (50002 Choose a future time)',@act,IIF(@act LIKE N'error 50002%future%',1,0));
DELETE @Bk;

BEGIN TRAN; BEGIN TRY
 EXEC dbo.BookCourt @CourtId=@Court,@UserId=@U1,@StartsAtUtc=@Slot,@Key=@K;
 DECLARE @K2 uniqueidentifier=NEWID();
 BEGIN TRY EXEC dbo.BookCourt @CourtId=@Court,@UserId=@U2,@StartsAtUtc=@Slot,@Key=@K2; SET @act=N'both booked'; END TRY
 BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('P03','Procedure',N'Second player books a slot that is already taken',N'Rejected (50004)',@act,IIF(@act LIKE N'error 50004%',1,0));
DELETE @Bk;

DECLARE @Ids TABLE(id int);
BEGIN TRAN; BEGIN TRY
 DECLARE @start datetime2(3)=DATEADD(day,10,SYSUTCDATETIME()), @G int, @st1 varchar(20), @st2 varchar(20);
 INSERT @Ids EXEC dbo.CreateGame @HostUserId=@U1,@SportId=@Sport,@VenueId=@Venue,@StartsAt=@start,@Capacity=2,@Description=N'report test',@CostPerPlayer=0,@Currency='USD',@SponsoredSlots=0;
 SELECT @G=id FROM @Ids;
 DECLARE @U3 int=(SELECT TOP(1) UserId FROM dbo.Users WHERE AccountStatus='Active' AND UserId NOT IN(@U1,@U2) ORDER BY UserId DESC);
 EXEC dbo.sp_JoinGameOrActivity @GameId=@G,@UserId=@U2,@ResultStatus=@st1 OUTPUT,@ReturnResult=0;
 EXEC dbo.sp_JoinGameOrActivity @GameId=@G,@UserId=@U3,@ResultStatus=@st2 OUTPUT,@ReturnResult=0;
 SET @act=CONCAT(N'capacity 2 (host + 1): 2nd player ',@st1,N', 3rd player ',@st2,N'; participants ',(SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@G));
 END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('P04','Procedure',N'Join a full game (sp_JoinGameOrActivity)',N'Last player goes to the waitlist, never over capacity',@act,IIF(@act LIKE N'%3rd player Waitlisted; participants 2',1,0));
DELETE @Ids;

BEGIN TRAN; BEGIN TRY
 INSERT @Ids EXEC dbo.CreateGame @HostUserId=@U1,@SportId=@Sport,@VenueId=@Venue,@StartsAt=@start,@Capacity=4,@Description=N'report test',@CostPerPlayer=0,@Currency='USD',@SponsoredSlots=0;
 SELECT @G=id FROM @Ids;
 EXEC dbo.CancelGame @GameId=@G,@HostUserId=@U2;
 SET @act=N'cancelled'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('P05','Procedure',N'Someone who is not the host cancels a game',N'Rejected (50003)',@act,IIF(@act LIKE N'error 50003%',1,0));
DELETE @Ids;

BEGIN TRAN; BEGIN TRY
 INSERT @Ids EXEC dbo.CreateGame @HostUserId=@U1,@SportId=@Sport,@VenueId=@Venue,@StartsAt=@start,@Capacity=4,@Description=N'report test',@CostPerPlayer=0,@Currency='USD',@SponsoredSlots=0;
 SELECT @G=id FROM @Ids;
 UPDATE dbo.GamesAndEvents SET JoinMode='Approval' WHERE EventId=@G;
 INSERT dbo.Participations(GameId,UserId,PaymentMethod) VALUES(@G,@U2,'Cash');
 SET @act=N'joined directly'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('T01','Trigger',N'Direct insert into an approval-only game (ApprovalRequiredParticipation)',N'Rejected by the trigger',@act,IIF(@act LIKE N'error%',1,0));
DELETE @Ids;

DECLARE @Msg TABLE(MessageId bigint,ConversationId bigint,SenderId int,SenderName nvarchar(80),Kind varchar(8),Body nvarchar(1000),ReplyToId bigint,ReplyToBody nvarchar(1000),ReplyToSender nvarchar(80),EditedAt datetime2,DeletedAt datetime2,CreatedAt datetime2,Reactions nvarchar(max));
BEGIN TRAN; BEGIN TRY
 DECLARE @C2 bigint, @Snd int;
 SELECT TOP(1) @C2=m.ConversationId,@Snd=m.SenderId FROM dbo.Messages m JOIN dbo.Users u ON u.UserId=m.SenderId WHERE u.AccountStatus='Active' AND m.Kind='Text' ORDER BY m.MessageId DESC;
 EXEC dbo.SendMessage @ConversationId=@C2,@UserId=@Snd,@Body=N'Report test: see you at 8',@ClientKey=@K;
 SELECT @act=CONCAT(N'Body=',ISNULL(Body,N'NULL'),N'; BodyCipher=',LEFT(CONVERT(varchar(80),BodyCipher,1),26),N'...; decrypted by procedure: ',
   CONVERT(nvarchar(100),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,BodyCipher,1,CONVERT(varbinary(8),ConversationId))))
 FROM dbo.Messages WHERE SenderId=@Snd AND ClientKey=@K;
 END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH; IF @@TRANCOUNT>0 ROLLBACK;
INSERT @R VALUES('P06','Procedure',N'SendMessage stores the text encrypted (ENCRYPTBYKEY)',N'Body NULL, ciphertext stored, decrypts to the text',@act,IIF(@act LIKE N'Body=NULL; BodyCipher=0x%decrypted by procedure: Report test: see you at 8',1,0));

-- ===== Query correctness =====
BEGIN TRY
 SELECT @n=COUNT(*) FROM dbo.CourtBookings WHERE ListPrice-Discount<>Price;
 SET @act=CONCAT(N'rows where Price <> ListPrice - Discount: ',@n); END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('Q01','Query',N'Computed column Price = ListPrice - Discount on all bookings',N'0 mismatches',@act,IIF(@act LIKE N'%: 0',1,0));

BEGIN TRY
 DECLARE @a int=(SELECT COUNT(*) FROM dbo.CourtBookings WITH(INDEX(IX_CB_Court_Time)) WHERE CourtId=@Court),
         @b int=(SELECT COUNT(*) FROM dbo.CourtBookings WITH(INDEX(1)) WHERE CourtId=@Court);
 SET @act=CONCAT(N'through index: ',@a,N', full scan: ',@b); END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('Q02','Query',N'Same answer with the index and with a full table scan',N'Equal counts',@act,IIF(@a=@b,1,0));

-- ===== Security =====
BEGIN TRY
 EXECUTE AS USER='gameon_api';
 BEGIN TRY SELECT TOP(1) @n=UserId FROM dbo.Users; SET @act=N'SELECT allowed'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH;
 REVERT;
END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('S01','Security',N'App login gameon_api runs SELECT on dbo.Users',N'Denied (error 229)',@act,IIF(@act LIKE N'error 229%',1,0));

BEGIN TRY
 EXECUTE AS USER='gameon_api';
 BEGIN TRY UPDATE dbo.Users SET DisplayName=DisplayName WHERE UserId=@U1; SET @act=N'UPDATE allowed'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH;
 REVERT;
END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('S02','Security',N'App login gameon_api runs UPDATE on dbo.Users',N'Denied (error 229)',@act,IIF(@act LIKE N'error 229%',1,0));

DECLARE @L TABLE(x int);
BEGIN TRY
 EXECUTE AS USER='gameon_api';
 BEGIN TRY EXEC dbo.GetPlatformSettings; SET @act=N'EXECUTE allowed'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH;
 REVERT;
END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('S03','Security',N'App login gameon_api executes a granted procedure',N'Allowed',@act,IIF(@act=N'EXECUTE allowed',1,0));

BEGIN TRY
 EXECUTE AS USER='gameon_api';
 BEGIN TRY OPEN SYMMETRIC KEY GameOnMessageKey DECRYPTION BY CERTIFICATE GameOnMessageCert; CLOSE SYMMETRIC KEY GameOnMessageKey; SET @act=N'key opened'; END TRY BEGIN CATCH SET @act=CONCAT(N'error ',ERROR_NUMBER(),N': ',LEFT(ERROR_MESSAGE(),120)); END CATCH;
 REVERT;
END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('S04','Security',N'App login gameon_api opens the message encryption key itself',N'Denied',@act,IIF(@act LIKE N'error%',1,0));

DECLARE @V TABLE(c1 sql_variant);
BEGIN TRY
 DECLARE @payload nvarchar(100)=N''' OR 1=1; DROP TABLE dbo.Users; --';
 CREATE TABLE #Found(VenueId int);
 DECLARE @cnt int;
 EXEC sp_executesql N'SELECT @c=COUNT(*) FROM dbo.Venues WHERE Name LIKE N''%''+@q+N''%''',N'@q nvarchar(100),@c int OUTPUT',@q=@payload,@c=@cnt OUTPUT;
 SET @act=CONCAT(N'payload treated as text; venues matched: ',@cnt,N'; dbo.Users still exists: ',IIF(OBJECT_ID(N'dbo.Users') IS NOT NULL,N'yes',N'NO'));
 DROP TABLE #Found;
END TRY BEGIN CATCH SET @act=ERROR_MESSAGE(); END CATCH;
INSERT @R VALUES('S05','Security',N'SQL injection payload '' OR 1=1; DROP TABLE dbo.Users; -- sent as a parameter',N'0 matches, no table dropped',@act,IIF(@act LIKE N'%matched: 0; dbo.Users still exists: yes',1,0));

SELECT Id,Area,Tested,Expected,Actual,IIF(Pass=1,'PASS','FAIL') AS Result FROM @R ORDER BY Id;
SELECT CONCAT(SUM(CONVERT(int,Pass)),' of ',COUNT(*),' report tests passed') AS Summary FROM @R;
