using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using static Database;

namespace GameOn.Payments;

// GameOn wallet (migration 25). The balance is an internal ledger:
// - money ENTERS only when an operator matches a Whish transfer on GameOn's real statement (no Whish merchant API exists yet);
// - paying the $1 deposit and refunding it happen instantly inside the ledger;
// - money LEAVES only when an operator sends a Whish transfer and records its reference.
public static class WalletEndpoints
{
    private static int Id(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);
    private static Microsoft.Data.SqlClient.SqlParameter Money(string name, decimal v) => new(name, SqlDbType.Decimal) { Precision = 12, Scale = 2, Value = v };
    private static bool ValidMoney(decimal v, decimal min, decimal max) => v >= min && v <= max && decimal.Round(v, 2) == v;

    public static void MapWallet(this WebApplication app)
    {
        app.MapGet("/api/me/wallet", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.GetWallet", ct, P("@UserId", SqlDbType.Int, Id(user)));
            return Results.Ok(new { summary = s[0][0], entries = s[1], topUps = s[2], withdrawals = s[3] });
        }).RequireAuthorization();

        app.MapPost("/api/me/wallet/top-ups", async (TopUpInput input, ClaimsPrincipal user, Database db, IConfiguration config, CancellationToken ct) =>
        {
            if (!config.GetValue<bool>("Payments:ManualWhishEnabled") || config["Payments:ManualWhishRecipient"] is not { } recipient)
                return Results.Json(new { error = "Wallet top-ups are not available right now." }, statusCode: 503);
            if (input.IdempotencyKey == Guid.Empty || !ValidMoney(input.Amount, 1, 200)) return Results.BadRequest(new { error = "Top up between USD 1 and 200." });
            return Results.Ok((await db.Call("dbo.CreateTopUp", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@Key", SqlDbType.UniqueIdentifier, input.IdempotencyKey),
                Money("@Amount", input.Amount), P("@Recipient", SqlDbType.VarChar, recipient, 20)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/me/wallet/top-ups/{id:guid}/reference", async (Guid id, TransferRequest input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(input.Reference) || input.Reference.Trim().Length is < 4 or > 100) return Results.BadRequest(new { error = "Enter the Whish transaction reference (4–100 characters)." });
            return Results.Ok((await db.Call("dbo.SubmitTopUpReference", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@TopUpId", SqlDbType.UniqueIdentifier, id),
                P("@Reference", SqlDbType.NVarChar, input.Reference.Trim(), 100)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapDelete("/api/me/wallet/top-ups/{id:guid}", async (Guid id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.CancelTopUp", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@TopUpId", SqlDbType.UniqueIdentifier, id)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/me/wallet/withdrawals", async (WithdrawalInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.IdempotencyKey == Guid.Empty || !ValidMoney(input.Amount, 1, 500)) return Results.BadRequest(new { error = "Withdraw between USD 1 and your balance." });
            if (input.WhishNumber is null || !Regex.IsMatch(input.WhishNumber, @"^\+961[0-9]{7,8}$")) return Results.BadRequest(new { error = "Enter your Lebanese Whish number, e.g. +96171123456." });
            return Results.Ok((await db.Call("dbo.RequestWithdrawal", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@Key", SqlDbType.UniqueIdentifier, input.IdempotencyKey),
                Money("@Amount", input.Amount), P("@WhishNumber", SqlDbType.VarChar, input.WhishNumber, 20)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/games/{id:int}/wallet-join", async (int id, WalletJoinInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.IdempotencyKey == Guid.Empty || input.Revision < 1) return Results.BadRequest(new { error = "Refresh the game and try again." });
            return Results.Ok((await db.Call("dbo.JoinWithWallet", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(user)),
                P("@Key", SqlDbType.UniqueIdentifier, input.IdempotencyKey), P("@Revision", SqlDbType.Int, input.Revision), P("@ClaimSponsored", SqlDbType.Bit, input.Covered)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        // Operator side
        app.MapGet("/api/operator/wallet", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.ListWalletReviews", ct, P("@OperatorId", SqlDbType.Int, Id(user)));
            return Results.Ok(new { topUps = s[0], withdrawals = s[1], totals = s[2][0] });
        }).RequireAuthorization();

        app.MapPost("/api/operator/wallet/top-ups/{id:guid}", async (Guid id, OperatorDecision input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Decision is not "VERIFY" and not "REJECT" || string.IsNullOrWhiteSpace(input.Note) || input.Note.Trim().Length is < 4 or > 400)
                return Results.BadRequest(new { error = "Choose a decision and write what you checked." });
            return Results.Ok((await db.Call("dbo.ReviewTopUp", ct, P("@OperatorId", SqlDbType.Int, Id(user)), P("@TopUpId", SqlDbType.UniqueIdentifier, id),
                P("@Decision", SqlDbType.VarChar, input.Decision, 8), P("@Note", SqlDbType.NVarChar, input.Note.Trim(), 400)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/operator/wallet/withdrawals/{id:guid}", async (Guid id, OperatorDecision input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Decision is not "SENT" and not "REJECT" || string.IsNullOrWhiteSpace(input.Note) || input.Note.Trim().Length is < 4 or > 400
                || (input.Decision == "SENT" && (string.IsNullOrWhiteSpace(input.Reference) || input.Reference.Trim().Length is < 4 or > 100)))
                return Results.BadRequest(new { error = "Choose a decision, write a note, and enter the Whish reference when sent." });
            return Results.Ok((await db.Call("dbo.ReviewWithdrawal", ct, P("@OperatorId", SqlDbType.Int, Id(user)), P("@WithdrawalId", SqlDbType.UniqueIdentifier, id),
                P("@Decision", SqlDbType.VarChar, input.Decision, 8), P("@Reference", SqlDbType.NVarChar, input.Reference?.Trim(), 100),
                P("@Note", SqlDbType.NVarChar, input.Note.Trim(), 400)))[0][0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");
    }
}
public sealed record TopUpInput(Guid IdempotencyKey, decimal Amount);
public sealed record WithdrawalInput(Guid IdempotencyKey, decimal Amount, string? WhishNumber);
public sealed record WalletJoinInput(Guid IdempotencyKey, int Revision, bool Covered = false);
public sealed record OperatorDecision(string Decision, string Note, string? Reference = null);
