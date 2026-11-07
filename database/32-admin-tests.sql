-- Acceptance tests for migration 31 (admin). DISPOSABLE DATABASE ONLY (name must end in _Tests).
--   sqlcmd -S localhost -E -C -b -d GameOn_Tests -i database\32-admin-tests.sql
SET NOCOUNT ON; SET XACT_ABORT OFF; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
IF DB_NAME() NOT LIKE N'%[_]Tests' THROW 50002,'Run these tests only on a disposable *_Tests database.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=31) THROW 50002,'Apply migration 31 to this test database first.',1;
DECLARE @tag nvarchar(12)=LEFT(REPLACE(CONVERT(nvarchar(36),NEWID()),'-',''),10);
DECLARE @t TABLE(Name nvarchar(200),Pass bit);
DECLARE @one TABLE(a sql_variant);
DECLARE @two TABLE(a sql_variant,b sql_variant);
DECLARE @three TABLE(a sql_variant,b sql_variant,c sql_variant);
DECLARE @ok bit,@A int,@A2 int,@U int,@Rich int,@Host int,@P int,@k uniqueidentifier,@Top uniqueidentifier,@ref nvarchar(40);
INSERT dbo.Users(Email,DisplayName,PasswordHash,Gender,DateOfBirth) VALUES('a'+@tag+'@gameon.invalid','Admin One','h','Female','19950101'); SET @A=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('a2'+@tag+'@gameon.invalid','Admin Two','h'); SET @A2=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash,Gender,DateOfBirth) VALUES('u'+@tag+'@gameon.invalid','Plain User','h','Male','20000101'); SET @U=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('r'+@tag+'@gameon.invalid','Rich User','h'); SET @Rich=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('h'+@tag+'@gameon.invalid','Host User','h'); SET @Host=SCOPE_IDENTITY();
INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES('p'+@tag+'@gameon.invalid','Player','h'); SET @P=SCOPE_IDENTITY();
-- Only admins can act
SET @ok=0; BEGIN TRY EXEC dbo.AdminListUsers @AdminId=@U; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50003,1,0); END CATCH;
INSERT @t VALUES('Non-admins cannot list users',@ok);
INSERT dbo.Admins(UserId) VALUES(@A);
INSERT @t SELECT 'Admin flag shows in profile',IIF(dbo.IsAdmin(@A)=1 AND dbo.IsAdmin(@U)=0,1,0);
-- Suspend / restore
DECLARE @StampBefore uniqueidentifier=(SELECT SessionStamp FROM dbo.Users WHERE UserId=@U);
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetUserStatus @AdminId=@A,@UserId=@U,@Status='Suspended',@Reason=NULL; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50002,1,0); END CATCH;
INSERT @t VALUES('Suspension needs a reason',@ok);
INSERT @one EXEC dbo.AdminSetUserStatus @AdminId=@A,@UserId=@U,@Status='Suspended',@Reason=N'Abusive messages'; DELETE @one;
DECLARE @sess TABLE(a int,b int,c uniqueidentifier);
INSERT @sess EXEC dbo.CheckSession @UserId=@U;
INSERT @t SELECT 'Suspended user has no valid session and a new stamp',IIF(NOT EXISTS(SELECT 1 FROM @sess) AND (SELECT SessionStamp FROM dbo.Users WHERE UserId=@U)<>@StampBefore,1,0);
INSERT @one EXEC dbo.AdminSetUserStatus @AdminId=@A,@UserId=@U,@Status='Active',@Reason=N'Appeal accepted'; DELETE @one;
INSERT @sess EXEC dbo.CheckSession @UserId=@U;
INSERT @t SELECT 'Restored user can sign in again',IIF(EXISTS(SELECT 1 FROM @sess),1,0); DELETE @sess;
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetUserStatus @AdminId=@A,@UserId=@A,@Status='Suspended',@Reason=N'self'; END TRY BEGIN CATCH SET @ok=1; END CATCH;
INSERT @t VALUES('Admin cannot suspend themselves',@ok);
-- Roles and last-admin protection
INSERT @two EXEC dbo.AdminSetRole @AdminId=@A,@UserId=@U,@Role='Operator',@Grant=1; DELETE @two;
INSERT @t SELECT 'Admin grants operator role',IIF(EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@U),1,0);
INSERT @two EXEC dbo.AdminSetRole @AdminId=@A,@UserId=@U,@Role='Operator',@Grant=0; DELETE @two;
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetRole @AdminId=@U,@UserId=@U,@Role='Admin',@Grant=1; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50003,1,0); END CATCH;
INSERT @t VALUES('Users cannot make themselves admin',@ok);
-- Make sure only our admins exist for the last-admin check in this disposable DB.
DECLARE @OtherAdmins TABLE(UserId int); INSERT @OtherAdmins SELECT UserId FROM dbo.Admins WHERE UserId<>@A; DELETE dbo.Admins WHERE UserId<>@A;
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetRole @AdminId=@A,@UserId=@A,@Role='Admin',@Grant=0; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50004,1,0); END CATCH;
INSERT @t VALUES('The last admin cannot be removed',@ok);
INSERT @two EXEC dbo.AdminSetRole @AdminId=@A,@UserId=@A2,@Role='Admin',@Grant=1; DELETE @two;
INSERT @two EXEC dbo.AdminSetRole @AdminId=@A2,@UserId=@A,@Role='Admin',@Grant=0; DELETE @two;
INSERT @t SELECT 'With a second admin, the first can step down',IIF(dbo.IsAdmin(@A)=0 AND dbo.IsAdmin(@A2)=1,1,0);
INSERT dbo.Admins(UserId) SELECT UserId FROM @OtherAdmins; INSERT dbo.Admins(UserId) VALUES(@A);
-- Delete: refused while money is held
SET @k=NEWID(); SET @ref=N'ADM-'+@tag;
DECLARE @tu TABLE(a sql_variant,b sql_variant,c sql_variant,d sql_variant,e sql_variant,f sql_variant);
INSERT @tu EXEC dbo.CreateTopUp @UserId=@Rich,@Key=@k,@Amount=10,@Recipient='+96171364432'; SELECT @Top=CONVERT(uniqueidentifier,a) FROM @tu; DELETE @tu;
INSERT @tu(a,b,c,d) EXEC dbo.SubmitTopUpReference @UserId=@Rich,@TopUpId=@Top,@Reference=@ref; DELETE @tu;
INSERT dbo.PaymentOperators(UserId) SELECT @A2 WHERE NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@A2);
INSERT @one EXEC dbo.ReviewTopUp @OperatorId=@A2,@TopUpId=@Top,@Decision='VERIFY',@Note=N'Seen'; DELETE @one;
SET @ok=0; BEGIN TRY EXEC dbo.AdminDeleteUser @AdminId=@A,@UserId=@Rich,@Reason=N'Requested deletion'; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50004,1,0); END CATCH;
INSERT @t SELECT 'Delete refused while wallet holds money',IIF(@ok=1 AND (SELECT AccountStatus FROM dbo.Users WHERE UserId=@Rich)='Active',1,0);
-- Delete: hosted games cancelled, personal data erased, records kept
DECLARE @V int,@G int,@Sport int=(SELECT TOP(1) SubtypeId FROM dbo.Subtypes);
INSERT dbo.Venues(Name,Area,Address,ListingStatus) VALUES(N'Admin test venue '+@tag,N'T',N'A','Unverified'); SET @V=SCOPE_IDENTITY();
DECLARE @ids TABLE(id int);
DECLARE @future datetime2(3)=DATEADD(day,4,SYSUTCDATETIME());
INSERT @ids EXEC dbo.CreateGame @HostUserId=@Host,@SportId=@Sport,@VenueId=@V,@StartsAt=@future,@Capacity=4; SELECT @G=id FROM @ids;
INSERT dbo.UserSportPreferences(UserId,SportId) VALUES(@Host,@Sport);
INSERT @two EXEC dbo.FriendRequest @UserId=@Host,@OtherId=@P,@Action='Request'; DELETE @two;
INSERT @one EXEC dbo.AdminDeleteUser @AdminId=@A,@UserId=@Host,@Reason=N'User asked to delete the account'; DELETE @one;
INSERT @t SELECT 'Deleted user: hosted game cancelled',IIF((SELECT GameStatus FROM dbo.GamesAndEvents WHERE EventId=@G)='Cancelled',1,0);
INSERT @t SELECT 'Deleted user: name, email, birth date and preferences erased',IIF((SELECT DisplayName FROM dbo.Users WHERE UserId=@Host)=N'Deleted user'
 AND (SELECT Email FROM dbo.Users WHERE UserId=@Host) LIKE N'deleted-%@gameon.invalid' AND NOT EXISTS(SELECT 1 FROM dbo.UserSportPreferences WHERE UserId=@Host)
 AND NOT EXISTS(SELECT 1 FROM dbo.Friendships WHERE @Host IN(UserLow,UserHigh)),1,0);
