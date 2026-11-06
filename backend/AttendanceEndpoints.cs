using System.Data;
using System.Security.Claims;
using System.Text.Json;
using static Database;

// Attendance/completion, disputes and host fraud holds (migration 22).
// Money never moves here: at most a refund is queued for an operator to send and record.
public static class AttendanceEndpoints
{
    private static int Id(ClaimsPrincipal user) => int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    private static readonly string[] DisputeReasons = ["HostCancelled", "HostNoShow", "FalseCompletion", "RefundNotReceived", "Other"];

    public static void MapAttendance(this WebApplication app)
    {
        app.MapGet("/api/games/{id:int}/trust", async (int id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var sets = await db.Call("dbo.GetGameTrust", ct, P("@GameId", SqlDbType.Int, id),
                P("@UserId", SqlDbType.Int, user.Identity?.IsAuthenticated == true ? Id(user) : null));
            return sets[0].Count == 0 ? Results.NotFound() : Results.Ok(new { trust = sets[0][0], attendance = sets[1] });
        }).RequireRateLimiting("browse");

        app.MapPost("/api/games/{id:int}/completion", async (int id, CompletionInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Outcome is not "Played" and not "DidNotTakePlace" || input.Marks is { Length: > 100 }
                || input.Marks?.Any(m => m.UserId <= 0 || m.Mark is not "Attended" and not "NoShow") == true
                || (input.Outcome == "Played" && input.Marks is null))
                return Results.BadRequest(new { error = "Choose whether the game was played and mark each player Attended or No-show." });
            var marks = JsonSerializer.Serialize((input.Marks ?? []).Select(m => new { userId = m.UserId, mark = m.Mark }));
            await db.Call("dbo.SubmitAttendance", ct, P("@GameId", SqlDbType.Int, id), P("@HostUserId", SqlDbType.Int, Id(user)),
                P("@Outcome", SqlDbType.VarChar, input.Outcome, 16), P("@MarksJson", SqlDbType.NVarChar, marks, 4000));
            return Results.Ok(new { message = input.Outcome == "Played"
                ? "Thanks. Players are asked to confirm; each $1 deposit is queued for refund once you both agree."
                : "Recorded. Every held deposit for this game is queued for refund." });
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/games/{id:int}/attendance", async (int id, AttendanceInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Mark is not "Attended" and not "NotPlayed") return Results.BadRequest(new { error = "Choose I played or The game did not happen." });
            await db.Call("dbo.ConfirmAttendance", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(user)), P("@Mark", SqlDbType.VarChar, input.Mark, 16));
            return Results.Ok(new { message = input.Mark == "Attended"
                ? "Confirmed. If the host's report matches, your $1 refund is queued."
                : "Recorded. An operator will review this game before any money is released." });
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/games/{id:int}/disputes", async (int id, DisputeInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (!DisputeReasons.Contains(input.Reason) || string.IsNullOrWhiteSpace(input.Details) || input.Details.Trim().Length is < 10 or > 800)
                return Results.BadRequest(new { error = "Choose a reason and describe what happened (10–800 characters)." });
            await db.Call("dbo.OpenDispute", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(user)),
                P("@Reason", SqlDbType.VarChar, input.Reason, 24), P("@Details", SqlDbType.NVarChar, input.Details.Trim(), 800));
            return Results.Ok(new { message = "Dispute opened. Your deposit is frozen until an operator reviews it." });
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapGet("/api/disputes", async (ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var sets = await db.Call("dbo.ListDisputes", ct, P("@UserId", SqlDbType.Int, Id(user)));
            return Results.Ok(new { disputes = sets[0], canReview = sets[1][0]["canReview"] });
        }).RequireAuthorization();

        app.MapPost("/api/disputes/{id:long}/resolve", async (long id, ResolveInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (input.Outcome is not "RefundOwed" and not "Restored" and not "NoAction" || string.IsNullOrWhiteSpace(input.Note) || input.Note.Trim().Length is < 4 or > 800)
                return Results.BadRequest(new { error = "Choose an outcome and write what you checked." });
            await db.Call("dbo.ResolveDispute", ct, P("@DisputeId", SqlDbType.BigInt, id), P("@UserId", SqlDbType.Int, Id(user)),
                P("@Outcome", SqlDbType.VarChar, input.Outcome, 16), P("@Note", SqlDbType.NVarChar, input.Note.Trim(), 800));
            return Results.Ok(new { message = "Dispute resolved." });
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/operator/hosts/{hostId:int}/hold", async (int hostId, HoldInput input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(input.Reason) || input.Reason.Trim().Length is < 4 or > 400) return Results.BadRequest(new { error = "Record the reason (4–400 characters)." });
            await db.Call("dbo.SetHostHold", ct, P("@UserId", SqlDbType.Int, Id(user)), P("@HostUserId", SqlDbType.Int, hostId),
                P("@Hold", SqlDbType.Bit, input.Hold), P("@Reason", SqlDbType.NVarChar, input.Reason.Trim(), 400));
            return Results.Ok(new { message = input.Hold ? "Host placed on hold. New games and new deposits for their games are blocked." : "Host hold released." });
        }).RequireAuthorization().RequireRateLimiting("checkout");
    }
}
public sealed record AttendanceMark(int UserId, string Mark);
public sealed record CompletionInput(string Outcome, AttendanceMark[]? Marks);
public sealed record AttendanceInput(string Mark);
public sealed record DisputeInput(string Reason, string Details);
public sealed record ResolveInput(string Outcome, string Note);
public sealed record HoldInput(bool Hold, string Reason);
