-- GameOn migration 36: email verification, modern group chats (admins, description, member management,
-- system notices) and message replies, reactions, edit and delete-for-everyone.
-- Requires migration 35. Back up GameOn and stop the API first.
-- Run from the REPOSITORY ROOT with a DBA identity (QUOTED_IDENTIFIER must be ON, hence -I):
--   sqlcmd -S localhost -E -I -b -i database/36-email-verification-group-chat.sql
-- Schema changes run in one transaction; procedures are created afterwards (CREATE OR ALTER, safe to rerun).
-- Existing accounts are marked verified so current users are not locked out of booking or chat.
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF;
IF @@TRANCOUNT<>0 THROW 50002,'Open a fresh query with no active transaction.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=35) THROW 50002,'Install migration 35 first.',1;
IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=36) THROW 50002,'Migration 36 is already installed. Do not rerun it.',1;
BEGIN TRY
 BEGIN TRANSACTION;
 -- ===== Email verification =====
 EXEC(N'ALTER TABLE dbo.Users ADD EmailVerifiedAt datetime2(3) NULL;');
 EXEC(N'UPDATE dbo.Users SET EmailVerifiedAt=CreatedAt;');
 EXEC(N'CREATE TABLE dbo.EmailVerificationTokens(TokenHash binary(32) NOT NULL CONSTRAINT PK_EmailVerificationTokens PRIMARY KEY,
  UserId int NOT NULL CONSTRAINT FK_EmailVerify_User REFERENCES dbo.Users(UserId),
  CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_EmailVerify_Created DEFAULT SYSUTCDATETIME(),
  ExpiresAt datetime2(3) NOT NULL, UsedAt datetime2(3) NULL);');
 EXEC(N'CREATE INDEX IX_EmailVerify_User ON dbo.EmailVerificationTokens(UserId,CreatedAt DESC);');
 EXEC(N'ALTER TABLE dbo.ResetEmailOutbox ADD Purpose varchar(8) NOT NULL CONSTRAINT DF_Outbox_Purpose DEFAULT ''Reset''
  CONSTRAINT CK_Outbox_Purpose CHECK(Purpose IN(''Reset'',''Verify''));');

 -- ===== Groups: roles and description =====
 EXEC(N'ALTER TABLE dbo.PlayerGroups ADD Description nvarchar(300) NULL;');
 EXEC(N'ALTER TABLE dbo.PlayerGroupMembers ADD Role varchar(8) NOT NULL CONSTRAINT DF_GroupMember_Role DEFAULT ''Member''
  CONSTRAINT CK_GroupMember_Role CHECK(Role IN(''Owner'',''Admin'',''Member''));');
 EXEC(N'UPDATE m SET Role=''Owner'' FROM dbo.PlayerGroupMembers m JOIN dbo.PlayerGroups g ON g.GroupId=m.GroupId AND g.OwnerId=m.UserId;');

 -- ===== Messages: replies, edits, deletes, system notices, reactions =====
 EXEC(N'ALTER TABLE dbo.Messages ADD Kind varchar(8) NOT NULL CONSTRAINT DF_Msg_Kind DEFAULT ''Text'' CONSTRAINT CK_Msg_Kind CHECK(Kind IN(''Text'',''System'')),
  ReplyToId bigint NULL CONSTRAINT FK_Msg_ReplyTo REFERENCES dbo.Messages(MessageId),
  EditedAt datetime2(3) NULL, DeletedAt datetime2(3) NULL;');
 -- A deleted message keeps its row (so replies still point somewhere) but loses its content.
 EXEC(N'ALTER TABLE dbo.Messages DROP CONSTRAINT CK_Msg_Body;');
 EXEC(N'ALTER TABLE dbo.Messages ADD CONSTRAINT CK_Msg_Body CHECK((DeletedAt IS NOT NULL AND Body IS NULL AND BodyCipher IS NULL)
  OR (Body IS NULL AND BodyCipher IS NOT NULL) OR (BodyCipher IS NULL AND (LEFT(Body,5)=''enc1:'' OR Body=N''(message from a deleted account)'')));');
 EXEC(N'CREATE TABLE dbo.MessageReactions(MessageId bigint NOT NULL CONSTRAINT FK_Reaction_Msg REFERENCES dbo.Messages(MessageId),
  UserId int NOT NULL CONSTRAINT FK_Reaction_User REFERENCES dbo.Users(UserId), Emoji nvarchar(16) NOT NULL,
  CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Reaction_Created DEFAULT SYSUTCDATETIME(),
  CONSTRAINT PK_MessageReactions PRIMARY KEY(MessageId,UserId));');

 INSERT dbo.PlatformMigrations(Version) VALUES(36);
 COMMIT;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
GO

-- ======================================================================
-- Email verification procedures
-- ======================================================================
CREATE OR ALTER PROCEDURE dbo.GetEmailStatus @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT Email,CAST(IIF(EmailVerifiedAt IS NULL,0,1) AS bit) AS EmailVerified FROM dbo.Users WHERE UserId=@UserId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.RequestEmailVerification @UserId int,@TokenHash binary(32),@ProtectedToken nvarchar(2000) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Email nvarchar(254),@Verified datetime2(3);
  SELECT @Email=Email,@Verified=EmailVerifiedAt FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@UserId AND AccountStatus='Active';
  IF @Email IS NULL THROW 50001,'Account not found.',1;
  IF @Verified IS NOT NULL THROW 50004,'Your email is already verified.',1;
  IF EXISTS(SELECT 1 FROM dbo.EmailVerificationTokens WHERE UserId=@UserId AND CreatedAt>DATEADD(second,-60,SYSUTCDATETIME()))
   THROW 50004,'A verification email was just sent. Wait a minute before asking for another.',1;
  DELETE dbo.EmailVerificationTokens WHERE UserId=@UserId;
  DELETE dbo.ResetEmailOutbox WHERE Recipient=@Email AND Purpose='Verify' AND SentAt IS NULL;
  INSERT dbo.EmailVerificationTokens(TokenHash,UserId,ExpiresAt) VALUES(@TokenHash,@UserId,DATEADD(hour,24,SYSUTCDATETIME()));
  INSERT dbo.ResetEmailOutbox(Recipient,ProtectedToken,ExpiresAt,Purpose) VALUES(@Email,@ProtectedToken,DATEADD(hour,24,SYSUTCDATETIME()),'Verify');
  COMMIT;
  SELECT 'Queued' AS Status;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.VerifyEmail @TokenHash binary(32) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @UserId int=(SELECT UserId FROM dbo.EmailVerificationTokens WITH(UPDLOCK,HOLDLOCK)
   WHERE TokenHash=@TokenHash AND UsedAt IS NULL AND ExpiresAt>SYSUTCDATETIME());
  IF @UserId IS NULL THROW 50002,'This verification link is invalid or has expired. Send a new one from the banner after signing in.',1;
  UPDATE dbo.EmailVerificationTokens SET UsedAt=SYSUTCDATETIME() WHERE TokenHash=@TokenHash;
  UPDATE dbo.Users SET EmailVerifiedAt=COALESCE(EmailVerifiedAt,SYSUTCDATETIME()) WHERE UserId=@UserId;
  COMMIT;
  SELECT 'Verified' AS Status;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
-- Password resets must only replace pending RESET emails, not verification emails.
CREATE OR ALTER PROCEDURE dbo.RequestPasswordReset @Email nvarchar(254),@TokenHash binary(32),@ProtectedToken nvarchar(2000) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @UserId int;
  SELECT @UserId=UserId FROM dbo.Users WITH(UPDLOCK,HOLDLOCK) WHERE Email=@Email AND PasswordHash<>N'DISABLED_FIXTURE';
  IF @UserId IS NOT NULL
  BEGIN
   DELETE dbo.PasswordResetTokens WHERE UserId=@UserId;
   DELETE dbo.ResetEmailOutbox WHERE Recipient=@Email AND Purpose='Reset' AND SentAt IS NULL;
   INSERT dbo.PasswordResetTokens(TokenHash,UserId,ExpiresAt) VALUES(@TokenHash,@UserId,DATEADD(minute,30,SYSUTCDATETIME()));
   INSERT dbo.ResetEmailOutbox(Recipient,ProtectedToken,ExpiresAt,Purpose) VALUES(@Email,@ProtectedToken,DATEADD(minute,30,SYSUTCDATETIME()),'Reset');
  END;
  COMMIT;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ClaimResetEmail @Lease uniqueidentifier AS
BEGIN
 SET NOCOUNT ON;
 ;WITH NextEmail AS(
  SELECT TOP(1) * FROM dbo.ResetEmailOutbox WITH(UPDLOCK,READPAST,READCOMMITTEDLOCK)
  WHERE SentAt IS NULL AND NextAttemptAt<=SYSUTCDATETIME() AND ExpiresAt>SYSUTCDATETIME() AND Attempts<5
  ORDER BY NextAttemptAt,OutboxId
 )
 UPDATE NextEmail SET Lease=@Lease,Attempts=Attempts+1,NextAttemptAt=DATEADD(minute,2,SYSUTCDATETIME())
 OUTPUT inserted.OutboxId,inserted.Recipient,inserted.ProtectedToken,inserted.Purpose;
END;
GO

-- ======================================================================
-- Chat: shared helpers
-- ======================================================================
CREATE OR ALTER FUNCTION dbo.GroupRole(@GroupId int,@UserId int) RETURNS varchar(8) AS
BEGIN
 RETURN (SELECT Role FROM dbo.PlayerGroupMembers WHERE GroupId=@GroupId AND UserId=@UserId);
END;
GO
-- Procedures that open or use the message key run WITH EXECUTE AS OWNER (as in migration 34): gameon_api itself has
-- no permission on the key or certificate, so only these vetted procedures can encrypt or decrypt.
-- One message in the shape the API and the browser use (decrypted inside SQL Server).
CREATE OR ALTER PROCEDURE dbo.GetMessageRow @MessageId bigint WITH EXECUTE AS OWNER AS
BEGIN
 SET NOCOUNT ON;
 SELECT m.MessageId,m.ConversationId,m.SenderId,u.DisplayName AS SenderName,m.Kind,
  CASE WHEN m.DeletedAt IS NOT NULL THEN NULL ELSE CONVERT(nvarchar(1000),COALESCE(m.Body,CONVERT(nvarchar(1000),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,m.BodyCipher,1,CONVERT(varbinary(8),m.ConversationId))))) END AS Body,
  m.CreatedAt,m.EditedAt,CAST(IIF(m.DeletedAt IS NULL,0,1) AS bit) AS IsDeleted,m.ReplyToId,ru.DisplayName AS ReplyToSenderName,
  CASE WHEN r.MessageId IS NULL THEN NULL WHEN r.DeletedAt IS NOT NULL THEN N'' ELSE LEFT(CONVERT(nvarchar(1000),COALESCE(r.Body,CONVERT(nvarchar(1000),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,r.BodyCipher,1,CONVERT(varbinary(8),r.ConversationId))))),120) END AS ReplyToBody,
  (SELECT x.Emoji AS emoji,x.UserId AS userId,xu.DisplayName AS name FROM dbo.MessageReactions x JOIN dbo.Users xu ON xu.UserId=x.UserId
   WHERE x.MessageId=m.MessageId ORDER BY x.CreatedAt FOR JSON PATH) AS ReactionsJson
 FROM dbo.Messages m JOIN dbo.Users u ON u.UserId=m.SenderId LEFT JOIN dbo.Messages r ON r.MessageId=m.ReplyToId LEFT JOIN dbo.Users ru ON ru.UserId=r.SenderId
 WHERE m.MessageId=@MessageId;
END;
GO
-- "Ali added Maya" style notices inside a group chat (encrypted like any other message).
CREATE OR ALTER PROCEDURE dbo.PostSystemMessage @ConversationId bigint,@ActorId int,@Text nvarchar(300) WITH EXECUTE AS OWNER AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @ConversationId IS NULL RETURN;
 OPEN SYMMETRIC KEY GameOnMessageKey DECRYPTION BY CERTIFICATE GameOnMessageCert;
 INSERT dbo.Messages(ConversationId,SenderId,Body,BodyCipher,ClientKey,Kind)
 VALUES(@ConversationId,@ActorId,NULL,ENCRYPTBYKEY(KEY_GUID(N'GameOnMessageKey'),@Text,1,CONVERT(varbinary(8),@ConversationId)),NEWID(),'System');
 CLOSE SYMMETRIC KEY GameOnMessageKey;
 UPDATE dbo.Conversations SET LastMessageAt=SYSUTCDATETIME() WHERE ConversationId=@ConversationId;
END;
GO

-- ======================================================================
-- Chat: messages
-- ======================================================================
CREATE OR ALTER PROCEDURE dbo.SendMessage @ConversationId bigint,@UserId int,@Body nvarchar(max),@ClientKey uniqueidentifier,@ReplyToId bigint=NULL WITH EXECUTE AS OWNER AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET @Body=TRIM(@Body);
 IF @Body IS NULL OR LEN(@Body) NOT BETWEEN 1 AND 1000 THROW 50002,'Write a message (up to 1000 characters).',1;
 IF dbo.CanUseConversation(@ConversationId,@UserId)=0 THROW 50003,'You are not part of this chat.',1;
 IF @ReplyToId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Messages WHERE MessageId=@ReplyToId AND ConversationId=@ConversationId)
  THROW 50002,'The message you are replying to is not in this chat.',1;
 -- Simple flood control: 20 messages per minute per sender.
 IF (SELECT COUNT(*) FROM dbo.Messages WHERE SenderId=@UserId AND Kind='Text' AND CreatedAt>DATEADD(minute,-1,SYSUTCDATETIME()))>=20 THROW 50004,'You are sending messages too fast. Wait a moment.',1;
 DECLARE @Id bigint;
 BEGIN TRY
  BEGIN TRANSACTION;
  SET @Id=(SELECT MessageId FROM dbo.Messages WHERE SenderId=@UserId AND ClientKey=@ClientKey);
  IF @Id IS NULL
  BEGIN
   -- Encrypted by SQL Server: AES-256 symmetric key, protected by a certificate (never stored in the app or in Git).
   -- The conversation id is the authenticator, so a ciphertext copied into another chat will not decrypt.
   OPEN SYMMETRIC KEY GameOnMessageKey DECRYPTION BY CERTIFICATE GameOnMessageCert;
   INSERT dbo.Messages(ConversationId,SenderId,Body,BodyCipher,ClientKey,ReplyToId)
   VALUES(@ConversationId,@UserId,NULL,ENCRYPTBYKEY(KEY_GUID(N'GameOnMessageKey'),@Body,1,CONVERT(varbinary(8),@ConversationId)),@ClientKey,@ReplyToId);
   CLOSE SYMMETRIC KEY GameOnMessageKey;
   SET @Id=SCOPE_IDENTITY();
   UPDATE dbo.Conversations SET LastMessageAt=SYSUTCDATETIME() WHERE ConversationId=@ConversationId;
   MERGE dbo.ConversationReads AS t USING (SELECT @ConversationId c,@UserId u) s ON t.ConversationId=s.c AND t.UserId=s.u
   WHEN MATCHED THEN UPDATE SET LastReadMessageId=@Id WHEN NOT MATCHED THEN INSERT(ConversationId,UserId,LastReadMessageId) VALUES(@ConversationId,@UserId,@Id);
  END;
  COMMIT;
 END TRY BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
 EXEC dbo.GetMessageRow @Id;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetMessages @ConversationId bigint,@UserId int,@BeforeId bigint=NULL WITH EXECUTE AS OWNER AS