INSERT @t SELECT 'Deleted user: game record kept for history',IIF(EXISTS(SELECT 1 FROM dbo.GamesAndEvents WHERE EventId=@G AND HostUserId=@Host),1,0);
DECLARE @login TABLE(a int,b nvarchar(80),c nvarchar(512),d int,e varchar(10),f uniqueidentifier);
INSERT @login EXEC dbo.FindUserForLogin @Email=N'deleted-x';
INSERT @login EXEC dbo.FindUserForLogin @Email=@ref;
INSERT @t SELECT 'Deleted user cannot sign in (old email no longer exists)',IIF(NOT EXISTS(SELECT 1 FROM dbo.Users WHERE Email='h'+@tag+'@gameon.invalid'),1,0);
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetUserStatus @AdminId=@A,@UserId=@Host,@Status='Active',@Reason=N'undo'; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50004,1,0); END CATCH;
INSERT @t VALUES('Deleted accounts cannot be restored',@ok);
-- Settings
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetSetting @AdminId=@A,@Key='ProMonthlyPrice',@Value=N'500'; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50002,1,0); END CATCH;
INSERT @t VALUES('Pro price limited to 1-100',@ok);
INSERT @two EXEC dbo.AdminSetSetting @AdminId=@A,@Key='Announcement',@Value=N'Courts open late this week'; DELETE @two;
INSERT @two EXEC dbo.AdminSetSetting @AdminId=@A,@Key='SignupsOpen',@Value=N'false'; DELETE @two;
INSERT @t SELECT 'Settings saved',IIF((SELECT SettingValue FROM dbo.PlatformSettings WHERE SettingKey='Announcement')=N'Courts open late this week' AND (SELECT SettingValue FROM dbo.PlatformSettings WHERE SettingKey='SignupsOpen')=N'false',1,0);
INSERT @two EXEC dbo.AdminSetSetting @AdminId=@A,@Key='SignupsOpen',@Value=N'true'; DELETE @two;
INSERT @two EXEC dbo.AdminSetSetting @AdminId=@A,@Key='Announcement',@Value=N''; DELETE @two;
SET @ok=0; BEGIN TRY EXEC dbo.AdminSetSetting @AdminId=@U,@Key='Announcement',@Value=N'hack'; END TRY BEGIN CATCH SET @ok=IIF(ERROR_NUMBER()=50003,1,0); END CATCH;
INSERT @t VALUES('Non-admins cannot change settings',@ok);
INSERT @t SELECT 'Every admin action is audited',IIF((SELECT COUNT(*) FROM dbo.AdminAudit WHERE AdminId IN(@A,@A2))>=8,1,0);
SELECT Name, CASE WHEN Pass=1 THEN 'PASS' ELSE 'FAIL' END AS Result FROM @t;
DECLARE @failed int=(SELECT COUNT(*) FROM @t WHERE Pass=0);
IF @failed>0 BEGIN DECLARE @m nvarchar(100)=CONCAT(@failed,' admin test(s) failed.'); THROW 50099,@m,1; END;
SELECT CONCAT((SELECT COUNT(*) FROM @t),' admin tests passed') AS Summary;
