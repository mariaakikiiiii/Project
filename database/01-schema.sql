-- Run in an empty GameOn database (created by a DBA), using a migration account.
SET XACT_ABORT ON;
BEGIN TRANSACTION;
CREATE TABLE dbo.Users (
 UserId int IDENTITY CONSTRAINT PK_Users PRIMARY KEY,
 Email nvarchar(254) NOT NULL CONSTRAINT UQ_Users_Email UNIQUE,
 DisplayName nvarchar(80) NOT NULL,
 PasswordHash nvarchar(512) NOT NULL,
 CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Users_Created DEFAULT SYSUTCDATETIME()
);
CREATE TABLE dbo.Sports (
 SportId int IDENTITY CONSTRAINT PK_Sports PRIMARY KEY,
 Name nvarchar(40) NOT NULL CONSTRAINT UQ_Sports_Name UNIQUE
);
CREATE TABLE dbo.Venues (
 VenueId int IDENTITY CONSTRAINT PK_Venues PRIMARY KEY,
 Name nvarchar(120) NOT NULL,
 Area nvarchar(80) NOT NULL,
 Address nvarchar(250) NOT NULL
);
CREATE TABLE dbo.Games (
 GameId int IDENTITY CONSTRAINT PK_Games PRIMARY KEY,
 HostUserId int NOT NULL CONSTRAINT FK_Games_Host REFERENCES dbo.Users(UserId),
 SportId int NOT NULL CONSTRAINT FK_Games_Sport REFERENCES dbo.Sports(SportId),
 VenueId int NOT NULL CONSTRAINT FK_Games_Venue REFERENCES dbo.Venues(VenueId),
 StartsAt datetime2(3) NOT NULL,
 Capacity smallint NOT NULL CONSTRAINT CK_Games_Capacity CHECK (Capacity BETWEEN 2 AND 100),
 CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Games_Created DEFAULT SYSUTCDATETIME()
);
-- No destructive cascades: users, games and audit history cannot disappear accidentally.
CREATE TABLE dbo.Participations (
 GameId int NOT NULL CONSTRAINT FK_Participations_Game REFERENCES dbo.Games(GameId),
 UserId int NOT NULL CONSTRAINT FK_Participations_User REFERENCES dbo.Users(UserId),
 JoinedAt datetime2(3) NOT NULL CONSTRAINT DF_Participations_Joined DEFAULT SYSUTCDATETIME(),
 CONSTRAINT PK_Participations PRIMARY KEY(GameId, UserId)
);
CREATE TABLE dbo.Waitlists (
 WaitlistId bigint IDENTITY CONSTRAINT PK_Waitlists PRIMARY KEY,
 GameId int NOT NULL CONSTRAINT FK_Waitlists_Game REFERENCES dbo.Games(GameId),
 UserId int NOT NULL CONSTRAINT FK_Waitlists_User REFERENCES dbo.Users(UserId),
 QueuedAt datetime2(3) NOT NULL CONSTRAINT DF_Waitlists_Queued DEFAULT SYSUTCDATETIME(),
 CONSTRAINT UQ_Waitlists_Game_User UNIQUE(GameId, UserId)
);
CREATE INDEX IX_Waitlists_FIFO ON dbo.Waitlists(GameId,WaitlistId) INCLUDE(UserId,QueuedAt);
CREATE INDEX IX_Participations_User ON dbo.Participations(UserId,GameId);
CREATE INDEX IX_Waitlists_User ON dbo.Waitlists(UserId,GameId) INCLUDE(WaitlistId);
CREATE INDEX IX_Games_Discovery ON dbo.Games(StartsAt, SportId) INCLUDE(VenueId,Capacity,HostUserId);
CREATE INDEX IX_Venues_Area ON dbo.Venues(Area,VenueId) INCLUDE(Name);
CREATE TABLE dbo.GameActivityLogs (
 ActivityId bigint IDENTITY CONSTRAINT PK_GameActivityLogs PRIMARY KEY CLUSTERED,
 GameId int NOT NULL CONSTRAINT FK_Activity_Game REFERENCES dbo.Games(GameId),
 ActorUserId int NOT NULL CONSTRAINT FK_Activity_User REFERENCES dbo.Users(UserId),
 ActivityType varchar(20) NOT NULL CONSTRAINT CK_Activity_Type CHECK
  (ActivityType IN ('Created','Joined','Waitlisted','Cancelled','Promoted','LeftWaitlist')),
 OccurredAt datetime2(3) NOT NULL CONSTRAINT DF_Activity_Time DEFAULT SYSUTCDATETIME(),
 Details nvarchar(400) NULL
);
CREATE INDEX IX_Activity_Game_Time ON dbo.GameActivityLogs(GameId,OccurredAt DESC,ActivityId DESC)
 INCLUDE(ActorUserId,ActivityType);
CREATE INDEX IX_Activity_User_Time ON dbo.GameActivityLogs(ActorUserId,OccurredAt DESC,ActivityId DESC)
 INCLUDE(GameId,ActivityType);
COMMIT;
GO
-- Counts are derived, never duplicated in a mutable PlayerCount column.
CREATE VIEW dbo.GameSummary AS
SELECT g.GameId,g.HostUserId,g.SportId,g.VenueId,g.StartsAt,g.Capacity,
 s.Name AS Sport,v.Name AS Venue,v.Area,
 (SELECT COUNT(*) FROM dbo.Participations p WHERE p.GameId=g.GameId) AS PlayerCount
FROM dbo.Games g JOIN dbo.Sports s ON s.SportId=g.SportId
JOIN dbo.Venues v ON v.VenueId=g.VenueId;
GO
CREATE FUNCTION dbo.WaitlistPosition(@GameId int,@UserId int)
RETURNS bigint
AS
BEGIN
 RETURN (SELECT COUNT_BIG(*) FROM dbo.Waitlists w
 WHERE w.GameId=@GameId AND w.WaitlistId <=
 (SELECT mine.WaitlistId FROM dbo.Waitlists mine WHERE mine.GameId=@GameId AND mine.UserId=@UserId));
END;
GO
