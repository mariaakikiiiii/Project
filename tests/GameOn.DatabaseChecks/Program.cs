using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.SqlServer.TransactSql.ScriptDom;

// Grammar validation is separate from executing SQL against the database engine.
if (args.Contains("--syntax"))
{
    if (!Directory.Exists("database")) { Console.WriteLine("Run this command from the repository root."); return 2; }
    var failures = 0;
    foreach (var file in Directory.GetFiles("database", "*.sql").Order())
    {
        var sql = string.Join("\n", File.ReadAllLines(file).Where(line => !line.TrimStart().StartsWith(":")));
        using var reader = new StringReader(sql);
        new TSql160Parser(true).Parse(reader, out var errors);
        foreach (var error in errors) { Console.WriteLine($"{file}:{error.Line}: {error.Message}"); failures++; }
        if (errors.Count == 0) Console.WriteLine($"PASS syntax only: {Path.GetFileName(file)}");
    }
    return failures == 0 ? 0 : 1;
}

var connectionString = Environment.GetEnvironmentVariable("GAMEON_TEST_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString) || Environment.GetEnvironmentVariable("GAMEON_DISPOSABLE_TESTS") != "yes")
{
    Console.WriteLine("NOT RUN: securely configure GAMEON_TEST_CONNECTION_STRING and GAMEON_DISPOSABLE_TESTS=yes. Database name must end with _Tests.");
    return 2;
}
var builder = new SqlConnectionStringBuilder(connectionString);
if (!builder.InitialCatalog.EndsWith("_Tests", StringComparison.OrdinalIgnoreCase))
{
    Console.WriteLine("REFUSED: use a disposable upgraded database with a name ending in _Tests.");
    return 2;
}
var users = new List<int>(); var games = new List<int>(); var passed = 0;
SqlParameter P(string name, SqlDbType type, object value, int size = 0) =>
    size > 0 ? new SqlParameter(name, type, size) { Value = value } : new SqlParameter(name, type) { Value = value };
async Task<object?> Query(string text, bool procedure, params SqlParameter[] parameters)
{
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();
    await using var command = new SqlCommand(text, connection) { CommandType = procedure ? CommandType.StoredProcedure : CommandType.Text, CommandTimeout = 30 };
    foreach (var parameter in parameters) command.Parameters.Add(parameter);
    return await command.ExecuteScalarAsync();
}
void Check(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); passed++; Console.WriteLine("PASS: " + name); }
async Task Expect(int number, Func<Task<object?>> operation, string name)
{
    try { await operation(); throw new InvalidOperationException("Expected rejection: " + name); }
    catch (SqlException e) when (e.Number == number) { Check(true, name); }
}
async Task<object?> Join(int game, int user, bool sponsored = false, string payment = "Cash") =>
    await Query("dbo.sp_JoinGameOrActivity", true, P("@GameId", SqlDbType.Int, game), P("@UserId", SqlDbType.Int, user), P("@ClaimSponsored", SqlDbType.Bit, sponsored), P("@PaymentMethod", SqlDbType.VarChar, payment, 12));
