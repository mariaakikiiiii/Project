using System.Data;
using System.Globalization;
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.SqlClient;
using static Database;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 16384);
builder.Services.AddSingleton<Database>();
builder.Services.AddHttpClient("email", c => c.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddSingleton<ResetEmail>();
builder.Services.AddHostedService<ResetDelivery>();
builder.Services.Configure<PasswordHasherOptions>(o => o.IterationCount = 210000);
builder.Services.AddSingleton<IPasswordHasher<string>, PasswordHasher<string>>();
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme).AddCookie(o =>
{
    o.Cookie.Name = "GameOn.Session";
    o.Cookie.HttpOnly = true; o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    o.Cookie.SameSite = SameSiteMode.Strict;
    o.ExpireTimeSpan = TimeSpan.FromHours(8); o.SlidingExpiration = false;
    o.Events.OnValidatePrincipal = async ctx =>
    {
        if (!int.TryParse(ctx.Principal?.FindFirstValue(ClaimTypes.NameIdentifier), out var id)
            || !int.TryParse(ctx.Principal?.FindFirstValue("securityVersion"), out var version))
        { ctx.RejectPrincipal(); return; }
        var db = ctx.HttpContext.RequestServices.GetRequiredService<Database>();
        var rows = (await db.Call("dbo.CheckSession", ctx.HttpContext.RequestAborted, P("@UserId", SqlDbType.Int, id)))[0];
        if (rows.Count == 0 || Convert.ToInt32(rows[0]["securityVersion"]) != version) ctx.RejectPrincipal();
    };
    o.Events.OnRedirectToLogin = ctx => { ctx.Response.StatusCode = 401; return Task.CompletedTask; };
    o.Events.OnRedirectToAccessDenied = ctx => { ctx.Response.StatusCode = 403; return Task.CompletedTask; };
});
builder.Services.AddAuthorization();
builder.Services.AddAntiforgery(o => { o.HeaderName = "X-CSRF-TOKEN"; o.Cookie.SecurePolicy = CookieSecurePolicy.Always; });
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = 429; o.AddPolicy("auth", context =>
    System.Threading.RateLimiting.RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown", _ => new()
        { PermitLimit = 10, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});
var app = builder.Build();
app.Use(async (ctx, next) =>
{
    ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
    ctx.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
    ctx.Response.Headers["Cache-Control"] = "no-store";
    await next();
});
app.Use(async (ctx, next) =>
{
    try { await next(); }
    catch (BadHttpRequestException ex)
    { ctx.Response.StatusCode = ex.StatusCode; await ctx.Response.WriteAsJsonAsync(new { error = "Check the request format and field values." }); }
    catch (SqlException ex) when (ex.Number is 2601 or 2627)
    { ctx.Response.StatusCode = 409; await ctx.Response.WriteAsJsonAsync(new { error = "Record already exists." }); }
    catch (SqlException ex) when (ex.Number is 50003)
    { ctx.Response.StatusCode = 403; await ctx.Response.WriteAsJsonAsync(new { error = "Only the host can change this game." }); }
    catch (SqlException ex) when (ex.Number is 50004)
    { ctx.Response.StatusCode = 409; await ctx.Response.WriteAsJsonAsync(new { error = "This game changed. Refresh to see the latest details and available places." }); }
    catch (SqlException ex) when (ex.Number is 50001)
    { ctx.Response.StatusCode = 404; await ctx.Response.WriteAsJsonAsync(new { error = "Game not found." }); }
    catch (SqlException ex) when (ex.Number is 50002 or 547)
    { ctx.Response.StatusCode = 400; await ctx.Response.WriteAsJsonAsync(new { error = ex.Number == 50002 ? ex.Message : "Invalid game, user, sport or venue." }); }
    catch (SqlException ex) when (ex.Number is 1205 or -2)
    { ctx.Response.StatusCode = 503; await ctx.Response.WriteAsJsonAsync(new { error = "Database busy; retry the request." }); }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        app.Logger.LogError("Request failed ({ErrorType})", ex.GetType().Name);
        ctx.Response.StatusCode = 500;
        await ctx.Response.WriteAsJsonAsync(new { error = "Request failed. Check server configuration and logs." });
    }
});
app.UseAuthentication(); app.UseAuthorization(); app.UseRateLimiter();
app.Use(async (ctx, next) =>
{
    if (!HttpMethods.IsGet(ctx.Request.Method) && !HttpMethods.IsHead(ctx.Request.Method) && !HttpMethods.IsOptions(ctx.Request.Method))
    {
        try { await ctx.RequestServices.GetRequiredService<IAntiforgery>().ValidateRequestAsync(ctx); }
        catch (AntiforgeryValidationException)
        { ctx.Response.StatusCode = 400; await ctx.Response.WriteAsJsonAsync(new { error = "Refresh the page and retry (CSRF token expired)." }); return; }
    }
    await next();
});
app.MapGet("/api/csrf", (HttpContext c, IAntiforgery anti) =>
    Results.Ok(new { token = anti.GetAndStoreTokens(c).RequestToken }));
