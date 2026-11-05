-- Enable Actual Execution Plan (Ctrl+M) in SSMS. Measure, do not assume timings.
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
DECLARE @UserId int=(SELECT MIN(UserId) FROM dbo.UserActivityLogs WHERE IsSynthetic=1),
 @SubtypeId int=(SELECT MIN(SubtypeId) FROM dbo.Subtypes),
 @From datetime2=DATEADD(day,-30,SYSUTCDATETIME()),@Until datetime2=SYSUTCDATETIME();
SELECT TOP(50) LogId,SubtypeId,Action,Area,OccurredAt
FROM dbo.UserActivityLogs WHERE UserId=@UserId AND OccurredAt>=@From AND OccurredAt<@Until
ORDER BY OccurredAt DESC,LogId DESC;
SELECT TOP(50) LogId,UserId,Action,Area,OccurredAt
FROM dbo.UserActivityLogs WHERE SubtypeId=@SubtypeId AND OccurredAt>=@From AND OccurredAt<@Until
ORDER BY OccurredAt DESC,LogId DESC;
SELECT CONVERT(date,OccurredAt) AS Day,Action,COUNT_BIG(*) AS Events
FROM dbo.UserActivityLogs WHERE OccurredAt>=@From AND OccurredAt<@Until
GROUP BY CONVERT(date,OccurredAt),Action ORDER BY Day;
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
