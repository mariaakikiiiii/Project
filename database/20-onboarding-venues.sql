-- Existing GameOn: back up, stop the API, run the WHOLE file in a NEW SSMS query.
-- Ordinary SSMS mode; no SQLCMD commands. Requires migration 18.
USE GameOn;
GO
IF @@TRANCOUNT<>0 THROW 50002,'Open a fresh query without an active transaction.',1;
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF;
BEGIN TRY
 BEGIN TRANSACTION;
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=18) THROW 50002,'Install migration 18 first.',1;
 IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=20) THROW 50002,'Migration 20 is already installed.',1;
 EXEC(N'ALTER TABLE dbo.Users ADD Gender varchar(20) NULL,DateOfBirth date NULL;');
 EXEC(N'ALTER TABLE dbo.Users ADD CONSTRAINT CK_Users_Gender CHECK(Gender IS NULL OR Gender IN(''Male'',''Female'',''NonBinary'',''PreferNotToSay'')),CONSTRAINT CK_Users_Birth CHECK(DateOfBirth IS NULL OR DateOfBirth>=''19000101'');');
 EXEC(N'CREATE TABLE dbo.VenueSubtypes(VenueId int NOT NULL REFERENCES dbo.Venues(VenueId),SubtypeId int NOT NULL REFERENCES dbo.Subtypes(SubtypeId),CONSTRAINT PK_VenueSubtypes PRIMARY KEY(VenueId,SubtypeId));');
 EXEC(N'CREATE TABLE dbo.VenueDirectoryAudit(AuditId bigint IDENTITY PRIMARY KEY,VenueId int NOT NULL REFERENCES dbo.Venues(VenueId),OperatorId int NOT NULL REFERENCES dbo.Users(UserId),CreatedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME());');
 EXEC(N'CREATE INDEX IX_Venues_Area_Name ON dbo.Venues(Area,Name) INCLUDE(Address,ContactPhoneNumber,IsVerified,Latitude,Longitude);');
 EXEC(N'CREATE OR ALTER FUNCTION dbo.ValidSportPreferences(@Json nvarchar(2000)) RETURNS bit AS
BEGIN
 IF @Json IS NULL OR ISJSON(@Json)<>1 OR LEFT(LTRIM(@Json),1)<>''['' RETURN 0;
 IF (SELECT COUNT(*) FROM OPENJSON(@Json)) NOT BETWEEN 1 AND 3 RETURN 0;
 IF (SELECT COUNT(DISTINCT TRY_CONVERT(int,value)) FROM OPENJSON(@Json))<>(SELECT COUNT(*) FROM OPENJSON(@Json)) RETURN 0;
 IF EXISTS(SELECT 1 FROM OPENJSON(@Json) j LEFT JOIN dbo.Subtypes s ON s.SubtypeId=TRY_CONVERT(int,j.value)
 LEFT JOIN dbo.Categories c ON c.CategoryId=s.CategoryId WHERE j.type<>2 OR s.SubtypeId IS NULL OR c.Slug<>''sports'') RETURN 0;
 RETURN 1;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.RegisterUser @Email nvarchar(254),@DisplayName nvarchar(80),@PasswordHash nvarchar(512),
 @Gender varchar(20)=NULL,@DateOfBirth date=NULL,@SportsJson nvarchar(2000)=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
 BEGIN TRANSACTION;
 IF @Gender IS NULL OR @Gender NOT IN(''Male'',''Female'',''NonBinary'',''PreferNotToSay'') OR @DateOfBirth IS NULL OR @DateOfBirth<''19000101'' OR @DateOfBirth>CONVERT(date,SYSUTCDATETIME())
 THROW 50002,''Choose a gender option and a valid date of birth.'',1;
 IF dbo.ValidSportPreferences(@SportsJson)<>1 THROW 50002,''Choose one to three distinct sports preferences.'',1;
 IF NULLIF(TRIM(@DisplayName),N'''') IS NULL OR NULLIF(TRIM(@Email),N'''') IS NULL THROW 50002,''Name and email are required.'',1;
 INSERT dbo.Users(Email,DisplayName,PasswordHash,Gender,DateOfBirth) VALUES(@Email,TRIM(@DisplayName),@PasswordHash,@Gender,@DateOfBirth);
 DECLARE @UserId int=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.UserPreferences(UserId) VALUES(@UserId);
 INSERT dbo.UserSportPreferences(UserId,SportId) SELECT @UserId,CONVERT(int,value) FROM OPENJSON(@SportsJson);
 COMMIT;
 SELECT UserId,DisplayName,SecurityVersion FROM dbo.Users WHERE UserId=@UserId;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.GetProfile @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT u.UserId,u.Email,u.DisplayName,u.Bio,u.Gender,u.DateOfBirth,p.Area,COALESCE(p.SkillLevel,''All levels'') AS SkillLevel,
 CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.PaymentOperators o WHERE o.UserId=u.UserId) THEN 1 ELSE 0 END AS bit) AS CanManageVenues
 FROM dbo.Users u LEFT JOIN dbo.UserPreferences p ON p.UserId=u.UserId WHERE u.UserId=@UserId;
 SELECT SportId FROM dbo.UserSportPreferences WHERE UserId=@UserId ORDER BY SportId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.SaveProfile
 @UserId int,@DisplayName nvarchar(80),@Bio nvarchar(400),@Area nvarchar(80),@SkillLevel varchar(16),@SportsJson nvarchar(2000),@Gender varchar(20)=NULL,@DateOfBirth date=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Id int;
  SELECT @Id=UserId FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId;
  IF @Id IS NULL THROW 50001,''User not found.'',1;
  IF LEN(TRIM(@DisplayName))=0 OR @SkillLevel NOT IN(''All levels'',''Beginner'',''Intermediate'',''Advanced'')
   THROW 50002,''Invalid profile.'',1;
  IF dbo.ValidSportPreferences(@SportsJson)<>1 THROW 50002,''Choose one to three distinct sports preferences.'',1;
  IF @Gender IS NOT NULL AND @Gender NOT IN(''Male'',''Female'',''NonBinary'',''PreferNotToSay'') THROW 50002,''Invalid gender option.'',1;
  IF @DateOfBirth IS NOT NULL AND (@DateOfBirth<''19000101'' OR @DateOfBirth>CONVERT(date,SYSUTCDATETIME())) THROW 50002,''Invalid date of birth.'',1;
  UPDATE dbo.Users SET DisplayName=TRIM(@DisplayName),Bio=@Bio,Gender=COALESCE(@Gender,Gender),DateOfBirth=COALESCE(@DateOfBirth,DateOfBirth) WHERE UserId=@UserId;
  UPDATE dbo.UserPreferences SET Area=NULLIF(TRIM(@Area),N''''),SkillLevel=@SkillLevel WHERE UserId=@UserId;
  IF @@ROWCOUNT=0 INSERT dbo.UserPreferences(UserId,Area,SkillLevel) VALUES(@UserId,NULLIF(TRIM(@Area),N''''),@SkillLevel);
  DELETE dbo.UserSportPreferences WHERE UserId=@UserId;
  INSERT dbo.UserSportPreferences(UserId,SportId) SELECT DISTINCT @UserId,CONVERT(int,value) FROM OPENJSON(@SportsJson);
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.SearchVenues @Query nvarchar(100)=N'''',@SubtypeId int=NULL AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @Term nvarchar(100)=TRIM(COALESCE(@Query,N''''));
 IF @SubtypeId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Subtypes WHERE SubtypeId=@SubtypeId) THROW 50002,''Unknown sport or activity.'',1;
 SELECT TOP(30) v.VenueId,v.Name,v.Area,v.Address,v.Latitude,v.Longitude,v.ContactPhoneNumber,v.IsVerified,
 CAST(CASE WHEN (v.Name=N''Central Court'' AND v.Address=N''Central sports complex'') OR (v.Name=N''North Field'' AND v.Address=N''North sports complex'') THEN 1 ELSE 0 END AS bit) AS IsDemo,
 CAST(CASE WHEN EXISTS(SELECT 1 FROM dbo.VenueSubtypes vs WHERE vs.VenueId=v.VenueId) THEN 1 ELSE 0 END AS bit) AS HasActivityDetails
 FROM dbo.Venues v
 WHERE (@Term=N'''' OR CHARINDEX(@Term COLLATE Latin1_General_100_CI_AI,v.Name COLLATE Latin1_General_100_CI_AI)>0
 OR CHARINDEX(@Term COLLATE Latin1_General_100_CI_AI,v.Area COLLATE Latin1_General_100_CI_AI)>0 OR CHARINDEX(@Term COLLATE Latin1_General_100_CI_AI,v.Address COLLATE Latin1_General_100_CI_AI)>0)
 AND (@SubtypeId IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.VenueSubtypes vs WHERE vs.VenueId=v.VenueId)
 OR EXISTS(SELECT 1 FROM dbo.VenueSubtypes vs WHERE vs.VenueId=v.VenueId AND vs.SubtypeId=@SubtypeId))
 ORDER BY v.IsVerified DESC,v.Area,v.Name,v.VenueId;
END;');
 EXEC(N'CREATE OR ALTER PROCEDURE dbo.AddDirectoryVenue @UserId int,@Name nvarchar(120),@Area nvarchar(80),@Address nvarchar(250),@Phone varchar(20),@SportsJson nvarchar(2000),@Verified bit=0 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@UserId) THROW 50003,''Venue operator access required.'',1;
 IF NULLIF(TRIM(@Name),N'''') IS NULL OR NULLIF(TRIM(@Area),N'''') IS NULL OR NULLIF(TRIM(@Address),N'''') IS NULL
 OR @Phone IS NULL OR LEN(@Phone) NOT BETWEEN 8 AND 16 OR @Phone NOT LIKE ''+%'' OR SUBSTRING(@Phone,2,20) LIKE ''%[^0-9]%''
 THROW 50002,''Provide the real venue name, area, address and international phone number.'',1;
 IF ISJSON(@SportsJson)<>1 OR LEFT(LTRIM(@SportsJson),1)<>''['' THROW 50002,''Choose supported venue activities.'',1;
 IF (SELECT COUNT(*) FROM OPENJSON(@SportsJson)) NOT BETWEEN 1 AND 17 OR EXISTS(SELECT 1 FROM OPENJSON(@SportsJson) j LEFT JOIN dbo.Subtypes s ON s.SubtypeId=TRY_CONVERT(int,j.value) WHERE j.type<>2 OR s.SubtypeId IS NULL)
 THROW 50002,''Choose between 1 and 17 known activities.'',1;
 BEGIN TRY
 BEGIN TRANSACTION;
 INSERT dbo.Venues(Name,Area,Address,ContactPhoneNumber,IsVerified) VALUES(TRIM(@Name),TRIM(@Area),TRIM(@Address),@Phone,@Verified);
 DECLARE @VenueId int=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.VenueSubtypes(VenueId,SubtypeId) SELECT DISTINCT @VenueId,CONVERT(int,value) FROM OPENJSON(@SportsJson);
 INSERT dbo.VenueDirectoryAudit(VenueId,OperatorId) VALUES(@VenueId,@UserId);
 COMMIT;
 SELECT @VenueId AS VenueId;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;');
 EXEC(N'GRANT EXECUTE ON dbo.SearchVenues TO gameon_executor;');
 EXEC(N'GRANT EXECUTE ON dbo.AddDirectoryVenue TO gameon_executor;');
 INSERT dbo.PlatformMigrations(Version) VALUES(20);
 COMMIT;
 SELECT 'Migration 20 completed successfully' AS Result;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
