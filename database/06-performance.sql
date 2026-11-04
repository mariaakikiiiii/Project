-- SSMS: enable Include Actual Execution Plan (Ctrl+M), then execute.
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
DECLARE @GameId int=(SELECT MIN(GameId) FROM dbo.GameActivityLogs),@From datetime2=DATEADD(day,-3,SYSUTCDATETIME()),@Until datetime2=SYSUTCDATETIME();
EXEC dbo.GetGameActivity @GameId,@From,@Until;
DECLARE @UserId int=(SELECT MIN(ActorUserId) FROM dbo.GameActivityLogs);
SELECT TOP(50) ActivityId,GameId,ActivityType,OccurredAt
FROM dbo.GameActivityLogs
WHERE ActorUserId=@UserId AND OccurredAt>=@From AND OccurredAt<@Until
ORDER BY OccurredAt DESC,ActivityId DESC;
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
