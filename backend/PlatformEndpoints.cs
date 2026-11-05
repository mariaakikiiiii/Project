using System.Data;
using Microsoft.AspNetCore.DataProtection;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Identity;
using static Database;

public static class PlatformEndpoints
{
    private static int Id(ClaimsPrincipal user) => int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    public static void MapPlatform(this WebApplication app)
    {
        app.MapGet("/api/config", (IConfiguration config, ResetEmail email, GameOn.Payments.IWhishGateway whish, GameOn.Payments.MockPaymentSecurity mock) => Results.Ok(new
        {
            mapsEmbedApiKey = config["Maps:EmbedApiKey"] ?? "",
            mapsBrowserApiKey = config["Maps:BrowserApiKey"] ?? "",
            mapsMapId = config["Maps:MapId"] ?? "",
            mapsPickerAvailable = !string.IsNullOrWhiteSpace(config["Maps:BrowserApiKey"]) && !string.IsNullOrWhiteSpace(config["Maps:ServerApiKey"]),
            manualWhishAvailable = config.GetValue<bool>("Payments:ManualWhishEnabled"),
            manualWhishRecipient = config.GetValue<bool>("Payments:ManualWhishEnabled") ? config["Payments:ManualWhishRecipient"] : null,
            passwordResetAvailable = email.Enabled,
            onlinePaymentsAvailable = whish.IsAvailable,
            payoutAvailable = false,
            mockPaymentsAvailable = mock.Enabled,
            serviceFeeRate = GameOn.Payments.BookingFees.Rate,
            paymentMethods = new[] { new { code = "Cash", name = "Cash at the venue", available = true }, new { code = "Whish", name = "Whish Money", available = whish.IsAvailable } },
            currencies = new[] { "USD", "LBP" },
            country = "LB"
        }));
        app.MapGet("/api/me/profile", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var sets = await db.Call("dbo.GetProfile", ct, P("@UserId", SqlDbType.Int, Id(user)));
            return Results.Ok(new { profile = sets[0][0], sports = sets[1].Select(s => s["sportId"]) });
        }).RequireAuthorization();
        app.MapPut("/api/me/profile", async (ProfileInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(input.DisplayName) || input.DisplayName.Length > 80 || input.Bio?.Length > 400
                || input.Area?.Length > 80 || input.SportIds is null || input.SportIds.Length > 20
                || !new[] { "All levels", "Beginner", "Intermediate", "Advanced" }.Contains(input.SkillLevel))
                return Results.BadRequest(new { error = "Check your name, bio, area and sports preferences." });
            await db.Call("dbo.SaveProfile", ct, P("@UserId", SqlDbType.Int, Id(user)),
                P("@DisplayName", SqlDbType.NVarChar, input.DisplayName.Trim(), 80),
                P("@Bio", SqlDbType.NVarChar, input.Bio ?? "", 400), P("@Area", SqlDbType.NVarChar, input.Area, 80),
                P("@SkillLevel", SqlDbType.VarChar, input.SkillLevel, 16),
                P("@SportsJson", SqlDbType.NVarChar, JsonSerializer.Serialize(input.SportIds), 2000));
            return Results.Ok(new { message = "Profile saved. Your next discovery feed will use these preferences." });
        }).RequireAuthorization();
        app.MapPut("/api/games/{id:int}", async (int id, EditGameInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (!ValidGame(input.StartsAt, input.Capacity, input.Description, input.CostPerPlayer, input.Currency, input.SponsoredSlots))
                return Results.BadRequest(new { error = "Check the start time, price, capacity and host-covered places." });
            await db.Call("dbo.EditGame", ct,
                P("@GameId", SqlDbType.Int, id), P("@HostUserId", SqlDbType.Int, Id(user)),
                P("@Revision", SqlDbType.Int, input.Revision), P("@StartsAt", SqlDbType.DateTime2, input.StartsAt.UtcDateTime),
                P("@Capacity", SqlDbType.SmallInt, input.Capacity), P("@Description", SqlDbType.NVarChar, input.Description ?? "", 1000),
                Price(input.CostPerPlayer), P("@Currency", SqlDbType.Char, input.Currency, 3), P("@SponsoredSlots", SqlDbType.SmallInt, input.SponsoredSlots));
            return Results.Ok(new { message = "Game updated. Players have been notified." });
        }).RequireAuthorization();
        app.MapPost("/api/games/{id:int}/cancel", async (int id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            await db.Call("dbo.CancelGame", ct, P("@GameId", SqlDbType.Int, id), P("@HostUserId", SqlDbType.Int, Id(user)));
            return Results.Ok(new { message = "Game cancelled. Players have been notified." });
        }).RequireAuthorization();
        app.MapPost("/api/games/{id:int}/sponsored-place", async (int id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.sp_JoinGameOrActivity", ct, P("@GameId", SqlDbType.Int, id),
                P("@UserId", SqlDbType.Int, Id(user)), P("@ClaimSponsored", SqlDbType.Bit, true)))[0][0])).RequireAuthorization();
        app.MapGet("/api/me/notifications", async (long? beforeId, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var sets = await db.Call("dbo.GetNotifications", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@BeforeId", SqlDbType.BigInt, beforeId));
            return Results.Ok(new { items = sets[0], unreadCount = sets[1][0]["unreadCount"] });
        }).RequireAuthorization();
        app.MapPost("/api/me/notifications/{id:long}/read", async (long id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            await db.Call("dbo.ReadNotification", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@NotificationId", SqlDbType.BigInt, id));
            return Results.NoContent();
        }).RequireAuthorization();
        app.MapPost("/api/auth/forgot-password", async (ForgotInput input, Database db, ResetEmail email, IDataProtectionProvider protection, CancellationToken ct) =>
        {
            if (!email.Enabled) return Results.Json(new { error = "Password recovery email is not available yet. Contact the organizer." }, statusCode: 503);
            if (!System.Net.Mail.MailAddress.TryCreate(input.Email?.Trim(), out var address) || address.Address.Length > 254)
                return Results.BadRequest(new { error = "Enter a valid email address." });
            var normalized = address.Address.ToLowerInvariant();
            string token = Microsoft.AspNetCore.WebUtilities.WebEncoders.Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
            byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(token));
            await db.Call("dbo.RequestPasswordReset", ct, P("@Email", SqlDbType.NVarChar, normalized, 254), P("@TokenHash", SqlDbType.Binary, hash, 32),
                P("@ProtectedToken", SqlDbType.NVarChar, protection.CreateProtector("GameOn.ResetEmail.v1").Protect(token), 2000));
            return Results.Ok(new { message = "If that account exists, a reset link will arrive shortly. It expires in 30 minutes." });
        }).RequireRateLimiting("auth");
        app.MapPost("/api/auth/reset-password", async (ResetInput input, Database db, IPasswordHasher<string> hasher, CancellationToken ct) =>
        {
            if (input.Token?.Length != 43 || input.Password is null || input.Password.Length is < 12 or > 128)
                return Results.BadRequest(new { error = "Use a valid reset link and a password of 12–128 characters." });
            await db.Call("dbo.ResetPassword", ct,
                P("@TokenHash", SqlDbType.Binary, SHA256.HashData(Encoding.UTF8.GetBytes(input.Token)), 32),
                P("@PasswordHash", SqlDbType.NVarChar, hasher.HashPassword("reset", input.Password), 512));
            return Results.Ok(new { message = "Password changed. Sign in with your new password." });
        }).RequireRateLimiting("auth");
    }
    public static bool ValidGame(DateTimeOffset start, short capacity, string? description, decimal price, string? currency, short sponsored) =>
        start > DateTimeOffset.UtcNow && start < DateTimeOffset.UtcNow.AddYears(2) && capacity is >= 2 and <= 100
        && description?.Length is not > 1000 && price is >= 0 and <= 99999999.99m && decimal.Round(price, 2) == price
        && currency is "USD" or "LBP" && sponsored >= 0 && sponsored < capacity;
    public static Microsoft.Data.SqlClient.SqlParameter Price(decimal value) => new("@CostPerPlayer", SqlDbType.Decimal)
    { Precision = 10, Scale = 2, Value = value };
}
record ProfileInput(string DisplayName, string? Bio, string? Area, string SkillLevel, int[] SportIds);
record EditGameInput(int Revision, DateTimeOffset StartsAt, short Capacity, string? Description, decimal CostPerPlayer, string Currency, short SponsoredSlots);
record ForgotInput(string Email);
record ResetInput(string Token, string Password);