BEGIN
 SET NOCOUNT ON;
 IF dbo.CanUseConversation(@ConversationId,@UserId)=0 THROW 50003,'You are not part of this chat.',1;
 SELECT TOP(50) m.MessageId,m.ConversationId,m.SenderId,u.DisplayName AS SenderName,m.Kind,
  CASE WHEN m.DeletedAt IS NOT NULL THEN NULL ELSE CONVERT(nvarchar(1000),COALESCE(m.Body,CONVERT(nvarchar(1000),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,m.BodyCipher,1,CONVERT(varbinary(8),m.ConversationId))))) END AS Body,
  m.CreatedAt,m.EditedAt,CAST(IIF(m.DeletedAt IS NULL,0,1) AS bit) AS IsDeleted,m.ReplyToId,ru.DisplayName AS ReplyToSenderName,
  CASE WHEN r.MessageId IS NULL THEN NULL WHEN r.DeletedAt IS NOT NULL THEN N'' ELSE LEFT(CONVERT(nvarchar(1000),COALESCE(r.Body,CONVERT(nvarchar(1000),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,r.BodyCipher,1,CONVERT(varbinary(8),r.ConversationId))))),120) END AS ReplyToBody,
  (SELECT x.Emoji AS emoji,x.UserId AS userId,xu.DisplayName AS name FROM dbo.MessageReactions x JOIN dbo.Users xu ON xu.UserId=x.UserId
   WHERE x.MessageId=m.MessageId ORDER BY x.CreatedAt FOR JSON PATH) AS ReactionsJson
 FROM dbo.Messages m JOIN dbo.Users u ON u.UserId=m.SenderId LEFT JOIN dbo.Messages r ON r.MessageId=m.ReplyToId LEFT JOIN dbo.Users ru ON ru.UserId=r.SenderId
 WHERE m.ConversationId=@ConversationId AND (@BeforeId IS NULL OR m.MessageId<@BeforeId) ORDER BY m.MessageId DESC;
 DECLARE @Last bigint=(SELECT MAX(MessageId) FROM dbo.Messages WHERE ConversationId=@ConversationId);
 IF @Last IS NOT NULL AND @BeforeId IS NULL
  MERGE dbo.ConversationReads AS t USING (SELECT @ConversationId c,@UserId u) s ON t.ConversationId=s.c AND t.UserId=s.u
  WHEN MATCHED THEN UPDATE SET LastReadMessageId=@Last WHEN NOT MATCHED THEN INSERT(ConversationId,UserId,LastReadMessageId) VALUES(@ConversationId,@UserId,@Last);
