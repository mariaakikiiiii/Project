using System.Data;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using static Database;

// In-app venue directory. Works without any Google credentials; operators add/correct/verify listings.
public static class VenueDirectoryEndpoints
{
    private static readonly string[] Listing = ["Demo", "Unverified", "Verified"];
    private static readonly string[] Reservation = ["Unknown", "ContactVenue", "OnlineBooking", "WalkIn"];

    public static void MapVenueDirectory(this WebApplication app)
    {
        app.MapGet("/api/venues/search", async (string? q, int? subtypeId, Database db, CancellationToken ct) =>
        {
            if (q?.Length > 100 || subtypeId is <= 0) return Results.BadRequest(new { error = "Use a search up to 100 characters and a valid activity." });
            return Results.Ok((await db.Call("dbo.SearchVenues", ct, P("@Query", SqlDbType.NVarChar, q?.Trim() ?? "", 100), P("@SubtypeId", SqlDbType.Int, subtypeId)))[0]);
        }).RequireRateLimiting("browse");

        app.MapPost("/api/operator/venues", async (DirectoryVenue input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var error = Validate(input, adding: true);
            if (error is not null) return Results.BadRequest(new { error });
            var row = (await db.Call("dbo.AddDirectoryVenue", ct, [P("@UserId", SqlDbType.Int, UserId(user)), .. Common(input), P("@Verified", SqlDbType.Bit, input.ContactVerified)]))[0][0];
            return Results.Ok(row);
        }).RequireAuthorization().RequireRateLimiting("checkout");

        app.MapPut("/api/operator/venues/{id:int}/directory", async (int id, DirectoryVenue input, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var error = Validate(input, adding: false);
            if (error is not null) return Results.BadRequest(new { error });
            await db.Call("dbo.UpdateDirectoryVenue", ct, [P("@UserId", SqlDbType.Int, UserId(user)), P("@VenueId", SqlDbType.Int, id), .. Common(input), P("@ContactVerified", SqlDbType.Bit, input.ContactVerified)]);
            return Results.Ok(new { message = "Venue updated and audited." });
        }).RequireAuthorization().RequireRateLimiting("checkout");
    }

    private static int UserId(ClaimsPrincipal u) => int.Parse(u.FindFirstValue(ClaimTypes.NameIdentifier)!);

    private static string? Validate(DirectoryVenue v, bool adding)
    {
        if (string.IsNullOrWhiteSpace(v.Name) || v.Name.Length > 120 || string.IsNullOrWhiteSpace(v.Area) || v.Area.Length > 80
            || string.IsNullOrWhiteSpace(v.Address) || v.Address.Length > 250)
            return "Provide the venue's actual name, area and address.";
        if (v.Phone is not null && !Regex.IsMatch(v.Phone, @"^\+[0-9]{7,15}$")) return "Use an international phone number beginning with +, e.g. +9613xxxxxx.";
        if (v.ContactVerified && v.Phone is null) return "A contact can only be marked verified with a phone number.";
        if (v.SubtypeIds is not { Length: >= 1 and <= 17 } || v.SubtypeIds.Any(id => id <= 0)) return "Choose the sports this venue actually offers.";
        if (!Listing.Contains(v.ListingStatus) || (adding && v.ListingStatus == "Demo")) return "Choose Unverified or Verified.";
        if (!Reservation.Contains(v.ReservationMode)) return "Choose how reservations work.";
        if (!SafeUrl(v.SourceUrl) || !SafeUrl(v.WebsiteUrl)) return "Links must be complete https:// addresses.";
        if (v.ListingStatus == "Verified" && (v.SourceUrl is null || v.SourceCheckedOn is null)) return "A verified listing needs the source link and the date you checked it.";
        if (v.SourceCheckedOn > DateOnly.FromDateTime(DateTime.UtcNow)) return "The check date cannot be in the future.";
        if ((v.Latitude is null) != (v.Longitude is null) || v.Latitude is < 33m or > 34.8m || v.Longitude is < 35m or > 36.7m) return "Coordinates must both be set and inside Lebanon.";
        if (!adding && (string.IsNullOrWhiteSpace(v.Note) || v.Note.Trim().Length < 4)) return "Explain the correction (what you checked and where).";
        if (v.Note?.Length > 400 || v.SourceName?.Length > 120) return "Note or source name is too long.";
        return null;
    }
    private static bool SafeUrl(string? url) => url is null || (url.Length <= 400 && Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == "https");

    private static Microsoft.Data.SqlClient.SqlParameter[] Common(DirectoryVenue v) =>
    [
        P("@Name", SqlDbType.NVarChar, v.Name.Trim(), 120), P("@Area", SqlDbType.NVarChar, v.Area.Trim(), 80),
        P("@Address", SqlDbType.NVarChar, v.Address.Trim(), 250), P("@Phone", SqlDbType.VarChar, v.Phone, 20),
        P("@SportsJson", SqlDbType.NVarChar, JsonSerializer.Serialize(v.SubtypeIds), 2000),
        MapsLocations.Coordinate("@Latitude", v.Latitude), MapsLocations.Coordinate("@Longitude", v.Longitude),
        P("@ListingStatus", SqlDbType.VarChar, v.ListingStatus, 12), P("@SourceName", SqlDbType.NVarChar, v.SourceName?.Trim(), 120),
        P("@SourceUrl", SqlDbType.NVarChar, v.SourceUrl, 400), P("@SourceCheckedOn", SqlDbType.Date, v.SourceCheckedOn?.ToDateTime(TimeOnly.MinValue)),
        P("@WebsiteUrl", SqlDbType.NVarChar, v.WebsiteUrl, 400), P("@ReservationMode", SqlDbType.VarChar, v.ReservationMode, 16),
        P("@Note", SqlDbType.NVarChar, v.Note?.Trim(), 400)
    ];
}
public sealed record DirectoryVenue(string Name, string Area, string Address, string? Phone, int[] SubtypeIds, bool ContactVerified = false,
    decimal? Latitude = null, decimal? Longitude = null, string ListingStatus = "Unverified", string? SourceName = null, string? SourceUrl = null,
    DateOnly? SourceCheckedOn = null, string? WebsiteUrl = null, string ReservationMode = "Unknown", string? Note = null);
