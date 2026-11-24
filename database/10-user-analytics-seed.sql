-- DEVELOPMENT/TEST ONLY. 200,000 synthetic events distributed across 256 fixture
-- users, 17 subtypes, four areas, five actions and 180 days. No real-user logs invented.
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
;WITH D(n) AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))v(n)),
 N AS(SELECT TOP(256) ROW_NUMBER()OVER(ORDER BY a.n,b.n,c.n) n FROM D a CROSS JOIN D b CROSS JOIN D c)
INSERT dbo.Users(Email,DisplayName,PasswordHash)
 SELECT N'analytics-'+CONVERT(nvarchar(10),n)+N'@fixtures.gameon.invalid',N'Analytics Fixture '+CONVERT(nvarchar(10),n),N'DISABLED_FIXTURE'
 FROM N WHERE NOT EXISTS(SELECT 1 FROM dbo.Users u WHERE u.Email=N'analytics-'+CONVERT(nvarchar(10),n)+N'@fixtures.gameon.invalid');
DECLARE @Remaining int=200000-(SELECT COUNT(*) FROM dbo.UserActivityLogs WHERE IsSynthetic=1);
IF @Remaining>0
BEGIN
 -- Materialise the fixture users/subtypes first: joining on window-function results directly
 -- made the optimiser recompute them per row (quadratic; 15+ minutes on SQL Server 2025).
 CREATE TABLE #U(rn int PRIMARY KEY,UserId int NOT NULL,total int NOT NULL);
 CREATE TABLE #S(rn int PRIMARY KEY,SubtypeId int NOT NULL,total int NOT NULL);
 INSERT #U SELECT ROW_NUMBER()OVER(ORDER BY UserId),UserId,COUNT(*)OVER() FROM dbo.Users WHERE Email LIKE N'analytics-%@fixtures.gameon.invalid';
 INSERT #S SELECT ROW_NUMBER()OVER(ORDER BY SubtypeId),SubtypeId,COUNT(*)OVER() FROM dbo.Subtypes;
 DECLARE @UT int=(SELECT MAX(total) FROM #U), @ST int=(SELECT MAX(total) FROM #S);
 ;WITH D(n) AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))v(n)),
 N AS(SELECT TOP(@Remaining) ROW_NUMBER()OVER(ORDER BY a.n,b.n,c.n,d.n,e.n,f.n) n FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d CROSS JOIN D e CROSS JOIN D f),
 U AS(SELECT * FROM #U),
 S AS(SELECT * FROM #S)
 INSERT dbo.UserActivityLogs(UserId,SubtypeId,Action,Area,OccurredAt,IsSynthetic)
 SELECT u.UserId,s.SubtypeId,
 CASE n.n%5 WHEN 0 THEN 'DiscoverySearch' WHEN 1 THEN 'EventViewed' WHEN 2 THEN 'FilterApplied' WHEN 3 THEN 'JoinAttempt' ELSE 'PaymentOptionsViewed' END,
 CASE n.n%4 WHEN 0 THEN N'Beirut' WHEN 1 THEN N'Jounieh' WHEN 2 THEN N'Tripoli' ELSE N'Saida' END,
 DATEADD(second,-CONVERT(int,(n.n*7919)%15552000),SYSUTCDATETIME()),1
 FROM N n JOIN U u ON u.rn=(n.n-1)%@UT+1 JOIN S s ON s.rn=(n.n-1)%@ST+1;
END;
COMMIT;
UPDATE STATISTICS dbo.UserActivityLogs WITH FULLSCAN;
SELECT COUNT_BIG(*) AS SyntheticAnalyticsRows FROM dbo.UserActivityLogs WHERE IsSynthetic=1;