END;
GO
-- Senders can edit their own text messages for 15 minutes.
CREATE OR ALTER PROCEDURE dbo.EditMessage @MessageId bigint,@UserId int,@Body nvarchar(max) WITH EXECUTE AS OWNER AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET @Body=TRIM(@Body);
 IF @Body IS NULL OR LEN(@Body) NOT BETWEEN 1 AND 1000 THROW 50002,'Write a message (up to 1000 characters).',1;
 DECLARE @Conv bigint,@Sender int,@Kind varchar(8),@Created datetime2,@Deleted datetime2(3);
 SELECT @Conv=ConversationId,@Sender=SenderId,@Kind=Kind,@Created=CreatedAt,@Deleted=DeletedAt FROM dbo.Messages WHERE MessageId=@MessageId;
 IF @Conv IS NULL OR dbo.CanUseConversation(@Conv,@UserId)=0 THROW 50001,'Message not found.',1;
 IF @Sender<>@UserId OR @Kind<>'Text' THROW 50003,'You can only edit your own messages.',1;
 IF @Deleted IS NOT NULL THROW 50002,'This message was deleted.',1;
 IF @Created<DATEADD(minute,-15,SYSUTCDATETIME()) THROW 50002,'Messages can only be edited for 15 minutes after sending.',1;
 BEGIN TRY
  OPEN SYMMETRIC KEY GameOnMessageKey DECRYPTION BY CERTIFICATE GameOnMessageCert;
  UPDATE dbo.Messages SET Body=NULL,BodyCipher=ENCRYPTBYKEY(KEY_GUID(N'GameOnMessageKey'),@Body,1,CONVERT(varbinary(8),@Conv)),EditedAt=SYSUTCDATETIME()
  WHERE MessageId=@MessageId;
  CLOSE SYMMETRIC KEY GameOnMessageKey;
 END TRY BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; THROW; END CATCH;
 EXEC dbo.GetMessageRow @MessageId;
