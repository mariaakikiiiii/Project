-- Disposable upgraded database only. Positive fixtures roll back; no Google/Whish calls.
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
IF dbo.ValidSportPreferences(N'[]')<>0 OR dbo.ValidSportPreferences(N'[1,1]')<>0 OR dbo.ValidSportPreferences(N'[1,2,3,4]')<>0
 OR dbo.ValidSportPreferences(N'not json')<>0 THROW 51000,'Invalid preference sets were accepted.',1;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @A int,@B int,@Activity int,@User int,@Operator int,@Venue int,@Email nvarchar(254)=CONVERT(nvarchar(36),NEWID())+N'@onboarding.test.invalid',@Json nvarchar(2000);
 SELECT @A=MIN(s.SubtypeId),@B=MAX(s.SubtypeId) FROM dbo.Subtypes s JOIN dbo.Categories c ON c.CategoryId=s.CategoryId WHERE c.Slug='sports';
 SELECT @Activity=MIN(s.SubtypeId) FROM dbo.Subtypes s JOIN dbo.Categories c ON c.CategoryId=s.CategoryId WHERE c.Slug='activities';
 SET @Json=N'['+CONVERT(nvarchar(10),@Activity)+N']';
 IF dbo.ValidSportPreferences(@Json)<>0 THROW 51000,'An entertainment subtype was accepted as a sport preference.',1;
 SET @Json=N'['+CONVERT(nvarchar(10),@A)+N','+CONVERT(nvarchar(10),@B)+N']';
 EXEC dbo.RegisterUser @Email,N'Onboarding fixture',N'DISABLED_FIXTURE','PreferNotToSay','19950512',@Json;
 SELECT @User=UserId FROM dbo.Users WHERE Email=@Email;
 IF NOT EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@User AND Gender='PreferNotToSay' AND DateOfBirth='19950512') THROW 51000,'Private signup details were not persisted.',1;
 IF (SELECT COUNT(*) FROM dbo.UserSportPreferences WHERE UserId=@User)<>2 THROW 51000,'Signup preferences were not persisted together.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserPreferences WHERE UserId=@User) THROW 51000,'Initial profile preferences are missing.',1;
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Venue curator fixture',N'DISABLED_FIXTURE'); SET @Operator=SCOPE_IDENTITY();
 INSERT dbo.PaymentOperators(UserId) VALUES(@Operator);
 EXEC dbo.AddDirectoryVenue @Operator,N'Jounieh directory fixture',N'Jounieh',N'Not a real venue','+96100000000',@Json,0;
 SELECT @Venue=MAX(VenueId) FROM dbo.Venues WHERE Name=N'Jounieh directory fixture';
 DECLARE @Matches TABLE(VenueId int,Name nvarchar(120),Area nvarchar(80),Address nvarchar(250),Latitude decimal(10,7),Longitude decimal(10,7),ContactPhoneNumber varchar(20),IsVerified bit,IsDemo bit,HasActivityDetails bit);
 INSERT @Matches EXEC dbo.SearchVenues N'jounieh',@A;
 IF NOT EXISTS(SELECT 1 FROM @Matches WHERE VenueId=@Venue AND HasActivityDetails=1) THROW 51000,'Town and sport search did not return the directory venue.',1;
 DELETE @Matches;
 INSERT @Matches EXEC dbo.SearchVenues N'jounieh%',@A;
 IF EXISTS(SELECT 1 FROM @Matches WHERE VenueId=@Venue) THROW 51000,'Search wildcard input was not treated literally.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.VenueDirectoryAudit WHERE VenueId=@Venue AND OperatorId=@Operator) THROW 51000,'Venue creation audit is missing.',1;
 ROLLBACK;
 PRINT 'PASS: private signup fields, 1–3 sports policy, initial preferences, in-app town/type search, literal search and venue creation audit. Fixtures rolled back.';
END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
GO
