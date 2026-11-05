-- Disposable upgraded GameOn copy only. All positive fixtures roll back.
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @Host int=(SELECT MIN(UserId) FROM dbo.Users),@Type int=(SELECT MIN(SubtypeId) FROM dbo.Subtypes),
 @A int,@Operator int,@Game int,@Payment uniqueidentifier,@Key uniqueidentifier=NEWID(),@Start datetime2=DATEADD(day,7,SYSUTCDATETIME());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Manual payer',N'DISABLED_FIXTURE');
 SET @A=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.Users(Email,DisplayName,PasswordHash) VALUES(CONVERT(nvarchar(36),NEWID())+N'@test.invalid',N'Payment operator',N'DISABLED_FIXTURE');
 SET @Operator=CONVERT(int,SCOPE_IDENTITY());
 INSERT dbo.PaymentOperators(UserId) VALUES(@Operator);
 EXEC dbo.CreateGame @Host,@Type,0,@Start,2,N'Custom pin fixture',15,'USD',0,N'Host chosen court',N'Beirut',N'Host chosen location',33.89,35.50;
 SELECT @Game=MAX(EventId) FROM dbo.GamesAndEvents WHERE HostUserId=@Host;
 IF NOT EXISTS(SELECT 1 FROM dbo.GamesAndEvents g JOIN dbo.Venues v ON v.VenueId=g.VenueId WHERE g.EventId=@Game AND v.Latitude=33.89 AND v.Longitude=35.50)
 THROW 51000,'Host pin was not persisted.',1;
 EXEC dbo.InitializeCheckout @Game,@A,'WhishManual',@Key,1,N'+96171364432';
 EXEC dbo.InitializeCheckout @Game,@A,'WhishManual',@Key,1,N'+96171364432';
 SELECT @Payment=PaymentID FROM dbo.Payments WHERE UserID=@A AND IdempotencyKey=@Key;
 IF (SELECT COUNT(*) FROM dbo.Payments WHERE UserID=@A AND GameID=@Game)<>1 THROW 51000,'Manual retry created duplicate payments.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Payments WHERE PaymentID=@Payment AND Status='AwaitingTransfer' AND TotalAmount=15.30 AND RecipientNumber=N'+96171364432')
 THROW 51000,'Manual quote or initial state is wrong.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Participations WHERE GameId=@Game AND UserId=@A AND PaymentMethod='WhishManual')
 THROW 51000,'Manual checkout did not reserve its place.',1;
 EXEC dbo.SubmitWhishTransfer @Payment,@A,N'FIXTURE-1234';
 EXEC dbo.SubmitWhishTransfer @Payment,@A,N'FIXTURE-1234';
 IF (SELECT Status FROM dbo.Payments WHERE PaymentID=@Payment)<>'AwaitingVerification' THROW 51000,'A submitted reference must not become verified.',1;
 -- Operator authorization is checked before any transaction or mutation.
 BEGIN TRY
  EXEC dbo.ReviewWhishTransfer @Payment,@A,'VerifiedManual',N'Unauthorized fixture';
  THROW 51000,'Ordinary payer was allowed to verify a transfer.',1;
 END TRY BEGIN CATCH IF ERROR_NUMBER()<>50003 THROW; END CATCH;
 EXEC dbo.ReviewWhishTransfer @Payment,@Operator,'VerifiedManual',N'Fixture statement reconciled';
 IF (SELECT Status FROM dbo.Payments WHERE PaymentID=@Payment)<>'VerifiedManual' THROW 51000,'Operator review did not persist.',1;
 IF (SELECT COUNT(*) FROM dbo.PaymentReviews WHERE PaymentId=@Payment)<>1 THROW 51000,'Review audit is missing.',1;
 EXEC dbo.CancelParticipation @Game,@A;
 IF (SELECT Status FROM dbo.Payments WHERE PaymentID=@Payment)<>'RefundReview' THROW 51000,'Cancelled transfer must require reconciliation.',1;
 ROLLBACK;
 PRINT 'PASS: host location, manual reservation/retry, reference submission, operator authorization/audit, cancellation refund review. Fixtures rolled back.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
GO
