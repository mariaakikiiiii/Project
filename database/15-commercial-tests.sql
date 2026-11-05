-- Migration owner, disposable upgraded database. Positive fixtures roll back.
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 IF dbo.PlatformServiceFee(0.25)<>0.01 OR dbo.PlatformServiceFee(1.25)<>0.03 OR dbo.PlatformServiceFee(100)<>2
  THROW 51000,'2% fee/half-cent rounding failed.',1;
 DECLARE @Host int=(SELECT MIN(UserId) FROM dbo.Users),@Type int=(SELECT MIN(SubtypeId) FROM dbo.Subtypes),@Venue int=(SELECT MIN(VenueId) FROM dbo.Venues),
 @A int,@B int,@CashGame int,@MockGame int,@Start datetime2=DATEADD(day,7,SYSUTCDATETIME()),@Key uniqueidentifier=NEWID(),@CashID uniqueidentifier,@MockID uniqueidentifier;
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Cash fixture',N'DISABLED_FIXTURE');
 SET @A=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Mock fixture',N'DISABLED_FIXTURE');
 SET @B=CONVERT(int,SCOPE_IDENTITY());
 EXEC dbo.CreateGame @Host,@Type,@Venue,@Start,2,N'Cash checkout fixture',1.25,'USD',0;
 SELECT @CashGame=MAX(EventId) FROM dbo.GamesAndEvents WHERE HostUserId=@Host;
 EXEC dbo.InitializeCheckout @CashGame,@A,'Cash',@Key,1;
 EXEC dbo.InitializeCheckout @CashGame,@A,'Cash',@Key,1;
 SELECT @CashID=PaymentID FROM dbo.Payments WHERE UserID=@A AND IdempotencyKey=@Key;
 IF (SELECT COUNT(*) FROM dbo.Payments WHERE UserID=@A AND GameID=@CashGame)<>1 THROW 51000,'Cash retry created duplicate payments.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@CashID AND Amount=1.25 AND ServiceFee=0.03 AND TotalAmount=1.28 AND Status='PendingCash')
  THROW 51000,'Cash price/fee/status mismatch.',1;
 EXEC dbo.CancelParticipation @CashGame,@A;
 IF (SELECT Status FROM dbo.Payments WHERE PaymentID=@CashID)<>'Cancelled' THROW 51000,'Cash cancellation left an active receivable.',1;
 EXEC dbo.CreateGame @Host,@Type,@Venue,@Start,2,N'Mock checkout fixture',15,'USD',0;
 SELECT @MockGame=MAX(EventId) FROM dbo.GamesAndEvents WHERE HostUserId=@Host;
 SET @Key=NEWID();
 EXEC dbo.InitializeCheckout @MockGame,@B,'WhishMock',@Key,1;
 SELECT @MockID=PaymentID FROM dbo.Payments WHERE UserID=@B AND IdempotencyKey=@Key;
 IF EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@MockGame AND UserId=@B) THROW 51000,'Initialization enrolled before verification.',1;
 DECLARE @Webhook uniqueidentifier=NEWID(),@Hash binary(32)=CRYPT_GEN_RANDOM(32),@Gateway nvarchar(128)=N'mock_'+CONVERT(nvarchar(36),@MockID);
 EXEC dbo.ApplyMockPaymentWebhook @Webhook,@MockID,@Gateway,'success',15.30,'USD',@Hash;
 EXEC dbo.ApplyMockPaymentWebhook @Webhook,@MockID,@Gateway,'success',15.30,'USD',@Hash;
 IF (SELECT COUNT(*) FROM dbo.PaymentWebhookEvents WHERE PaymentID=@MockID)<>1 THROW 51000,'Webhook replay duplicated processing.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@MockID AND Status='MockSucceeded') THROW 51000,'Mock result missing.',1;
 IF (SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@MockGame AND UserId=@B AND PaymentMethod='WhishMock')<>1 THROW 51000,'Verified mock enrollment failed.',1;
 EXEC dbo.CancelGame @MockGame,@Host;
 IF (SELECT Status FROM dbo.Payments WHERE PaymentID=@MockID)<>'MockCancelled' THROW 51000,'Cancelled demo still claims a current booking.',1;
 UPDATE dbo.SponsoredVenues SET IsActive=0; -- isolate test campaigns inside the rollback
 -- Campaign filtering, independent of existing local campaign records (rolled back).
 UPDATE dbo.SponsoredVenues SET Tier='Gold',StartDate=DATEADD(day,-1,SYSUTCDATETIME()),EndDate=DATEADD(day,1,SYSUTCDATETIME()),IsActive=1 WHERE VenueID=@Venue;
 IF @@ROWCOUNT=0 INSERT dbo.SponsoredVenues VALUES(@Venue,'Gold',DATEADD(day,-1,SYSUTCDATETIME()),DATEADD(day,1,SYSUTCDATETIME()),1);
 DECLARE @Featured TABLE(VenueId int,Name nvarchar(120),Area nvarchar(80),Address nvarchar(250),Tier varchar(12),EndDate datetime2(3));
 INSERT @Featured EXEC dbo.GetSponsoredVenues;
 IF NOT EXISTS(SELECT 1 FROM @Featured WHERE VenueId=@Venue) THROW 51000,'Active sponsor not shown.',1;
 UPDATE dbo.SponsoredVenues SET IsActive=0 WHERE VenueID=@Venue;
 DELETE @Featured;
 INSERT @Featured EXEC dbo.GetSponsoredVenues;
 IF EXISTS(SELECT 1 FROM @Featured WHERE VenueId=@Venue) THROW 51000,'Inactive sponsor leaked into discovery.',1;
 UPDATE dbo.SponsoredVenues SET IsActive=1,StartDate=DATEADD(day,-3,SYSUTCDATETIME()),EndDate=DATEADD(day,-1,SYSUTCDATETIME()) WHERE VenueID=@Venue;
 DELETE @Featured;
 INSERT @Featured EXEC dbo.GetSponsoredVenues;
 IF EXISTS(SELECT 1 FROM @Featured WHERE VenueId=@Venue) THROW 51000,'Expired sponsor leaked into discovery.',1;
 ROLLBACK;
 PRINT 'PASS: fee rounding, cash idempotency/cancellation, verified mock enrollment, webhook replay and sponsored visibility.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