END;
GO
-- Delete for everyone: the sender, or a group owner/admin for messages in their group. Content is erased.
CREATE OR ALTER PROCEDURE dbo.DeleteMessage @MessageId bigint,@UserId int AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Conv bigint,@Sender int,@Kind varchar(8),@Group int;
 SELECT @Conv=m.ConversationId,@Sender=m.SenderId,@Kind=m.Kind,@Group=c.GroupId FROM dbo.Messages m JOIN dbo.Conversations c ON c.ConversationId=m.ConversationId WHERE m.MessageId=@MessageId;
 IF @Conv IS NULL OR dbo.CanUseConversation(@Conv,@UserId)=0 THROW 50001,'Message not found.',1;
 IF @Kind<>'Text' THROW 50002,'Group notices cannot be deleted.',1;
 IF @Sender<>@UserId AND COALESCE(dbo.GroupRole(@Group,@UserId),'') NOT IN('Owner','Admin') THROW 50003,'You can only delete your own messages.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  DELETE dbo.MessageReactions WHERE MessageId=@MessageId;
  UPDATE dbo.Messages SET Body=NULL,BodyCipher=NULL,DeletedAt=COALESCE(DeletedAt,SYSUTCDATETIME()) WHERE MessageId=@MessageId;
  COMMIT;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
 EXEC dbo.GetMessageRow @MessageId;
