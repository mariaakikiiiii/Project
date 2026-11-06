using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using static Database;
namespace GameOn.Payments;
public static class DepositEndpoints
{
    private static int User(ClaimsPrincipal user) => int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    public static void MapDeposits(this WebApplication app)
    {
        app.MapGet("/api/games/{id:int}/deposit-quote", async (int id, bool? covered, string? method, ClaimsPrincipal user, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.GetDepositQuote", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, User(user)), P("@ClaimSponsored", SqlDbType.Bit, covered ?? false), P("@Method", SqlDbType.VarChar, method ?? "WhishManual", 12)))[0][0])).RequireAuthorization().RequireRateLimiting("browse");
        app.MapPost("/api/games/{id:int}/deposit-checkout", async (int id, DepositInput input, ClaimsPrincipal user, Database db, IConfiguration config, CancellationToken ct) =>
        {
            if (!config.GetValue<bool>("Payments:ManualWhishEnabled") || config["Payments:ManualWhishRecipient"] != "+96171364432")
                return Results.Json(new { error = "Verified deposit collection is not available." }, statusCode: 503);
            if (input.IdempotencyKey == Guid.Empty || input.Revision < 1 || input.Method is not "Cash" and not "WhishManual") return Results.BadRequest(new { error = "Invalid deposit checkout." });
            return Results.Ok((await db.Call("dbo.InitializeDeposit", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, User(user)),
                P("@Revision", SqlDbType.Int, input.Revision), P("@Key", SqlDbType.UniqueIdentifier, input.IdempotencyKey), P("@ClaimSponsored", SqlDbType.Bit, input.Covered),
                P("@Recipient", SqlDbType.VarChar, config["Payments:ManualWhishRecipient"], 20), P("@Method", SqlDbType.VarChar, input.Method, 12)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/me/deposits", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var sets = await db.Call("dbo.GetMyDeposits", ct, P("@UserId", SqlDbType.Int, User(user)));
            return Results.Ok(new { deposits = sets[0], canReview = sets[1][0]["canReview"] });
        }).RequireAuthorization();
        app.MapPost("/api/deposits/{id:guid}/transfer", async (Guid id, TransferRequest input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (!ValidReference(input.Reference)) return Results.BadRequest(new { error = "Enter the actual Whish reference (4–100 characters)." });
            return Results.Ok((await db.Call("dbo.SubmitDepositTransfer", ct, P("@DepositID", SqlDbType.UniqueIdentifier, id), P("@UserId", SqlDbType.Int, User(user)),
                P("@Reference", SqlDbType.NVarChar, input.Reference.Trim(), 100)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/deposits/reviews", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListDepositReviews", ct, P("@UserId", SqlDbType.Int, User(user))))[0])).RequireAuthorization();
        app.MapPost("/api/deposits/{id:guid}/review", async (Guid id, DepositReview input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Decision == "FORFEIT") return Results.BadRequest(new { error = "No-show forfeiture is disabled until a written no-show policy is approved." });
            if (input.Decision is not "VERIFY" and not "REJECT" and not "REFUND" || string.IsNullOrWhiteSpace(input.Note) || input.Note.Trim().Length is < 4 or > 400
                || (input.Decision == "REFUND" && !ValidReference(input.RefundReference))) return Results.BadRequest(new { error = "Enter a valid review, note and actual refund reference when applicable." });
            return Results.Ok((await db.Call("dbo.ReviewDeposit", ct, P("@DepositID", SqlDbType.UniqueIdentifier, id), P("@UserId", SqlDbType.Int, User(user)),
                P("@Decision", SqlDbType.VarChar, input.Decision, 20), P("@Note", SqlDbType.NVarChar, input.Note.Trim(), 400), P("@RefundReference", SqlDbType.NVarChar, input.RefundReference?.Trim(), 100)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/operator/venues", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListVenueContacts", ct, P("@UserId", SqlDbType.Int, User(user))))[0])).RequireAuthorization();
        app.MapPut("/api/operator/venues/{id:int}", async (int id, VenueContact input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Phone is not null && !Regex.IsMatch(input.Phone, @"^\+[0-9]{7,15}$") || input.Verified && input.Phone is null)
                return Results.BadRequest(new { error = "Enter the venue's real international phone number, beginning with +." });
            await db.Call("dbo.SetVenueContact", ct, P("@VenueId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, User(user)), P("@Phone", SqlDbType.VarChar, input.Phone, 20), P("@Verified", SqlDbType.Bit, input.Verified));
            return Results.Ok(new { message = "Venue contact updated." });
        }).RequireAuthorization().RequireRateLimiting("checkout");
    }
    private static bool ValidReference(string? reference) => !string.IsNullOrWhiteSpace(reference) && reference.Trim().Length is >= 4 and <= 100;
}
public sealed record DepositInput(Guid IdempotencyKey, int Revision, bool Covered = false, string Method = "WhishManual");
public sealed record DepositReview(string Decision, string Note, string? RefundReference = null);
public sealed record VenueContact(string? Phone, bool Verified);
