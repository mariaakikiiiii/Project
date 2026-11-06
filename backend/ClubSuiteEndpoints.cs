using System.Data;
using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using static Database;

// Migration 29: wallet court payments, booking approval, club memberships & class packs (QR check-in),
// class attendance, player groups, CRM & broadcasts, inventory, payroll, club payouts, Shots.
public static class ClubSuiteEndpoints
{
    private static int Id(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);
    private static int? MaybeId(ClaimsPrincipal u) => u.Identity?.IsAuthenticated == true ? Id(u) : null;
    private static Microsoft.Data.SqlClient.SqlParameter Dec(string n, decimal? v, byte p = 10) => new(n, SqlDbType.Decimal) { Precision = p, Scale = 2, Value = (object?)v ?? DBNull.Value };
    private static bool Money(decimal v, decimal max = 500) => v > 0 && v <= max && decimal.Round(v, 2) == v;
    private static IResult Bad(string e) => Results.BadRequest(new { error = e });
    private static async Task<IResult> Row(Task<List<List<Dictionary<string, object?>>>> call) => Results.Ok((await call)[0].FirstOrDefault());

    public static void MapClubSuite(this WebApplication app)
    {
        // ---------- Booking approval ----------
        app.MapGet("/api/clubs/{id:int}/pending", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListPendingBookings", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
        app.MapPost("/api/court-bookings/{id:long}/decision", (long id, ApproveInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.DecideCourtBooking", ct, P("@BookingId", SqlDbType.BigInt, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@Approve", SqlDbType.Bit, i.Approve))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPut("/api/courts/{id:int}/approval", (int id, CourtApprovalInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.SetCourtApproval", ct, P("@CourtId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@RequiresApproval", SqlDbType.Bit, i.RequiresApproval))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Memberships & class packs ----------
        app.MapGet("/api/clubs/{id:int}/products", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListClubProducts", ct, P("@ClubId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, MaybeId(u))))[0])).RequireRateLimiting("browse");
        app.MapPost("/api/clubs/{id:int}/products", (int id, ProductInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Kind is not ("Membership" or "ClassPack") || string.IsNullOrWhiteSpace(i.Name) || i.Name.Length > 80 || !Money(i.Price) || i.DurationDays is < 1 or > 366 || (i.Kind == "ClassPack" && i.Credits is not (>= 1 and <= 100))
                ? Task.FromResult(Bad("Check the name, price (up to $500), validity (1–366 days) and class credits (1–100)."))
                : Row(db.Call("dbo.SaveClubProduct", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@ProductId", SqlDbType.Int, i.ProductId),
                    P("@Kind", SqlDbType.VarChar, i.Kind, 10), P("@Name", SqlDbType.NVarChar, i.Name.Trim(), 80), Dec("@Price", i.Price), P("@DurationDays", SqlDbType.SmallInt, i.DurationDays),
                    P("@Credits", SqlDbType.SmallInt, i.Credits), P("@IsActive", SqlDbType.Bit, i.IsActive))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPost("/api/products/{id:int}/buy", (int id, BuyInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.IdempotencyKey == Guid.Empty ? Task.FromResult(Bad("Refresh and try again.")) :
            Row(db.Call("dbo.BuyClubProduct", ct, P("@ProductId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(u)), P("@Key", SqlDbType.UniqueIdentifier, i.IdempotencyKey))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/me/passes", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.MyClubPasses", ct, P("@UserId", SqlDbType.Int, Id(u)));
            return Results.Ok(new { passes = s[0], visits = s[1] });
        }).RequireAuthorization();
        app.MapPost("/api/clubs/{id:int}/check-in", (int id, CheckInInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Code is not { Length: 12 } || !i.Code.All(char.IsLetterOrDigit) ? Task.FromResult(Bad("Scan or type the member's 12-character code.")) :
            Row(db.Call("dbo.CheckInMember", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@AccessCode", SqlDbType.Char, i.Code.ToUpperInvariant(), 12))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPost("/api/classes/{id:int}/pack-registration", (int id, PackInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.RegisterWithPack", ct, P("@ClassId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, Id(u)), P("@PurchaseId", SqlDbType.BigInt, i.PurchaseId))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Class attendance ----------
        app.MapGet("/api/classes/{id:int}/roster", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ClassRoster", ct, P("@ClassId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
        app.MapPost("/api/classes/{id:int}/attendance", (int id, AttendInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.MarkClassAttendance", ct, P("@ClassId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, i.UserId), P("@Attended", SqlDbType.Bit, i.Attended))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- CRM & broadcasts ----------
        app.MapGet("/api/clubs/{id:int}/customers", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.ClubCustomers", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)));
            return Results.Ok(new { customers = s[0], broadcasts = s[1] });
        }).RequireAuthorization();
        app.MapPost("/api/clubs/{id:int}/broadcasts", (int id, BroadcastInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            string.IsNullOrWhiteSpace(i.Title) || i.Title.Length > 120 || string.IsNullOrWhiteSpace(i.Body) || i.Body.Trim().Length is < 10 or > 600
                ? Task.FromResult(Bad("Write a title and a message of 10–600 characters.")) :
            Row(db.Call("dbo.BroadcastToCustomers", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@Title", SqlDbType.NVarChar, i.Title.Trim(), 120), P("@Body", SqlDbType.NVarChar, i.Body.Trim(), 600))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Inventory ----------
        app.MapGet("/api/clubs/{id:int}/inventory", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListInventory", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
        app.MapPost("/api/clubs/{id:int}/inventory", (int id, ItemInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            string.IsNullOrWhiteSpace(i.Name) || i.Name.Length > 80 || i.Unit?.Length > 20 || i.ReorderLevel < 0 || i.UnitPrice is < 0 ? Task.FromResult(Bad("Check the item details.")) :
            Row(db.Call("dbo.SaveInventoryItem", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@ItemId", SqlDbType.Int, i.ItemId), P("@Name", SqlDbType.NVarChar, i.Name.Trim(), 80),
                P("@Unit", SqlDbType.NVarChar, i.Unit, 20), P("@ReorderLevel", SqlDbType.Int, i.ReorderLevel), Dec("@UnitPrice", i.UnitPrice))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPost("/api/inventory/{id:int}/adjust", (int id, StockInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Delta == 0 || Math.Abs(i.Delta) > 100000 || i.Reason is not ("Restock" or "Sale" or "Use" or "Damage" or "Count") || i.Note?.Length > 120 ? Task.FromResult(Bad("Enter a quantity change and reason.")) :
            Row(db.Call("dbo.AdjustInventory", ct, P("@ItemId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@Delta", SqlDbType.Int, i.Delta), P("@Reason", SqlDbType.VarChar, i.Reason, 10), P("@Note", SqlDbType.NVarChar, i.Note, 120))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Owner back office: payroll, activity log, balance ----------
        app.MapGet("/api/clubs/{id:int}/back-office", async (int id, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.ClubBackOffice", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)));
            return Results.Ok(new { balance = s[0][0], activity = s[1], payroll = s[2], staff = s[3], ledger = s[4] });
        }).RequireAuthorization();
        app.MapPost("/api/clubs/{id:int}/payroll", (int id, PayInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Salary < 0 || i.Salary > 100000 || decimal.Round(i.Salary, 2) != i.Salary || i.Note?.Length > 120 ? Task.FromResult(Bad("Enter the salary for the month.")) :
            Row(db.Call("dbo.AddStaffPay", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, i.UserId),
                P("@PeriodMonth", SqlDbType.Date, i.Month.ToDateTime(TimeOnly.MinValue)), Dec("@Salary", i.Salary), P("@Note", SqlDbType.NVarChar, i.Note, 120))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPut("/api/clubs/{id:int}/staff/{userId:int}/commission", (int id, int userId, CommissionInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.SetStaffCommission", ct, P("@ClubId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, userId), P("@CommissionPct", SqlDbType.TinyInt, i.CommissionPct))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/operator/club-balances", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListClubBalances", ct, P("@OperatorId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
        app.MapPost("/api/operator/clubs/{id:int}/payouts", (int id, PayoutInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            !Money(i.Amount, 1000000) || string.IsNullOrWhiteSpace(i.Reference) || i.Reference.Trim().Length is < 4 or > 100 ? Task.FromResult(Bad("Enter the amount sent and its reference.")) :
            Row(db.Call("dbo.RecordClubPayout", ct, P("@OperatorId", SqlDbType.Int, Id(u)), P("@ClubId", SqlDbType.Int, id), Dec("@Amount", i.Amount, 12), P("@Reference", SqlDbType.NVarChar, i.Reference.Trim(), 100))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Player groups ----------
        app.MapGet("/api/me/groups", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListMyGroups", ct, P("@UserId", SqlDbType.Int, Id(u))))[0])).RequireAuthorization();
        app.MapPost("/api/me/groups", (GroupInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            string.IsNullOrWhiteSpace(i.Name) || i.Name.Length > 60 || i.MemberIds is not { Length: <= 30 } ? Task.FromResult(Bad("Name the group and choose up to 30 friends.")) :
            Row(db.Call("dbo.CreatePlayerGroup", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@Name", SqlDbType.NVarChar, i.Name.Trim(), 60), P("@MembersJson", SqlDbType.NVarChar, JsonSerializer.Serialize(i.MemberIds.Distinct()), 1000))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPost("/api/groups/{id:int}/members", (int id, GroupMemberInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.UpdateGroupMember", ct, P("@GroupId", SqlDbType.Int, id), P("@ActorId", SqlDbType.Int, Id(u)), P("@UserId", SqlDbType.Int, i.UserId), P("@Add", SqlDbType.Bit, i.Add))))
            .RequireAuthorization().RequireRateLimiting("checkout");
        app.MapPost("/api/games/{id:int}/invite-group", (int id, InviteGroupInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Row(db.Call("dbo.InviteGroupToGame", ct, P("@GameId", SqlDbType.Int, id), P("@HostUserId", SqlDbType.Int, Id(u)), P("@GroupId", SqlDbType.Int, i.GroupId))))
            .RequireAuthorization().RequireRateLimiting("checkout");

        // ---------- Shots ----------
        app.MapGet("/api/shots", async (long? beforeId, int? subtypeId, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.ListShots", ct, P("@UserId", SqlDbType.Int, MaybeId(u)), P("@BeforeId", SqlDbType.BigInt, beforeId), P("@SubtypeId", SqlDbType.Int, subtypeId)))[0]))
            .RequireRateLimiting("browse");
        app.MapPost("/api/shots", async (HttpRequest req, ClaimsPrincipal u, Database db, IWebHostEnvironment env, IConfiguration config, CancellationToken ct) =>
        {
            if (!req.HasFormContentType) return Bad("Choose a photo to share.");
            var form = await req.ReadFormAsync(ct);
            var file = form.Files.GetFile("photo");
            var caption = form["caption"].ToString().Trim();
            if (file is null || file.Length is < 100 or > ShotImages.MaxBytes) return Bad("Choose a JPEG, PNG or WebP photo up to 3 MB.");
            if (caption.Length > 280) return Bad("Keep the caption under 280 characters.");
            int? subtype = int.TryParse(form["subtypeId"], out var s) && s > 0 ? s : null;
            int? game = int.TryParse(form["gameId"], out var g) && g > 0 ? g : null;
            byte[] bytes;
            using (var ms = new MemoryStream()) { await file.CopyToAsync(ms, ct); bytes = ms.ToArray(); }
            var kind = ShotImages.Detect(bytes);
            if (kind is null) return Bad("That file is not a JPEG, PNG or WebP image.");
            bytes = ShotImages.StripMetadata(bytes, kind.Value.Type); // removes EXIF/GPS location data
            var name = Guid.NewGuid().ToString("N") + kind.Value.Ext;  // never trust the uploaded file name
            var dir = ShotImages.Folder(env, config);
            Directory.CreateDirectory(dir);
            await File.WriteAllBytesAsync(Path.Combine(dir, name), bytes, ct);
            try
            {
                var row = (await db.Call("dbo.CreateShot", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@Caption", SqlDbType.NVarChar, caption, 280), P("@MediaFile", SqlDbType.VarChar, name, 64),
                    P("@ContentType", SqlDbType.VarChar, kind.Value.Type, 20), P("@SubtypeId", SqlDbType.Int, subtype), P("@GameId", SqlDbType.Int, game)))[0][0];
                return Results.Ok(row);
            }
            catch { File.Delete(Path.Combine(dir, name)); throw; }
        }).RequireAuthorization().RequireRateLimiting("checkout").DisableAntiforgery()
          .WithMetadata(new RequestSizeLimitAttribute(ShotImages.MaxBytes + 64 * 1024), new RequestFormLimitsAttribute { MultipartBodyLengthLimit = ShotImages.MaxBytes + 64 * 1024 });
        app.MapGet("/api/shots/{id:long}/media", async (long id, HttpContext ctx, Database db, IWebHostEnvironment env, IConfiguration config, CancellationToken ct) =>
        {
            var rows = (await db.Call("dbo.GetShotMedia", ct, P("@ShotId", SqlDbType.BigInt, id)))[0];
            if (rows.Count == 0) return Results.NotFound();
            var path = Path.Combine(ShotImages.Folder(env, config), Path.GetFileName(rows[0]["mediaFile"]!.ToString()!));
            if (!File.Exists(path)) return Results.NotFound();
            ctx.Response.Headers["Content-Security-Policy"] = "default-src 'none'; sandbox";
            ctx.Response.Headers["Cache-Control"] = "private, max-age=3600";
            return Results.File(path, rows[0]["contentType"]!.ToString()!);
        }).RequireRateLimiting("browse");
        app.MapPost("/api/shots/{id:long}/action", (long id, ShotActionInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
            i.Action is not ("Like" or "Unlike" or "Report" or "Delete") || i.Reason?.Length > 200 ? Task.FromResult(Bad("Unknown action.")) :
            Row(db.Call("dbo.ShotAction", ct, P("@ShotId", SqlDbType.BigInt, id), P("@UserId", SqlDbType.Int, Id(u)), P("@Action", SqlDbType.VarChar, i.Action, 8), P("@Reason", SqlDbType.NVarChar, i.Reason, 200))))
            .RequireAuthorization().RequireRateLimiting("checkout");
    }
}

// Image checks for Shots: real file signature, size limit, and removal of embedded metadata (EXIF can contain GPS).
public static class ShotImages
{
    public const int MaxBytes = 3 * 1024 * 1024;
    public static string Folder(IWebHostEnvironment env, IConfiguration config) =>
        config["Storage:ShotsPath"] is { Length: > 0 } p ? p : Path.Combine(env.ContentRootPath, "App_Data", "shots");

    public static (string Type, string Ext)? Detect(byte[] b)
    {
        if (b.Length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return ("image/jpeg", ".jpg");
        if (b.Length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) return ("image/png", ".png");
        if (b.Length > 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' && b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P') return ("image/webp", ".webp");
        return null;
    }

    public static byte[] StripMetadata(byte[] b, string type) => type switch
    {
        "image/jpeg" => StripJpeg(b),
        "image/png" => StripPng(b),
        "image/webp" => StripWebp(b),
        _ => b
    };

    // JPEG: drop APP1 (EXIF/XMP), APP13 (IPTC) and COM segments before the image data.
    static byte[] StripJpeg(byte[] b)
    {
        using var o = new MemoryStream(b.Length);
        o.Write(b, 0, 2);
        int i = 2;
        while (i + 4 <= b.Length && b[i] == 0xFF)
        {
            byte marker = b[i + 1];
            if (marker == 0xDA) break; // start of scan: copy the rest unchanged
            int len = (b[i + 2] << 8) | b[i + 3];
            if (len < 2 || i + 2 + len > b.Length) throw new InvalidDataException("Damaged JPEG.");
            if (marker is not (0xE1 or 0xED or 0xFE)) o.Write(b, i, 2 + len);
            i += 2 + len;
        }
        o.Write(b, i, b.Length - i);
        return o.ToArray();
    }

    // PNG: drop eXIf and text chunks.
    static byte[] StripPng(byte[] b)
    {
        using var o = new MemoryStream(b.Length);
        o.Write(b, 0, 8);
        int i = 8;
        while (i + 12 <= b.Length)
        {
            int len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
            if (len < 0 || i + 12 + len > b.Length) throw new InvalidDataException("Damaged PNG.");
            var type = System.Text.Encoding.ASCII.GetString(b, i + 4, 4);
            if (type is not ("eXIf" or "tEXt" or "iTXt" or "zTXt")) o.Write(b, i, 12 + len);
            i += 12 + len;
            if (type == "IEND") break;
        }
        return o.ToArray();
    }

    // WebP: drop EXIF and XMP chunks and clear their flags in VP8X.
    static byte[] StripWebp(byte[] b)
    {
        using var o = new MemoryStream(b.Length);
        o.Write(b, 0, 12);
        int i = 12;
        while (i + 8 <= b.Length)
        {
            var type = System.Text.Encoding.ASCII.GetString(b, i, 4);
            int len = b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
            int total = 8 + len + (len & 1);
            if (len < 0 || i + 8 + len > b.Length) throw new InvalidDataException("Damaged WebP.");
            if (type is not ("EXIF" or "XMP "))
            {
                var chunk = b.AsSpan(i, Math.Min(total, b.Length - i)).ToArray();
                if (type == "VP8X" && chunk.Length > 8) chunk[8] &= 0xF3; // clear EXIF (0x08) and XMP (0x04) flags
                o.Write(chunk);
            }
            i += total;
        }
        var r = o.ToArray();
        BitConverter.TryWriteBytes(r.AsSpan(4, 4), r.Length - 8); // fix RIFF size (little-endian)
        return r;
    }
}

public sealed record ApproveInput(bool Approve);
public sealed record CourtApprovalInput(bool RequiresApproval);
public sealed record ProductInput(int? ProductId, string Kind, string Name, decimal Price, short DurationDays, short? Credits, bool IsActive = true);
public sealed record BuyInput(Guid IdempotencyKey);
public sealed record CheckInInput(string Code);
public sealed record PackInput(long PurchaseId);
public sealed record AttendInput(int UserId, bool Attended);
public sealed record BroadcastInput(string Title, string Body);
public sealed record ItemInput(int? ItemId, string Name, string? Unit, int ReorderLevel, decimal? UnitPrice);
public sealed record StockInput(int Delta, string Reason, string? Note = null);
public sealed record PayInput(int UserId, DateOnly Month, decimal Salary, string? Note = null);
public sealed record CommissionInput(byte CommissionPct);
public sealed record PayoutInput(decimal Amount, string Reference);
public sealed record GroupInput(string Name, int[] MemberIds);
public sealed record GroupMemberInput(int UserId, bool Add);
public sealed record InviteGroupInput(int GroupId);
public sealed record ShotActionInput(string Action, string? Reason = null);