END;
GO
-- One reaction per person per message; sending the same emoji again removes it, a different one replaces it.
CREATE OR ALTER PROCEDURE dbo.ReactToMessage @MessageId bigint,@UserId int,@Emoji nvarchar(16) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Conv bigint,@Deleted datetime2(3),@Kind varchar(8);
 SELECT @Conv=ConversationId,@Deleted=DeletedAt,@Kind=Kind FROM dbo.Messages WHERE MessageId=@MessageId;
 IF @Conv IS NULL OR dbo.CanUseConversation(@Conv,@UserId)=0 THROW 50001,'Message not found.',1;
 IF @Deleted IS NOT NULL OR @Kind<>'Text' THROW 50002,'You cannot react to this message.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  DECLARE @Current nvarchar(16)=(SELECT Emoji FROM dbo.MessageReactions WITH(UPDLOCK,HOLDLOCK) WHERE MessageId=@MessageId AND UserId=@UserId);
  IF @Current IS NOT NULL DELETE dbo.MessageReactions WHERE MessageId=@MessageId AND UserId=@UserId;
  IF @Current IS NULL OR @Current<>@Emoji INSERT dbo.MessageReactions(MessageId,UserId,Emoji) VALUES(@MessageId,@UserId,@Emoji);
  COMMIT;
 END TRY BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
 EXEC dbo.GetMessageRow @MessageId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ListConversations @UserId int WITH EXECUTE AS OWNER AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(100) c.ConversationId,c.Kind,c.GameId,c.ClubId,c.GroupId,c.LastMessageAt,
  CASE c.Kind WHEN 'Game' THEN s.Name+N' - '+FORMAT(dbo.ToBeirut(g.StartsAt),'ddd d MMM HH:mm') WHEN 'Club' THEN CASE WHEN c.UserLow=@UserId THEN cl.Name ELSE cl.Name+N' - '+pu.DisplayName END
   WHEN 'Group' THEN pg.Name ELSE (SELECT DisplayName FROM dbo.Users WHERE UserId=IIF(c.UserLow=@UserId,c.UserHigh,c.UserLow)) END AS Title,
  (SELECT TOP(1) CASE WHEN m.DeletedAt IS NOT NULL THEN N'Message deleted' ELSE LEFT(CONVERT(nvarchar(1000),COALESCE(m.Body,CONVERT(nvarchar(1000),DECRYPTBYKEYAUTOCERT(CERT_ID(N'GameOnMessageCert'),NULL,m.BodyCipher,1,CONVERT(varbinary(8),m.ConversationId))))),80) END
   FROM dbo.Messages m WHERE m.ConversationId=c.ConversationId ORDER BY m.MessageId DESC) AS LastMessage,
  (SELECT COUNT(*) FROM dbo.Messages m WHERE m.ConversationId=c.ConversationId AND m.SenderId<>@UserId AND m.Kind='Text' AND m.DeletedAt IS NULL
    AND m.MessageId>COALESCE((SELECT r.LastReadMessageId FROM dbo.ConversationReads r WHERE r.ConversationId=c.ConversationId AND r.UserId=@UserId),0)) AS Unread
 FROM dbo.Conversations c LEFT JOIN dbo.GamesAndEvents g ON g.EventId=c.GameId LEFT JOIN dbo.Subtypes s ON s.SubtypeId=g.SubtypeId
  LEFT JOIN dbo.Clubs cl ON cl.ClubId=c.ClubId LEFT JOIN dbo.Users pu ON pu.UserId=c.UserLow AND c.Kind='Club' LEFT JOIN dbo.PlayerGroups pg ON pg.GroupId=c.GroupId
 WHERE dbo.CanUseConversation(c.ConversationId,@UserId)=1 AND (c.LastMessageAt IS NOT NULL OR c.Kind NOT IN('Club') OR c.UserLow=@UserId)
 ORDER BY COALESCE(c.LastMessageAt,c.CreatedAt) DESC;
