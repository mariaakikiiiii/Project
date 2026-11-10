using System.Data;
using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using static Database;

// Migration 27: clubs & courts, classes & coaches, public/private games with approval,
// friends & chat (real-time via SignalR), loyalty points, rewards and GameOn Pro.
// Every rule that protects money, places or privacy lives in SQL; these endpoints validate shape and forward.
[Authorize]
public sealed class LiveHub : Hub
{
    // Each signed-in browser joins its own user group. The server pushes chat messages to every member's group,
    // so a client never chooses which conversation it listens to (no way to subscribe to someone else's chat).
    public override async Task OnConnectedAsync()
    {
        var id = Context.User?.FindFirstValue(ClaimTypes.NameIdentifier);
        if (id is not null) await Groups.AddToGroupAsync(Context.ConnectionId, "user:" + id);
        await base.OnConnectedAsync();
    }
}

public static class CommunityEndpoints
{
    private static int Id(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);
    private static int? MaybeId(ClaimsPrincipal u) => u.Identity?.IsAuthenticated == true ? Id(u) : null;
    private static Microsoft.Data.SqlClient.SqlParameter Dec(string name, decimal? v, byte precision = 10) => new(name, SqlDbType.Decimal) { Precision = precision, Scale = 2, Value = (object?)v ?? DBNull.Value };
    private static bool Money(decimal v, decimal max = 10000) => v >= 0 && v <= max && decimal.Round(v, 2) == v;
    private static IResult Bad(string error) => Results.BadRequest(new { error });