async Task<int> Create(int type, int capacity, int sponsored = 0, decimal price = 0)
{
    var id = Convert.ToInt32(await Query("dbo.CreateGame", true, P("@HostUserId", SqlDbType.Int, users[0]), P("@SportId", SqlDbType.Int, type),
        P("@VenueId", SqlDbType.Int, Convert.ToInt32(await Query("SELECT MIN(VenueId) FROM dbo.Venues", false))),
        P("@StartsAt", SqlDbType.DateTime2, DateTime.UtcNow.AddDays(7)), P("@Capacity", SqlDbType.SmallInt, capacity),
        new SqlParameter("@CostPerPlayer", SqlDbType.Decimal) { Precision = 10, Scale = 2, Value = price }, P("@SponsoredSlots", SqlDbType.SmallInt, sponsored)));
    games.Add(id); return id;
}
try
{
    Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Categories WHERE Slug IN('sports','activities')", false)) == 2, "two category sections");
    Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Subtypes WHERE Slug IN('football','basketball','padel','tennis','volleyball','badminton','table-tennis','squash','swimming','paintball','laser-tag','icombat','escape-rooms','go-karting','bowling','archery-tag','airsoft')", false)) == 17, "all seventeen subtypes seeded");
    for (var i = 0; i < 4; i++) users.Add(Convert.ToInt32(await Query("INSERT dbo.Users(Email,DisplayName,PasswordHash) OUTPUT INSERTED.UserId VALUES(@Email,N'Database concurrency fixture',N'DISABLED_FIXTURE')", false,
        P("@Email", SqlDbType.NVarChar, $"{Guid.NewGuid():N}@concurrency.gameon.invalid", 254))));
    var sport = Convert.ToInt32(await Query("SELECT SubtypeId FROM dbo.Subtypes WHERE Slug='basketball'", false));
    var activity = Convert.ToInt32(await Query("SELECT SubtypeId FROM dbo.Subtypes WHERE Slug='paintball'", false));
    foreach (var type in new[] { sport, activity })
    {
        var game = await Create(type, 2);
        await using var holder = new SqlConnection(connectionString);
        await holder.OpenAsync();
        await using var transaction = (SqlTransaction)await holder.BeginTransactionAsync();
        await using var hold = new SqlCommand("SELECT EventId FROM dbo.GamesAndEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@Game", holder, transaction);
        hold.Parameters.Add(P("@Game", SqlDbType.Int, game));
        await hold.ExecuteScalarAsync();
        var first = Join(game, users[1]); var second = Join(game, users[2]);
        await Task.Delay(250);
        var bothBlocked = !first.IsCompleted && !second.IsCompleted;
        await transaction.CommitAsync();
        var results = await Task.WhenAll(first, second);
        Check(bothBlocked, "both join requests block on the same held event row");
        Check(results.Count(r => r?.ToString() == "Joined") == 1 && results.Count(r => r?.ToString() == "Waitlisted") == 1, "two independent connections competing for last spot");
        Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game", false, P("@Game", SqlDbType.Int, game))) == 2, "no overbooking");
        var joined = results[0]?.ToString() == "Joined" ? users[1] : users[2]; var waiting = joined == users[1] ? users[2] : users[1];
        await Query("dbo.CancelParticipation", true, P("@GameId", SqlDbType.Int, game), P("@UserId", SqlDbType.Int, joined));
        Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game AND UserId=@User", false, P("@Game", SqlDbType.Int, game), P("@User", SqlDbType.Int, waiting))) == 1, "cancel atomically promotes next queued person");
        await Join(game, waiting);
        Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game", false, P("@Game", SqlDbType.Int, game))) == 2, "duplicate join is idempotent");
        await Expect(50003, () => Query("dbo.CancelGame", true, P("@GameId", SqlDbType.Int, game), P("@HostUserId", SqlDbType.Int, users[3])), "non-host cancellation is rejected");
        Check((await Query("SELECT GameStatus FROM dbo.GamesAndEvents WHERE EventId=@Game", false, P("@Game", SqlDbType.Int, game)))?.ToString() == "Open", "rejected cancellation leaves event unchanged");
    }
    var coveredGame = await Create(activity, 3, 1, 10);
    async Task<string> Claim(int user) { try { return (await Join(coveredGame, user, true))!.ToString()!; } catch (SqlException e) when (e.Number == 50004) { return "Conflict"; } }
    var claims = await Task.WhenAll(Claim(users[1]), Claim(users[2]));
    Check(claims.Count(r => r == "Joined") == 1 && claims.Count(r => r == "Conflict") == 1, "last sponsored place cannot be double-claimed");
    Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.SponsoredSeats WHERE GameId=@Game", false, P("@Game", SqlDbType.Int, coveredGame))) == 1, "one sponsorship stored");
    await Expect(50005, () => Join(coveredGame, users[3], false, "Whish"), "unconfigured Whish cannot create a paid reservation");
    Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game AND UserId=@User", false, P("@Game", SqlDbType.Int, coveredGame), P("@User", SqlDbType.Int, users[3]))) == 0, "failed payment attempt leaves no participation");
    await Query("dbo.CancelGame", true, P("@GameId", SqlDbType.Int, coveredGame), P("@HostUserId", SqlDbType.Int, users[0]));
    await Expect(50002, () => Join(coveredGame, users[3]), "cancelled event rejects joins");
    if (Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.PlatformMigrations WHERE Version=13", false)) == 1)
    {
        var payGame = await Create(activity, 2, 0, 0.25m);
        async Task<Guid> Init(int user, string mode, Guid key) => (Guid)(await Query("dbo.InitializeCheckout", true,
            P("@GameId", SqlDbType.Int, payGame), P("@UserId", SqlDbType.Int, user), P("@Mode", SqlDbType.VarChar, mode, 12),
            P("@IdempotencyKey", SqlDbType.UniqueIdentifier, key), P("@ExpectedRevision", SqlDbType.Int, 1)))!;
        var firstPayment = await Init(users[1], "WhishMock", Guid.NewGuid());
        var secondPayment = await Init(users[2], "WhishMock", Guid.NewGuid());
        Check(await Query("dbo.GetPayment",true,P("@PaymentID",SqlDbType.UniqueIdentifier,firstPayment),P("@UserId",SqlDbType.Int,users[3])) is null,"payment lookup does not expose another user's checkout");
        var firstEvent = Guid.NewGuid(); var secondEvent = Guid.NewGuid();
        var firstHash = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        var secondHash = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        Task<object?> Confirm(Guid payment, Guid webhook, byte[] hash, decimal total) => Query("dbo.ApplyMockPaymentWebhook", true,
            P("@WebhookEventID", SqlDbType.UniqueIdentifier, webhook), P("@PaymentID", SqlDbType.UniqueIdentifier, payment),
            P("@GatewayTransactionID", SqlDbType.NVarChar, "mock_test_" + payment.ToString("N"), 128),
            P("@Outcome", SqlDbType.VarChar, "success", 12), new SqlParameter("@TotalAmount", SqlDbType.Decimal) { Precision=12,Scale=2,Value=total },
            P("@Currency", SqlDbType.Char, "USD", 3), P("@PayloadHash", SqlDbType.Binary, hash, 32));
        await Task.WhenAll(Confirm(firstPayment,firstEvent,firstHash,0.26m),Confirm(secondPayment,secondEvent,secondHash,0.26m));
        Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Payments WHERE GameID=@Game AND Status='MockSucceeded'", false,P("@Game",SqlDbType.Int,payGame)))==1,"two mock confirmations cannot both claim last spot");
        Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.Participations WHERE GameId=@Game",false,P("@Game",SqlDbType.Int,payGame)))==2,"mock confirmation preserves capacity");
        await Confirm(firstPayment,firstEvent,firstHash,0.26m);
        Check(Convert.ToInt32(await Query("SELECT COUNT(*) FROM dbo.PaymentWebhookEvents WHERE PaymentID=@Payment",false,P("@Payment",SqlDbType.UniqueIdentifier,firstPayment)))==1,"identical webhook replay has one stored event");
        await Expect(50002,()=>Confirm(firstPayment,Guid.NewGuid(),firstHash,99m),"signed callback with mismatched amount rejected");
    }
    Console.WriteLine($"PASS: {passed} database checks executed.");
    return 0;
}
catch (Exception e) { Console.WriteLine("FAIL: " + e.GetType().Name + (e is SqlException sql ? $" (SQL {sql.Number})" : ": " + e.Message)); return 1; }
finally
{
    foreach (var id in games)
        await Query("IF OBJECT_ID('dbo.Payments') IS NOT NULL BEGIN DELETE dbo.PaymentWebhookEvents WHERE PaymentID IN(SELECT PaymentID FROM dbo.Payments WHERE GameID=@Id); DELETE dbo.Payments WHERE GameID=@Id; END; DELETE dbo.UserActivityLogs WHERE EventId=@Id; DELETE dbo.Notifications WHERE GameId=@Id; DELETE dbo.GameActivityLogs WHERE GameId=@Id; DELETE dbo.Waitlists WHERE GameId=@Id; DELETE dbo.Participations WHERE GameId=@Id; DELETE dbo.GamesAndEvents WHERE EventId=@Id;", false, P("@Id", SqlDbType.Int, id));
    foreach (var id in users) await Query("DELETE dbo.Users WHERE UserId=@Id", false, P("@Id", SqlDbType.Int, id));
}
