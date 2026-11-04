-- Run as DBA in GameOn, after provisioning gameon_api login externally.
-- Prefer integrated/managed authentication. For SQL authentication, provision a
-- generated password using a secret manager / secure DBA tooling, never this file.
CREATE USER gameon_api FOR LOGIN gameon_api;
CREATE ROLE gameon_executor;
ALTER ROLE gameon_executor ADD MEMBER gameon_api;
-- Individual grants ensure future admin procedures are not automatically exposed.
GRANT EXECUTE ON dbo.JoinGame TO gameon_executor;
GRANT EXECUTE ON dbo.CancelParticipation TO gameon_executor;
GRANT EXECUTE ON dbo.CreateGame TO gameon_executor;
GRANT EXECUTE ON dbo.DiscoverGames TO gameon_executor;
GRANT EXECUTE ON dbo.GetGame TO gameon_executor;
GRANT EXECUTE ON dbo.MyGames TO gameon_executor;
GRANT EXECUTE ON dbo.GetLookups TO gameon_executor;
GRANT EXECUTE ON dbo.RegisterUser TO gameon_executor;
GRANT EXECUTE ON dbo.FindUserForLogin TO gameon_executor;
-- No db_owner, db_datareader, db_datawriter or direct table permissions.
-- Static SQL and common dbo ownership permit stored-procedure ownership chaining.
