-- OPTIONAL DEVELOPMENT DEMO ONLY. No real venue is automatically advertised.
-- Only the two original, synthetic lab venue addresses are eligible.
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;
INSERT dbo.SponsoredVenues(VenueID,Tier,StartDate,EndDate,IsActive)
 SELECT v.VenueId,CASE WHEN v.Name=N'Central Court' THEN 'Gold' ELSE 'Silver' END,
 DATEADD(day,-1,SYSUTCDATETIME()),DATEADD(day,30,SYSUTCDATETIME()),1
 FROM dbo.Venues v
 WHERE ((v.Name=N'Central Court' AND v.Address=N'Central sports complex') OR
        (v.Name=N'North Field' AND v.Address=N'North sports complex'))
 AND NOT EXISTS(SELECT 1 FROM dbo.SponsoredVenues s WHERE s.VenueID=v.VenueId);
COMMIT;