app.MapPost("/api/auth/register", async (Register input, Database db, IPasswordHasher<string> hasher, CancellationToken ct) =>
{
    if (!ValidEmail(input.Email) || string.IsNullOrWhiteSpace(input.DisplayName) || input.DisplayName.Length > 80
        || input.Password is null || input.Password.Length < 12 || input.Password.Length > 128)
        return Results.BadRequest(new { error = "Use a valid email, name (1–80 characters), and password (12–128 characters)." });
    var email = input.Email.Trim().ToLowerInvariant();
    await db.Call("dbo.RegisterUser", ct, P("@Email", SqlDbType.NVarChar, email, 254),
        P("@DisplayName", SqlDbType.NVarChar, input.DisplayName.Trim(), 80),
        P("@PasswordHash", SqlDbType.NVarChar, hasher.HashPassword(email, input.Password), 512));
    return Results.Ok(new { message = "Registered. Sign in to continue." });
}).RequireRateLimiting("auth");
app.MapPost("/api/auth/login", async (Login input, HttpContext ctx, Database db, IPasswordHasher<string> hasher, CancellationToken ct) =>
{
    if (!ValidEmail(input.Email) || input.Password is null || input.Password.Length > 128)
        return Results.BadRequest(new { error = "Invalid credentials." });
    string email = input.Email.Trim().ToLowerInvariant();
    var rows = (await db.Call("dbo.FindUserForLogin", ct, P("@Email", SqlDbType.NVarChar, email, 254)))[0];
    // Always perform password work, including for unknown emails and disabled fixtures.
    string dummy = hasher.HashPassword(email, Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)));
    var row = rows.FirstOrDefault();
    string hash = row?["passwordHash"]?.ToString() ?? dummy;
    if (hash == "DISABLED_FIXTURE") hash = dummy;
    var result = hasher.VerifyHashedPassword(email, hash, input.Password);
    if (row is null || row["passwordHash"]?.ToString() == "DISABLED_FIXTURE" || result == PasswordVerificationResult.Failed)
        return Results.Json(new { error = "Invalid credentials." }, statusCode: 401);
    var identity = new ClaimsIdentity(new[] {
        new Claim(ClaimTypes.NameIdentifier, row["userId"]!.ToString()!),
        new Claim(ClaimTypes.Name, row["displayName"]!.ToString()!),
        new Claim("securityVersion", row["securityVersion"]!.ToString()!)
    }, CookieAuthenticationDefaults.AuthenticationScheme);
    await ctx.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, new ClaimsPrincipal(identity));
    return Results.Ok(new { name = row["displayName"] });
}).RequireRateLimiting("auth");
app.MapPost("/api/auth/logout", async (HttpContext ctx) => { await ctx.SignOutAsync(); return Results.NoContent(); }).RequireAuthorization();
app.MapGet("/api/auth/me", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
{
    var profile = (await db.Call("dbo.GetProfile", ct, P("@UserId", SqlDbType.Int, UserId(u))))[0][0];
    return Results.Ok(new { name = profile["displayName"], userId = UserId(u) });
}).RequireAuthorization();
app.MapGet("/api/lookups", async (Database db, CancellationToken ct) =>
{
    var sets = await db.Call("dbo.GetLookups", ct);
    return Results.Ok(new { sports = sets[0], venues = sets[1] });
});
app.MapGet("/api/games", async (int? sportId, string? date, string? area, bool? freeOnly, ClaimsPrincipal user, Database db, CancellationToken ct) =>
{
    DateTime? day = null;
    if (!string.IsNullOrEmpty(date))
    {
        if (!DateTime.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
            return Results.BadRequest(new { error = "Date must be YYYY-MM-DD (UTC)." });
        if (parsed.Year >= 9999) return Results.BadRequest(new { error = "Choose a supported date." });
        day = parsed;
    }
    if (area?.Length > 80) return Results.BadRequest(new { error = "Area is too long." });
    return Results.Ok((await db.Call("dbo.DiscoverGames", ct,
        P("@SportId", SqlDbType.Int, sportId), P("@Date", SqlDbType.Date, day),
        P("@Area", SqlDbType.NVarChar, string.IsNullOrWhiteSpace(area) ? null : area, 80),
        P("@UserId", SqlDbType.Int, user.Identity?.IsAuthenticated == true ? UserId(user) : null),
        P("@FreeOnly", SqlDbType.Bit, freeOnly ?? false)))[0]);
});
app.MapGet("/api/games/{id:int}", async (int id, Database db, CancellationToken ct) =>
{
    var sets = await db.Call("dbo.GetGame", ct, P("@GameId", SqlDbType.Int, id));
    return sets[0].Count == 0 ? Results.NotFound() : Results.Ok(new { game = sets[0][0], roster = sets[1] });
});
app.MapGet("/api/me/games", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
    Results.Ok((await db.Call("dbo.MyGames", ct, P("@UserId", SqlDbType.Int, UserId(user))))[0])).RequireAuthorization();
app.MapPost("/api/games", async (NewGame input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
{
    if (!PlatformEndpoints.ValidGame(input.StartsAt, input.Capacity, input.Description, input.CostPerPlayer, input.Currency, input.SponsoredSlots))
        return Results.BadRequest(new { error = "Choose a future start and capacity from 2 to 100." });
    var rows = (await db.Call("dbo.CreateGame", ct,
        P("@HostUserId", SqlDbType.Int, UserId(user)), P("@SportId", SqlDbType.Int, input.SportId),
        P("@VenueId", SqlDbType.Int, input.VenueId), P("@StartsAt", SqlDbType.DateTime2, input.StartsAt.UtcDateTime),
        P("@Capacity", SqlDbType.SmallInt, input.Capacity), P("@Description", SqlDbType.NVarChar, input.Description ?? "", 1000),
        PlatformEndpoints.Price(input.CostPerPlayer), P("@Currency", SqlDbType.Char, input.Currency, 3),
        P("@SponsoredSlots", SqlDbType.SmallInt, input.SponsoredSlots)))[0];
    return Results.Created($"/api/games/{rows[0]["gameId"]}", rows[0]);
}).RequireAuthorization();
app.MapPost("/api/games/{id:int}/join", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
    Results.Ok((await db.Call("dbo.JoinGame", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, UserId(u))))[0][0])).RequireAuthorization();
app.MapDelete("/api/games/{id:int}/participation", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
    Results.Ok((await db.Call("dbo.CancelParticipation", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, UserId(u))))[0][0])).RequireAuthorization();
app.MapPlatform();
app.Run();
static int UserId(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);
static bool ValidEmail(string? email) => email is not null && email.Length <= 254
    && System.Net.Mail.MailAddress.TryCreate(email.Trim(), out var address) && address.Address == email.Trim();
record Register(string Email, string DisplayName, string Password);
record Login(string Email, string Password);
record NewGame(int SportId, int VenueId, DateTimeOffset StartsAt, short Capacity, string? Description = "", decimal CostPerPlayer = 0, string Currency = "USD", short SponsoredSlots = 0);
