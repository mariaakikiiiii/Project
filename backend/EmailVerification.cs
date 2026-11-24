using System.Data;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.DataProtection;
using static Database;

/// <summary>
/// Email verification (migration 36). New accounts can sign in and browse straight away, but booking, hosting
/// and chat stay locked until the email is confirmed. Tokens: 32 random bytes, only their SHA-256 stored,
/// valid 24 hours, single use. The raw token waits in the email outbox protected by Data Protection.
/// </summary>
public static partial class EmailVerification
{
    public const string Purpose = "GameOn.VerifyEmail.v1";

    // Booking, hosting and chat actions that need a confirmed email (any non-GET request to these paths).
    [GeneratedRegex(@"^/api/(chats(/.*)?|messages/.*|me/groups|groups/.*|games|games/\d+/(join|checkout|deposit-checkout|wallet-join|join-requests|sponsored-place|invite-group)|courts/\d+/bookings|classes/\d+/(registration|pack-registration)|products/\d+/buy)$", RegexOptions.IgnoreCase)]
    private static partial Regex GatedPath();

    public static async Task Queue(Database db, IDataProtectionProvider protection, int userId, CancellationToken ct)
    {
        string token = Microsoft.AspNetCore.WebUtilities.WebEncoders.Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
        await db.Call("dbo.RequestEmailVerification", ct, P("@UserId", SqlDbType.Int, userId),
            P("@TokenHash", SqlDbType.Binary, SHA256.HashData(Encoding.UTF8.GetBytes(token)), 32),
            P("@ProtectedToken", SqlDbType.NVarChar, protection.CreateProtector(Purpose).Protect(token), 2000));
    }

    public static async Task<bool> IsVerified(Database db, int userId, CancellationToken ct) =>
        (await db.Call("dbo.GetEmailStatus", ct, P("@UserId", SqlDbType.Int, userId)))[0] is { Count: > 0 } rows && Convert.ToBoolean(rows[0]["emailVerified"]);

    /// <summary>Blocks gated actions for signed-in users whose email is not confirmed (403, code "email_unverified").</summary>
    public static IApplicationBuilder UseEmailVerificationGate(this IApplicationBuilder app) => app.Use(async (ctx, next) =>
    {
        if (!HttpMethods.IsGet(ctx.Request.Method) && !HttpMethods.IsHead(ctx.Request.Method) && !HttpMethods.IsOptions(ctx.Request.Method)
            && ctx.User.Identity?.IsAuthenticated == true && GatedPath().IsMatch(ctx.Request.Path.Value ?? "")
            && int.TryParse(ctx.User.FindFirstValue(ClaimTypes.NameIdentifier), out int userId)
            && !await IsVerified(ctx.RequestServices.GetRequiredService<Database>(), userId, ctx.RequestAborted))
        {
            ctx.Response.StatusCode = 403;
            await ctx.Response.WriteAsJsonAsync(new { error = "Confirm your email first. Check your inbox or send a new link from the banner at the top.", code = "email_unverified" });
            return;
        }
        await next();
    });

    public static void MapEmailVerification(this WebApplication app)
    {
        // Opened from the email link; no sign-in needed (the token itself is the proof).
        app.MapPost("/api/auth/verify-email", async (VerifyEmailInput input, Database db, CancellationToken ct) =>
        {
            if (input.Token?.Length != 43) return Results.BadRequest(new { error = "This verification link is invalid. Send a new one from the banner after signing in." });
            await db.Call("dbo.VerifyEmail", ct, P("@TokenHash", SqlDbType.Binary, SHA256.HashData(Encoding.UTF8.GetBytes(input.Token)), 32));
            return Results.Ok(new { message = "Email confirmed. You can now book and chat." });
        }).RequireRateLimiting("auth");

        app.MapPost("/api/auth/resend-verification", async (ClaimsPrincipal u, Database db, ResetEmail email, IDataProtectionProvider protection, CancellationToken ct) =>
        {
            if (!email.CanDeliver) return Results.Json(new { error = "Email sending is not configured yet. Contact the organizer." }, statusCode: 503);
            await Queue(db, protection, int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!), ct);
            return Results.Ok(new { message = "A new confirmation link is on its way. It expires in 24 hours." });
        }).RequireAuthorization().RequireRateLimiting("auth");
    }
}

public sealed record VerifyEmailInput(string Token);