END;
GO

-- ======================================================================
-- Groups
-- ======================================================================
CREATE OR ALTER PROCEDURE dbo.CreatePlayerGroup @UserId int,@Name nvarchar(60),@MembersJson nvarchar(1000),@Description nvarchar(300)=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NULLIF(TRIM(@Name),N'') IS NULL OR ISJSON(@MembersJson)<>1 OR (SELECT COUNT(*) FROM OPENJSON(@MembersJson))>49 THROW 50002,'Name the group and add up to 49 friends.',1;
 IF (SELECT COUNT(*) FROM dbo.PlayerGroups WHERE OwnerId=@UserId)>=20 THROW 50004,'You can own up to 20 groups.',1;
 -- Only accepted friends can be added.
 IF EXISTS(SELECT 1 FROM OPENJSON(@MembersJson) j WHERE TRY_CONVERT(int,j.value) IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.Friendships f WHERE f.Status='Accepted'
  AND f.UserLow=IIF(@UserId<TRY_CONVERT(int,j.value),@UserId,TRY_CONVERT(int,j.value)) AND f.UserHigh=IIF(@UserId<TRY_CONVERT(int,j.value),TRY_CONVERT(int,j.value),@UserId)))
  THROW 50002,'Only your friends can be added to a group.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  INSERT dbo.PlayerGroups(Name,OwnerId,Description) VALUES(TRIM(@Name),@UserId,NULLIF(TRIM(@Description),N''));
  DECLARE @G int=SCOPE_IDENTITY();
  INSERT dbo.PlayerGroupMembers(GroupId,UserId,Role) VALUES(@G,@UserId,'Owner');
  INSERT dbo.PlayerGroupMembers(GroupId,UserId) SELECT DISTINCT @G,TRY_CONVERT(int,value) FROM OPENJSON(@MembersJson) WHERE TRY_CONVERT(int,value)<>@UserId;
  INSERT dbo.Conversations(Kind,GroupId) VALUES('Group',@G);
  DECLARE @Conv bigint=SCOPE_IDENTITY(),@Actor nvarchar(80)=(SELECT DisplayName FROM dbo.Users WHERE UserId=@UserId);
  DECLARE @Note nvarchar(300)=LEFT(@Actor+N' created the group "'+TRIM(@Name)+N'"',300);
  EXEC dbo.PostSystemMessage @Conv,@UserId,@Note;
  INSERT dbo.Notifications(UserId,Title,Body) SELECT m.UserId,N'Added to a group',LEFT(@Actor+N' added you to "'+TRIM(@Name)+N'". Open Chat to say hi.',800)
  FROM dbo.PlayerGroupMembers m WHERE m.GroupId=@G AND m.UserId<>@UserId;
  COMMIT;
  SELECT @G AS GroupId,@Conv AS ConversationId;
 END TRY BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ListMyGroups @UserId int AS
BEGIN
 SET NOCOUNT ON;
 SELECT g.GroupId,g.Name,g.Description,m.Role AS MyRole,CAST(CASE WHEN g.OwnerId=@UserId THEN 1 ELSE 0 END AS bit) AS IsOwner,
  (SELECT COUNT(*) FROM dbo.PlayerGroupMembers x WHERE x.GroupId=g.GroupId) AS Members,
  (SELECT ConversationId FROM dbo.Conversations c WHERE c.Kind='Group' AND c.GroupId=g.GroupId) AS ConversationId,
  (SELECT STRING_AGG(u.DisplayName,N', ') FROM dbo.PlayerGroupMembers x JOIN dbo.Users u ON u.UserId=x.UserId WHERE x.GroupId=g.GroupId) AS MemberNames,
  (SELECT '['+STRING_AGG(CONVERT(varchar(12),x.UserId),',')+']' FROM dbo.PlayerGroupMembers x WHERE x.GroupId=g.GroupId) AS MemberIdsJson
 FROM dbo.PlayerGroups g JOIN dbo.PlayerGroupMembers m ON m.GroupId=g.GroupId AND m.UserId=@UserId ORDER BY g.Name;
