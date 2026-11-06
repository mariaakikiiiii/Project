-- Researched Lebanese venue starter list (data only). Requires migration 22.
-- Safe to rerun: inserts only venues that are not already present (matched by name + area); never updates or deletes.
-- Research date: 2026-11-06. This is NOT complete coverage of Lebanon.
-- Rules followed: nothing invented. "Verified" listing = an official source states the venue and its sports.
-- No contact is marked verified (IsVerified=0): an operator must phone the venue before deposits can be collected.
-- No prices, ratings, opening hours or availability are stored. ReservationMode is 'Unknown' unless a source says how to book.
USE GameOn;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=22) THROW 50002,'Install migration 22 first.',1;
DECLARE @v TABLE(Name nvarchar(120),Area nvarchar(80),Address nvarchar(250),Phone varchar(20),Listing varchar(12),SourceName nvarchar(120),SourceUrl nvarchar(400),Reservation varchar(16),Note nvarchar(400),Sports varchar(100));
INSERT @v VALUES
(N'Hariri Sports Complex (HFClub)',N'Saida',N'Saida, South Lebanon (street address not published on source)','+9617725285','Verified',N'Hariri Foundation (official)',N'https://hariri-foundation.org/programs/hariri-sports-complex/','Unknown',
 N'Official page lists indoor/outdoor courts for basketball, volleyball, football and tennis and phone +961 7 725 285. Booking method not stated: call to ask.','basketball,volleyball,football,tennis'),
(N'The Sports City (Aley)',N'Aley',N'Aley, Mount Lebanon (street address not published on source)',NULL,'Unverified',N'Municipality of Aley (official, 2006 article)',N'https://aley.gov.lb/en/details/449/','Unknown',
 N'Municipal page from 2006 lists football field, basketball and tennis courts and an Olympic pool. Current status and public access unconfirmed.','football,basketball,tennis,swimming'),
(N'Fouad Chehab Stadium',N'Jounieh',N'Jounieh, Keserwan (municipal stadium)',NULL,'Unverified',N'Wikipedia (secondary)',N'https://en.wikipedia.org/wiki/Fouad_Chehab_Stadium','Unknown',
 N'Municipal football stadium. Public pitch rental not confirmed; contact the Jounieh municipality.','football'),
(N'The Padel Club - Beirut Waterfront',N'Beirut',N'Beirut Waterfront, Beirut','+9613633833','Unverified',N'Lebanon Traveler / Beirut.com press (secondary)',N'https://www.lebanontraveler.com/?p=29065','ContactVenue',
 N'Press says courts are booked by phone or website. Phone is from press coverage, not yet confirmed by an operator.','padel'),
(N'Padel House - Jounieh',N'Jounieh',N'Jounieh (exact branch address not published on source)',NULL,'Unverified',N'Beiruting news (secondary, 2026)',N'https://www.beiruting.com/news/141167/','Unknown',
 N'2026 announcement lists Jounieh among Padel House branches (also Sin El Fil, Zalka, Kaslik). Confirm address and contact before use.','padel'),
(N'Padel House - Kaslik',N'Kaslik',N'Kaslik, Keserwan (exact address not published on source)',NULL,'Unverified',N'Beiruting news (secondary, 2026)',N'https://www.beiruting.com/news/141167/','Unknown',
 N'2026 announcement lists Kaslik among Padel House branches. Confirm address and contact before use.','padel');
BEGIN TRANSACTION;
DECLARE @n nvarchar(120),@a nvarchar(80),@id int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Name,Area FROM @v v WHERE NOT EXISTS(SELECT 1 FROM dbo.Venues x WHERE x.Name=v.Name AND x.Area=v.Area);
OPEN c; FETCH NEXT FROM c INTO @n,@a;
WHILE @@FETCH_STATUS=0
BEGIN
 INSERT dbo.Venues(Name,Area,Address,ContactPhoneNumber,IsVerified,ListingStatus,SourceName,SourceUrl,SourceCheckedOn,ReservationMode,DirectoryNote)
 SELECT Name,Area,Address,Phone,0,Listing,SourceName,SourceUrl,'20261106',Reservation,Note FROM @v WHERE Name=@n AND Area=@a;
 SET @id=SCOPE_IDENTITY();
 INSERT dbo.VenueSubtypes(VenueId,SubtypeId) SELECT @id,s.SubtypeId FROM @v v CROSS APPLY STRING_SPLIT(v.Sports,',') x JOIN dbo.Subtypes s ON s.Slug=x.value WHERE v.Name=@n AND v.Area=@a;
 FETCH NEXT FROM c INTO @n,@a;
END;
CLOSE c; DEALLOCATE c;
COMMIT;
SELECT Name,Area,ListingStatus,SourceCheckedOn FROM dbo.Venues WHERE SourceCheckedOn IS NOT NULL ORDER BY Area,Name;
