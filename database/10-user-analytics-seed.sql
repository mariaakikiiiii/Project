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
 ;WITH D(n) AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))v(n)),
 N AS(SELECT TOP(@Remaining) ROW_NUMBER()OVER(ORDER BY a.n,b.n,c.n,d.n,e.n,f.n) n FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d CROSS JOIN D e CROSS JOIN D f),
 U AS(SELECT UserId,ROW_NUMBER()OVER(ORDER BY UserId) rn,COUNT(*)OVER() total FROM dbo.Users WHERE Email LIKE N'analytics-%@fixtures.gameon.invalid'),
 S AS(SELECT SubtypeId,ROW_NUMBER()OVER(ORDER BY SubtypeId) rn,COUNT(*)OVER() total FROM dbo.Subtypes)
 INSERT dbo.UserActivityLogs(UserId,SubtypeId,Action,Area,OccurredAt,IsSynthetic)
 SELECT u.UserId,s.SubtypeId,
 CASE n.n%5 WHEN 0 THEN 'DiscoverySearch' WHEN 1 THEN 'EventViewed' WHEN 2 THEN 'FilterApplied' WHEN 3 THEN 'JoinAttempt' ELSE 'PaymentOptionsViewed' END,
 CASE n.n%4 WHEN 0 THEN N'Beirut' WHEN 1 THEN N'Jounieh' WHEN 2 THEN N'Tripoli' ELSE N'Saida' END,
 DATEADD(second,-CONVERT(int,(n.n*7919)%15552000),SYSUTCDATETIME()),1
 FROM N n JOIN U u ON u.rn=(n.n-1)%u.total+1 JOIN S s ON s.rn=(n.n-1)%s.total+1;
END;
COMMIT;
UPDATE STATISTICS dbo.UserActivityLogs WITH FULLSCAN;
SELECT COUNT_BIG(*) AS SyntheticAnalyticsRows FROM dbo.UserActivityLogs WHERE IsSynthetic=1;