END;
GO
CREATE OR ALTER PROCEDURE dbo.GetGroupDetails @GroupId int,@UserId int AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @Me varchar(8)=dbo.GroupRole(@GroupId,@UserId);
 IF @Me IS NULL THROW 50001,'Group not found.',1;
 SELECT g.GroupId,g.Name,g.Description,g.OwnerId,g.CreatedAt,@Me AS MyRole,
  (SELECT ConversationId FROM dbo.Conversations c WHERE c.Kind='Group' AND c.GroupId=g.GroupId) AS ConversationId
 FROM dbo.PlayerGroups g WHERE g.GroupId=@GroupId;
 SELECT m.UserId,u.DisplayName,m.Role,m.AddedAt FROM dbo.PlayerGroupMembers m JOIN dbo.Users u ON u.UserId=m.UserId
 WHERE m.GroupId=@GroupId ORDER BY CASE m.Role WHEN 'Owner' THEN 0 WHEN 'Admin' THEN 1 ELSE 2 END,u.DisplayName;
END;
GO
-- Owner/admins add friends; owner removes anyone, admins remove members; anyone can leave.
-- When the owner leaves, ownership passes to the longest-serving admin, otherwise the longest-serving member.
CREATE OR ALTER PROCEDURE dbo.UpdateGroupMember @GroupId int,@ActorId int,@UserId int,@Add bit AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Name nvarchar(60)=(SELECT Name FROM dbo.PlayerGroups WHERE GroupId=@GroupId);
 IF @Name IS NULL THROW 50001,'Group not found.',1;
 DECLARE @ActorRole varchar(8)=dbo.GroupRole(@GroupId,@ActorId),@TargetRole varchar(8)=dbo.GroupRole(@GroupId,@UserId);
 IF @ActorRole IS NULL THROW 50003,'You are not in this group.',1;
 DECLARE @Conv bigint=(SELECT ConversationId FROM dbo.Conversations WHERE Kind='Group' AND GroupId=@GroupId);
 DECLARE @ActorName nvarchar(80)=(SELECT DisplayName FROM dbo.Users WHERE UserId=@ActorId),@TargetName nvarchar(80)=(SELECT DisplayName FROM dbo.Users WHERE UserId=@UserId);
 DECLARE @Note nvarchar(300);
 IF @TargetName IS NULL THROW 50001,'Player not found.',1;
 BEGIN TRY
  BEGIN TRANSACTION;
  IF @Add=1
  BEGIN
   IF @ActorRole NOT IN('Owner','Admin') THROW 50003,'Only group admins can add members.',1;
   IF @TargetRole IS NOT NULL THROW 50004,'They are already in this group.',1;
   IF NOT EXISTS(SELECT 1 FROM dbo.Friendships f WHERE f.Status='Accepted' AND f.UserLow=IIF(@ActorId<@UserId,@ActorId,@UserId) AND f.UserHigh=IIF(@ActorId<@UserId,@UserId,@ActorId))
    THROW 50002,'You can only add your own friends.',1;
   IF (SELECT COUNT(*) FROM dbo.PlayerGroupMembers WHERE GroupId=@GroupId)>=50 THROW 50004,'Groups have up to 50 members.',1;
   INSERT dbo.PlayerGroupMembers(GroupId,UserId) VALUES(@GroupId,@UserId);
   INSERT dbo.Notifications(UserId,Title,Body) VALUES(@UserId,N'Added to a group',LEFT(@ActorName+N' added you to "'+@Name+N'". Open Chat to say hi.',800));
   SET @Note=@ActorName+N' added '+@TargetName;
  END
  ELSE IF @ActorId=@UserId
  BEGIN
   DELETE dbo.PlayerGroupMembers WHERE GroupId=@GroupId AND UserId=@UserId;
   IF @ActorRole='Owner'
   BEGIN
    DECLARE @Next int=(SELECT TOP(1) UserId FROM dbo.PlayerGroupMembers WHERE GroupId=@GroupId ORDER BY CASE Role WHEN 'Admin' THEN 0 ELSE 1 END,AddedAt,UserId);
    IF @Next IS NOT NULL
    BEGIN
     UPDATE dbo.PlayerGroupMembers SET Role='Owner' WHERE GroupId=@GroupId AND UserId=@Next;
     UPDATE dbo.PlayerGroups SET OwnerId=@Next WHERE GroupId=@GroupId;
     SET @Note=@ActorName+N' left. '+(SELECT DisplayName FROM dbo.Users WHERE UserId=@Next)+N' is now the group owner';
    END
    ELSE SET @Note=@ActorName+N' left';
   END
   ELSE SET @Note=@ActorName+N' left';
  END
  ELSE
  BEGIN
   IF @TargetRole IS NULL THROW 50001,'They are not in this group.',1;
   IF NOT (@ActorRole='Owner' OR (@ActorRole='Admin' AND @TargetRole='Member')) THROW 50003,'Only the owner can remove admins; admins can remove members.',1;
   DELETE dbo.PlayerGroupMembers WHERE GroupId=@GroupId AND UserId=@UserId;
   SET @Note=@ActorName+N' removed '+@TargetName;
  END;
  EXEC dbo.PostSystemMessage @Conv,@ActorId,@Note;
  COMMIT;
  SELECT 'Saved' AS Status,@Conv AS ConversationId;
 END TRY BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
