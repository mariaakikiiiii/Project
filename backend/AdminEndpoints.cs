using System.Data;
using System.Security.Claims;
using static Database;

// App settings an admin can change without touching code (migration 31). Cached briefly.
public sealed class PlatformSettings(Database db)
{
    private Dictionary<string, string> cache = new();
    private DateTime loaded = DateTime.MinValue;
    private readonly SemaphoreSlim gate = new(1, 1);

    public async Task<Dictionary<string, string>> All(CancellationToken ct)
    {
        if (DateTime.UtcNow - loaded < TimeSpan.FromSeconds(30)) return cache;
        await gate.WaitAsync(ct);
        try
        {
            if (DateTime.UtcNow - loaded < TimeSpan.FromSeconds(30)) return cache;
            var rows = (await db.Call("dbo.GetPlatformSettings", ct))[0];
            cache = rows.ToDictionary(r => r["settingKey"]!.ToString()!, r => r["settingValue"]?.ToString() ?? "");
            loaded = DateTime.UtcNow;
            return cache;
        }
        finally { gate.Release(); }
    }
    public void Invalidate() => loaded = DateTime.MinValue;
    public async Task<bool> Flag(string key, CancellationToken ct) => !(await All(ct)).TryGetValue(key, out var v) || v != "false";
    public async Task<decimal> ProPrice(CancellationToken ct) =>
        (await All(ct)).TryGetValue("ProMonthlyPrice", out var v) && decimal.TryParse(v, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var p) && p is >= 1 and <= 100 ? decimal.Round(p, 2) : 5.00m;
}

// Admin panel API. Every rule (admin-only, no self-suspension, last admin, money checks) is enforced in SQL.
public static class AdminEndpoints
{
    private static int Id(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);
    private static IResult Bad(string e) => Results.BadRequest(new { error = e });
    private static readonly string[] Keys = ["Announcement", "SignupsOpen", "ShotsEnabled", "ProMonthlyPrice", "SupportEmail"];

    public static void MapAdmin(this WebApplication app)
    {
        app.MapGet("/api/admin/overview", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var stats = (await db.Call("dbo.AdminStats", ct, P("@AdminId", SqlDbType.Int, Id(u))))[0][0];
            var settings = (await db.Call("dbo.GetPlatformSettings", ct))[0];
            return Results.Ok(new { stats, settings });
        }).RequireAuthorization();

        app.MapGet("/api/admin/users", async (string? q, string? status, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (q?.Length > 100 || status is not (null or "Active" or "Suspended" or "Deleted")) return Bad("Check the search.");
            return Results.Ok((await db.Call("dbo.AdminListUsers", ct, P("@AdminId", SqlDbType.Int, Id(u)), P("@Query", SqlDbType.NVarChar, q, 100), P("@Status", SqlDbType.VarChar, status, 10)))[0]);
        }).RequireAuthorization();

        app.MapPost("/api/admin/users/{userId:int}/status", async (int userId, StatusInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Status is not ("Active" or "Suspended") || i.Reason?.Length > 300 ? Bad("Choose Active or Suspended.") :
            Results.Ok((await db.Call("dbo.AdminSetUserStatus", ct, P("@AdminId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, userId),
                P("@Status", SqlDbType.VarChar, i.Status, 10), P("@Reason", SqlDbType.NVarChar, i.Reason?.Trim(), 300)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/admin/users/{userId:int}/delete", async (int userId, StatusInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            string.IsNullOrWhiteSpace(i.Reason) || i.Reason.Length > 300 ? Bad("Write the reason for deleting this account.") :
            Results.Ok((await db.Call("dbo.AdminDeleteUser", ct, P("@AdminId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, userId), P("@Reason", SqlDbType.NVarChar, i.Reason.Trim(), 300)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPost("/api/admin/users/{userId:int}/role", async (int userId, RoleInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Role is not ("Admin" or "Operator") ? Bad("Choose Admin or Operator.") :
            Results.Ok((await db.Call("dbo.AdminSetRole", ct, P("@AdminId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, userId),
                P("@Role", SqlDbType.VarChar, i.Role, 10), P("@Grant", SqlDbType.Bit, i.Grant)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPut("/api/admin/settings/{key}", async (string key, SettingInput i, ClaimsPrincipal u, Database db, PlatformSettings settings, CancellationToken ct) =>
        {
            if (!Keys.Contains(key) || i.Value is null || i.Value.Length > 400) return Bad("Unknown setting.");
            var row = (await db.Call("dbo.AdminSetSetting", ct, P("@AdminId", SqlDbType.Int, Id(u)), P("@Key", SqlDbType.VarChar, key, 40), P("@Value", SqlDbType.NVarChar, i.Value, 400)))[0][0];
            settings.Invalidate();
            return Results.Ok(row);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapGet("/api/admin/shots", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.AdminReportedShots", ct, P("@AdminId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
        app.MapPost("/api/admin/shots/{id:long}", async (long id, HideInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.AdminModerateShot", ct, P("@AdminId", SqlDbType.Int, Id(u)), P("@ShotId", SqlDbType.BigInt, id), P("@Hide", SqlDbType.Bit, i.Hide)))[0][0]))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/admin/audit", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.AdminAuditLog", ct, P("@AdminId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
    }
}
public sealed record StatusInput(string? Status, string? Reason);
public sealed record RoleInput(string Role, bool Grant);
public sealed record SettingInput(string Value);
public sealed record HideInput(bool Hide);
