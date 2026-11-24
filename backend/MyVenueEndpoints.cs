using System.Data;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using static Database;

// "List your venue": owners list their club, courts and a price per duration. GameOn keeps 10% of each booking.
public static class MyVenueEndpoints
{
    static readonly short[] Durations = [30, 60, 90, 120, 150, 180];
    private static int Id(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);
    private static IResult Bad(string error) => Results.BadRequest(new { error });

    public static void MapMyVenues(this WebApplication app)
    {
        app.MapGet("/api/me/venues", async (ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            var s = await db.Call("dbo.ListMyVenues", ct, P("@UserId", SqlDbType.Int, Id(u)));
            return Results.Ok(new { venues = s[0], courts = s[1], prices = s[2] });
        }).RequireAuthorization();

        app.MapPost("/api/me/venues", async (MyVenueInput i, ClaimsPrincipal u, Database db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(i.Name) || i.Name.Trim().Length > 120 || string.IsNullOrWhiteSpace(i.Area) || i.Area.Trim().Length > 80
                || string.IsNullOrWhiteSpace(i.Address) || i.Address.Trim().Length > 250)
                return Bad("Enter the venue name, town and address.");
            if (i.Phone is { Length: > 0 } && !Regex.IsMatch(i.Phone, @"^\+[0-9]{7,15}$")) return Bad("Enter the phone in international format, e.g. +96171123456.");
            if (i.OpenHour >= i.CloseHour || i.CloseHour > 24) return Bad("Opening hour must be before closing hour.");
            if (i.Courts is not { Length: >= 1 and <= 20 }) return Bad("List between 1 and 20 courts.");
            foreach (var c in i.Courts)
            {
                if (string.IsNullOrWhiteSpace(c.Name) || c.Name.Trim().Length > 80 || c.SubtypeId <= 0) return Bad("Give every court a name and a sport.");
                if (c.Prices is not { Length: >= 1 and <= 6 } || c.Prices.Select(p => p.Minutes).Distinct().Count() != c.Prices.Length) return Bad($"{c.Name}: add 1–6 prices, one per duration.");
                if (c.Prices.Any(p => !Durations.Contains(p.Minutes) || p.Price < 0 || p.Price > 10000 || decimal.Round(p.Price, 2) != p.Price))
                    return Bad($"{c.Name}: prices must be for 30 min to 3 h, between $0 and $10,000.");
            }
            if (i.ClubId is null && !i.AcceptFee) return Bad("Accept the 10% GameOn fee on bookings to list your venue.");
            var courts = JsonSerializer.Serialize(i.Courts.Select(c => new { courtId = c.CourtId, name = c.Name.Trim(), subtypeId = c.SubtypeId, prices = c.Prices.Select(p => new { minutes = p.Minutes, price = p.Price }) }));
            var r = (await db.Call("dbo.SaveMyVenue", ct, P("@UserId", SqlDbType.Int, Id(u)), P("@ClubId", SqlDbType.Int, i.ClubId),
                P("@Name", SqlDbType.NVarChar, i.Name.Trim(), 120), P("@Area", SqlDbType.NVarChar, i.Area.Trim(), 80), P("@Address", SqlDbType.NVarChar, i.Address.Trim(), 250),
                Coord("@Latitude", i.Latitude), Coord("@Longitude", i.Longitude), P("@Phone", SqlDbType.VarChar, string.IsNullOrWhiteSpace(i.Phone) ? null : i.Phone, 20),
                P("@OpenHour", SqlDbType.TinyInt, i.OpenHour), P("@CloseHour", SqlDbType.TinyInt, i.CloseHour),
                P("@CourtsJson", SqlDbType.NVarChar, courts, -1), P("@AcceptFee", SqlDbType.Bit, i.AcceptFee)))[0][0];
            return Results.Ok(r);
        }).RequireAuthorization().RequireRateLimiting("checkout");
    }

    static Microsoft.Data.SqlClient.SqlParameter Coord(string name, decimal? v) =>
        new(name, SqlDbType.Decimal) { Precision = 10, Scale = 7, Value = v is { } d ? decimal.Round(d, 7) : DBNull.Value };
}

public sealed record MyVenuePrice(short Minutes, decimal Price);
public sealed record MyVenueCourt(int? CourtId, string Name, int SubtypeId, MyVenuePrice[] Prices);
public sealed record MyVenueInput(int? ClubId, string Name, string Area, string Address, decimal? Latitude, decimal? Longitude, string? Phone,
    byte OpenHour, byte CloseHour, MyVenueCourt[] Courts, bool AcceptFee = false);