-- Only the owner promotes or demotes admins.
CREATE OR ALTER PROCEDURE dbo.SetGroupRole @GroupId int,@ActorId int,@UserId int,@Role varchar(8) AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @Role NOT IN('Admin','Member') THROW 50002,'Choose Admin or Member.',1;
 IF COALESCE(dbo.GroupRole(@GroupId,@ActorId),'')<>'Owner' THROW 50003,'Only the group owner can change admins.',1;
 DECLARE @Target varchar(8)=dbo.GroupRole(@GroupId,@UserId);
 IF @Target IS NULL THROW 50001,'They are not in this group.',1;
 IF @Target='Owner' THROW 50002,'The owner is always an admin.',1;
 DECLARE @Conv bigint=(SELECT ConversationId FROM dbo.Conversations WHERE Kind='Group' AND GroupId=@GroupId);
 DECLARE @Note nvarchar(300)=(SELECT DisplayName FROM dbo.Users WHERE UserId=@ActorId)
  +IIF(@Role='Admin',N' made ',N' removed ')+(SELECT DisplayName FROM dbo.Users WHERE UserId=@UserId)+IIF(@Role='Admin',N' an admin',N' as admin');
 BEGIN TRY
  BEGIN TRANSACTION;
  IF @Target<>@Role
  BEGIN
   UPDATE dbo.PlayerGroupMembers SET Role=@Role WHERE GroupId=@GroupId AND UserId=@UserId;
   EXEC dbo.PostSystemMessage @Conv,@ActorId,@Note;
  END;
  COMMIT;
  SELECT 'Saved' AS Status,@Conv AS ConversationId;
 END TRY BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
-- Owner/admins rename the group or change its description.
CREATE OR ALTER PROCEDURE dbo.UpdateGroupInfo @GroupId int,@ActorId int,@Name nvarchar(60),@Description nvarchar(300)=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET @Name=TRIM(@Name); SET @Description=NULLIF(TRIM(@Description),N'');
 IF NULLIF(@Name,N'') IS NULL THROW 50002,'Give the group a name.',1;
 IF COALESCE(dbo.GroupRole(@GroupId,@ActorId),'') NOT IN('Owner','Admin') THROW 50003,'Only group admins can edit the group.',1;
 DECLARE @OldName nvarchar(60),@OldDesc nvarchar(300);
 SELECT @OldName=Name,@OldDesc=Description FROM dbo.PlayerGroups WHERE GroupId=@GroupId;
 DECLARE @Conv bigint=(SELECT ConversationId FROM dbo.Conversations WHERE Kind='Group' AND GroupId=@GroupId);
 DECLARE @Actor nvarchar(80)=(SELECT DisplayName FROM dbo.Users WHERE UserId=@ActorId),@Note nvarchar(300);
 BEGIN TRY
  BEGIN TRANSACTION;
  UPDATE dbo.PlayerGroups SET Name=@Name,Description=@Description WHERE GroupId=@GroupId;
  IF @OldName<>@Name BEGIN SET @Note=LEFT(@Actor+N' renamed the group to "'+@Name+N'"',300); EXEC dbo.PostSystemMessage @Conv,@ActorId,@Note; END;
  IF COALESCE(@OldDesc,N'')<>COALESCE(@Description,N'') BEGIN SET @Note=@Actor+N' changed the group description'; EXEC dbo.PostSystemMessage @Conv,@ActorId,@Note; END;
  COMMIT;
  SELECT 'Saved' AS Status,@Conv AS ConversationId;
 END TRY BEGIN CATCH IF EXISTS(SELECT 1 FROM sys.openkeys WHERE key_name=N'GameOnMessageKey') CLOSE SYMMETRIC KEY GameOnMessageKey; IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH;
END;
GO
GRANT EXECUTE ON dbo.GetEmailStatus TO gameon_executor;
GRANT EXECUTE ON dbo.RequestEmailVerification TO gameon_executor;
GRANT EXECUTE ON dbo.VerifyEmail TO gameon_executor;
GRANT EXECUTE ON dbo.EditMessage TO gameon_executor;
GRANT EXECUTE ON dbo.DeleteMessage TO gameon_executor;
GRANT EXECUTE ON dbo.ReactToMessage TO gameon_executor;
GRANT EXECUTE ON dbo.GetGroupDetails TO gameon_executor;
GRANT EXECUTE ON dbo.SetGroupRole TO gameon_executor;
GRANT EXECUTE ON dbo.UpdateGroupInfo TO gameon_executor;
GO
SELECT 'Migration 36 completed successfully' AS Result;
GO