    public static void MapCommunity(this WebApplication app)
    {
        app.MapHub<LiveHub>("/hubs/live");

        // ---------- Clubs, courts, schedule ----------
        app.MapGet("/api/clubs", async (int? subtypeId, string? q, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (q?.Length > 80) return Bad("Search is too long.");
            var s = await db.Call("dbo.ListClubs", ct, P("@SubtypeId", SqlDbType.Int, subtypeId), P("@Query", SqlDbType.NVarChar, q, 80), P("@UserId", SqlDbType.Int, MaybeId(u)));
            return Results.Ok(new { clubs = s[0], myClubs = s[1] });
        }).RequireRateLimiting("browse");

        app.MapGet("/api/clubs/{id:int}/schedule", async (int id, string date, int? courtId, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (!DateOnly.TryParseExact(date, "yyyy-MM-dd", out var day) || day < DateOnly.FromDateTime(DateTime.UtcNow.AddDays(-1)) || day > DateOnly.FromDateTime(DateTime.UtcNow.AddDays(62)))
                return Bad("Choose a date within the next 60 days.");
            var s = await db.Call("dbo.GetCourtSchedule", ct, P("@ClubId", SqlDbType.Int, id), P("@Day", SqlDbType.Date, day.ToDateTime(TimeOnly.MinValue)),
                P("@UserId", SqlDbType.Int, MaybeId(u)), P("@CourtId", SqlDbType.Int, courtId));
            return Results.Ok(new { slots = s[0], classes = s.Count > 1 ? s[1] : [] });
        }).RequireRateLimiting("browse");

        app.MapPost("/api/courts/{id:int}/bookings", async (int id, CourtBookingInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (i.IdempotencyKey == Guid.Empty || i.RewardCode is { Length: not 10 } || i.GuestName?.Length > 80) return Bad("Refresh and try again.");
            var r = (await db.Call("dbo.BookCourt", ct, P("@CourtId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(u)),
                P("@StartsAtUtc", SqlDbType.DateTime2, i.StartsAtUtc.UtcDateTime), P("@Key", SqlDbType.UniqueIdentifier, i.IdempotencyKey),
                P("@RedemptionCode", SqlDbType.Char, i.RewardCode?.ToUpperInvariant(), 10), P("@GuestName", SqlDbType.NVarChar, string.IsNullOrWhiteSpace(i.GuestName) ? null : i.GuestName.Trim(), 80), P("@PayFromWallet", SqlDbType.Bit, i.PayFromWallet)))[0][0];
            return Results.Ok(r);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapDelete("/api/court-bookings/{id:long}", async (long id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.CancelCourtBooking", ct, P("@BookingId", SqlDbType.BigInt, id), P("@UserId", SqlDbType.Int, Id(u))))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapGet("/api/me/court-bookings", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.MyCourtBookings", ct, P("@UserId", SqlDbType.Int, Id(u)));
            return Results.Ok(new { bookings = s[0], classes = s[1] });
        }).RequireAuthorization();

        app.MapPost("/api/classes/{id:int}/registration", async (int id, ClassRegistrationInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.RegisterForClass", ct, P("@ClassId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(u)), P("@Cancel", SqlDbType.Bit, i.Cancel)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Club management (role checks in SQL: Owner 4, Manager 3, Reception 2, Coach 1) ----------
        app.MapPost("/api/operator/clubs", async (NewClubInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(i.Name) || i.Name.Length > 120 || i.ProDiscountPct > 50 || string.IsNullOrWhiteSpace(i.OwnerEmail)) return Bad("Enter the club name, venue, owner email and a Pro discount of 0–50%.");
            var owner = (await db.Call("dbo.FindUserForLogin", ct, P("@Email", SqlDbType.NVarChar, i.OwnerEmail.Trim().ToLowerInvariant(), 254)))[0].FirstOrDefault();
            if (owner is null) return Bad("The owner must sign up on GameOn first, with that email.");
            return Results.Ok((await db.Call("dbo.CreateClub", ct, P("@OperatorId", SqlDbType.Int, Id(u)), P("@VenueId", SqlDbType.Int, i.VenueId), P("@Name", SqlDbType.NVarChar, i.Name.Trim(), 120),
                P("@OwnerUserId", SqlDbType.Int, owner["userId"]), P("@IsPartner", SqlDbType.Bit, i.IsPartner), P("@ProDiscountPct", SqlDbType.TinyInt, i.ProDiscountPct)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/clubs/{id:int}/staff", async (int id, StaffInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(i.Email) || i.Role is not (null or "Manager" or "Reception" or "Coach")) return Bad("Enter the staff member's GameOn email and a role.");
            var user = (await db.Call("dbo.FindUserForLogin", ct, P("@Email", SqlDbType.NVarChar, i.Email.Trim().ToLowerInvariant(), 254)))[0].FirstOrDefault();
            if (user is null) return Bad("No GameOn account with that email. Ask them to sign up first.");
            return Results.Ok((await db.Call("dbo.SetClubStaff", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, user["userId"]), P("@Role", SqlDbType.VarChar, i.Role, 12)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/clubs/{id:int}/courts", async (int id, CourtInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(i.Name) || i.Name.Length > 80 || !Money(i.BasePrice) || !Money(i.PeakPrice) || i.SlotMinutes is not (30 or 60 or 90 or 120)
                || i.OpenHour >= i.CloseHour || i.CloseHour > 24 || i.PeakStartHour > i.PeakEndHour || i.PeakEndHour > 24) return Bad("Check the court name, opening hours, slot length and prices.");
            return Results.Ok((await db.Call("dbo.SaveCourt", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@CourtId", SqlDbType.Int, i.CourtId),
                P("@Name", SqlDbType.NVarChar, i.Name.Trim(), 80), P("@SubtypeId", SqlDbType.Int, i.SubtypeId), P("@SlotMinutes", SqlDbType.SmallInt, i.SlotMinutes),
                P("@OpenHour", SqlDbType.TinyInt, i.OpenHour), P("@CloseHour", SqlDbType.TinyInt, i.CloseHour), Dec("@BasePrice", i.BasePrice), Dec("@PeakPrice", i.PeakPrice),
                P("@PeakStartHour", SqlDbType.TinyInt, i.PeakStartHour), P("@PeakEndHour", SqlDbType.TinyInt, i.PeakEndHour), P("@IsActive", SqlDbType.Bit, i.IsActive)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/courts/{id:int}/block-toggle", async (int id, BlockInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Reason?.Length > 120 ? Bad("Keep the reason short.") :
            Results.Ok((await db.Call("dbo.ToggleCourtBlock", ct, P("@CourtId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)),
                P("@StartsAtUtc", SqlDbType.DateTime2, i.StartsAtUtc.UtcDateTime), P("@Reason", SqlDbType.NVarChar, i.Reason, 120)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/clubs/{id:int}/classes", async (int id, ClassSeriesInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(i.Title) || i.Title.Length > 120 || i.Weeks is < 1 or > 26 || i.Capacity is < 1 or > 60 || i.DurationMinutes is < 30 or > 240 || !Money(i.Price))
                return Bad("Check the class title, capacity (1–60), duration (30–240 min), price and weeks (1–26).");
            return Results.Ok((await db.Call("dbo.CreateClassSeries", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@Title", SqlDbType.NVarChar, i.Title.Trim(), 120),
                P("@SubtypeId", SqlDbType.Int, i.SubtypeId), P("@CourtId", SqlDbType.Int, i.CourtId), P("@CoachUserId", SqlDbType.Int, i.CoachUserId),
                P("@FirstStartsAtUtc", SqlDbType.DateTime2, i.FirstStartsAtUtc.UtcDateTime), P("@DurationMinutes", SqlDbType.SmallInt, i.DurationMinutes),
                P("@Capacity", SqlDbType.SmallInt, i.Capacity), Dec("@Price", i.Price), P("@Weeks", SqlDbType.TinyInt, i.Weeks)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapGet("/api/clubs/{id:int}/dashboard", async (int id, int? days, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.GetClubDashboard", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@Days", SqlDbType.Int, days ?? 30));
            return Results.Ok(new { summary = s[0][0], daily = s[1], byHour = s[2], expenses = s[3], courts = s[4], staff = s[5] });
        }).RequireAuthorization();

        app.MapPost("/api/clubs/{id:int}/expenses", async (int id, ExpenseInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (!Money(i.Amount, 1000000) || i.Amount == 0 || i.Note?.Length > 200) return Bad("Enter a positive amount.");
            return Results.Ok((await db.Call("dbo.AddClubExpense", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), Dec("@Amount", i.Amount, 12),
                P("@Category", SqlDbType.VarChar, i.Category, 16), P("@SpentOn", SqlDbType.Date, i.SpentOn.ToDateTime(TimeOnly.MinValue)), P("@Note", SqlDbType.NVarChar, i.Note, 200)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Coaches ----------
        app.MapGet("/api/coaches", async (int? subtypeId, string? area, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (area?.Length > 80) return Bad("Area is too long.");
            var s = await db.Call("dbo.ListCoaches", ct, P("@SubtypeId", SqlDbType.Int, subtypeId), P("@Area", SqlDbType.NVarChar, area, 80), P("@UserId", SqlDbType.Int, MaybeId(u)));
            return Results.Ok(new { coaches = s[0], mine = s[1].FirstOrDefault() });
        }).RequireRateLimiting("browse");

        app.MapPut("/api/me/coach-profile", async (CoachInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(i.Headline) || i.Headline.Length > 120 || i.Bio?.Length > 800 || i.Area?.Length > 80 || i.SubtypeIds is not { Length: >= 1 and <= 5 } || (i.HourlyRate is { } r && !Money(r)))
                return Bad("Add a headline, up to 800 characters about you, and 1–5 sports.");
            return Results.Ok((await db.Call("dbo.SaveCoachProfile", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@Headline", SqlDbType.NVarChar, i.Headline.Trim(), 120),
                P("@Bio", SqlDbType.NVarChar, i.Bio ?? "", 800), Dec("@HourlyRate", i.HourlyRate), P("@Area", SqlDbType.NVarChar, i.Area, 80),
                P("@SportsJson", SqlDbType.NVarChar, JsonSerializer.Serialize(i.SubtypeIds), 400), P("@IsListed", SqlDbType.Bit, i.IsListed)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Public / private games, host approval ----------
        app.MapGet("/api/games/{id:int}/access", async (int id, string? invite, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.GetGameAccess", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, MaybeId(u)), P("@InviteCode", SqlDbType.Char, invite is { Length: 10 } ? invite.ToUpperInvariant() : null, 10));
            return s[0].Count == 0 ? Results.NotFound() : Results.Ok(new { access = s[0][0], requests = s[1] });
        }).RequireRateLimiting("browse");

        app.MapPut("/api/games/{id:int}/access", async (int id, AccessInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Visibility is not ("Public" or "Private") || i.JoinMode is not ("Instant" or "Approval") ? Bad("Choose who can see and join.") :
            Results.Ok((await db.Call("dbo.SetGameAccess", ct, P("@GameId", SqlDbType.Int, id), P("@HostUserId", SqlDbType.Int, Id(u)),
                P("@Visibility", SqlDbType.VarChar, i.Visibility, 8), P("@JoinMode", SqlDbType.VarChar, i.JoinMode, 8)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/games/{id:int}/join-requests", async (int id, JoinRequestInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Message?.Length > 200 ? Bad("Keep your message under 200 characters.") :
            Results.Ok((await db.Call("dbo.RequestToJoin", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(u)),
                P("@Message", SqlDbType.NVarChar, string.IsNullOrWhiteSpace(i.Message) ? null : i.Message.Trim(), 200),
                P("@InviteCode", SqlDbType.Char, i.InviteCode is { Length: 10 } ? i.InviteCode.ToUpperInvariant() : null, 10)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/games/{id:int}/join-requests/{userId:int}", async (int id, int userId, DecisionInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.DecideJoinRequest", ct, P("@GameId", SqlDbType.Int, id), P("@HostUserId", SqlDbType.Int, Id(u)),
                P("@UserId", SqlDbType.Int, userId), P("@Approve", SqlDbType.Bit, i.Approve)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Friends & chat ----------
        app.MapGet("/api/me/friends", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListFriends", ct, P("@UserId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();

        app.MapPost("/api/me/friends", async (FriendInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (i.Action is not ("Request" or "Accept" or "Remove") || (i.UserId is null && (string.IsNullOrWhiteSpace(i.Email) || i.Email.Length > 254))) return Bad("Enter your friend's email.");
            return Results.Ok((await db.Call("dbo.FriendRequest", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@Email", SqlDbType.NVarChar, i.Email, 254),
                P("@OtherId", SqlDbType.Int, i.UserId), P("@Action", SqlDbType.VarChar, i.Action, 8)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapGet("/api/chats", async (ClaimsPrincipal u, Database db, MessageCrypto crypto, CancellationToken ct) =>
        {
            var rows = (await db.Call("dbo.ListConversations", ct, P("@UserId", SqlDbType.Int, Id(u))))[0];
            foreach (var r in rows) if (r["lastMessage"] is string m)
            { var text = crypto.Decrypt(Convert.ToInt64(r["conversationId"]), m); r["lastMessage"] = text.Length > 80 ? text[..80] : text; }
            return Results.Ok(rows);
        }).RequireAuthorization();

        app.MapPost("/api/chats", async (OpenChatInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Kind is not ("Direct" or "Game" or "Club") ? Bad("Unknown chat.") :
            Results.Ok((await db.Call("dbo.OpenConversation", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@Kind", SqlDbType.VarChar, i.Kind, 8),
                P("@GameId", SqlDbType.Int, i.GameId), P("@ClubId", SqlDbType.Int, i.ClubId), P("@OtherUserId", SqlDbType.Int, i.UserId)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapGet("/api/chats/{id:long}/messages", async (long id, long? beforeId, ClaimsPrincipal u, Database db, MessageCrypto crypto, CancellationToken ct) =>
            Results.Ok(crypto.Open((await db.Call("dbo.GetMessages", ct, P("@ConversationId", SqlDbType.BigInt, id), P("@UserId", SqlDbType.Int, Id(u)), P("@BeforeId", SqlDbType.BigInt, beforeId)))[0])))
            .RequireAuthorization();

        app.MapPost("/api/chats/{id:long}/messages", async (long id, MessageInput i, ClaimsPrincipal u, Database db, MessageCrypto crypto, IHubContext<LiveHub> hub, CancellationToken ct) =>
        {
            if (i.ClientKey == Guid.Empty || string.IsNullOrWhiteSpace(i.Body) || i.Body.Trim().Length > 1000) return Bad("Write a message (up to 1000 characters).");
            // Encrypted here, so SQL Server never receives the message text.
            var msg = crypto.Open((await db.Call("dbo.SendMessage", ct, P("@ConversationId", SqlDbType.BigInt, id), P("@UserId", SqlDbType.Int, Id(u)),
                P("@Body", SqlDbType.NVarChar, crypto.Encrypt(id, i.Body.Trim()), -1), P("@ClientKey", SqlDbType.UniqueIdentifier, i.ClientKey)))[0])[0];
            // Push to every member's private user group (membership is computed in SQL, never by the client).
            var members = (await db.Call("dbo.ConversationMembers", ct, P("@ConversationId", SqlDbType.BigInt, id)))[0];
            await hub.Clients.Groups(members.Select(m => "user:" + m["userId"]).ToList()).SendAsync("message", msg, ct);
            return Results.Ok(msg);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Loyalty, rewards, GameOn Pro ----------
        app.MapGet("/api/me/rewards", async (ClaimsPrincipal u, Database db, PlatformSettings settings, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.GetRewards", ct, P("@UserId", SqlDbType.Int, Id(u)));
            return Results.Ok(new { summary = s[0][0], rewards = s[1], history = s[2], codes = s[3], pro = new { price = await settings.ProPrice(ct), days = 30 } });
        }).RequireAuthorization();

        app.MapPost("/api/me/rewards/{id:int}/redeem", async (int id, KeyInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.IdempotencyKey == Guid.Empty ? Bad("Refresh and try again.") :
            Results.Ok((await db.Call("dbo.RedeemReward", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@RewardId", SqlDbType.Int, id), P("@Key", SqlDbType.UniqueIdentifier, i.IdempotencyKey)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/me/pro", async (KeyInput i, ClaimsPrincipal u, Database db, PlatformSettings settings, CancellationToken ct) =>
            i.IdempotencyKey == Guid.Empty ? Bad("Refresh and try again.") :
            Results.Ok((await db.Call("dbo.BuyPro", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@Key", SqlDbType.UniqueIdentifier, i.IdempotencyKey),
                Dec("@Price", await settings.ProPrice(ct)), P("@Days", SqlDbType.Int, 30)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/badges", async (BadgeInput i, Database db, CancellationToken ct) =>
            i.UserIds is not { Length: <= 100 } ? Bad("Too many users.") :
            Results.Ok((await db.Call("dbo.GetBadges", ct, P("@UserIdsJson", SqlDbType.NVarChar, JsonSerializer.Serialize(i.UserIds.Distinct()), 2000)))[0]))
            .RequireRateLimiting("browse");
    }

    // Pro price is configurable (Payments:ProMonthlyPrice) and always computed on the server.
    private static decimal ProPrice(IConfiguration config) => config.GetValue<decimal?>("Payments:ProMonthlyPrice") is { } p && p > 0 && p <= 100 ? decimal.Round(p, 2) : 5.00m;

    // Discovery & game details must not leak private games.
    public static async Task<HashSet<int>> HiddenGames(Database db, int? userId, CancellationToken ct) =>
        (await db.Call("dbo.ListPrivateGamesHidden", ct, P("@UserId", SqlDbType.Int, userId)))[0].Select(r => Convert.ToInt32(r["gameId"])).ToHashSet();
}

public sealed record CourtBookingInput(DateTimeOffset StartsAtUtc, Guid IdempotencyKey, string? RewardCode = null, string? GuestName = null, bool PayFromWallet = false);
public sealed record ClassRegistrationInput(bool Cancel = false);
public sealed record NewClubInput(int VenueId, string Name, string OwnerEmail, bool IsPartner = false, byte ProDiscountPct = 0);
public sealed record StaffInput(string Email, string? Role);
public sealed record CourtInput(int? CourtId, string Name, int SubtypeId, short SlotMinutes, byte OpenHour, byte CloseHour, decimal BasePrice, decimal PeakPrice, byte PeakStartHour, byte PeakEndHour, bool IsActive = true);
public sealed record BlockInput(DateTimeOffset StartsAtUtc, string? Reason = null);
public sealed record ClassSeriesInput(string Title, int SubtypeId, int? CourtId, int? CoachUserId, DateTimeOffset FirstStartsAtUtc, short DurationMinutes, short Capacity, decimal Price, byte Weeks = 1);
public sealed record ExpenseInput(decimal Amount, string Category, DateOnly SpentOn, string? Note = null);
public sealed record CoachInput(string Headline, string? Bio, decimal? HourlyRate, string? Area, int[] SubtypeIds, bool IsListed = true);
public sealed record AccessInput(string Visibility, string JoinMode);
public sealed record JoinRequestInput(string? Message = null, string? InviteCode = null);
public sealed record DecisionInput(bool Approve);
public sealed record FriendInput(string Action, string? Email = null, int? UserId = null);
public sealed record OpenChatInput(string Kind, int? GameId = null, int? ClubId = null, int? UserId = null);
public sealed record MessageInput(string Body, Guid ClientKey);
public sealed record KeyInput(Guid IdempotencyKey);
public sealed record BadgeInput(int[] UserIds);
