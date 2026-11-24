using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using static Database;

namespace GameOn.Payments;
// Venue-facing endpoints: sponsored venues, map/location helpers and the operator venue-contact editor.
// In-app payments (Whish checkout, $1 deposits, wallet) were removed in migration 37: games and courts are paid in person.
public static class CommercialEndpoints
{
    private static int User(ClaimsPrincipal user) => int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    public static void MapCommercial(this WebApplication app)
    {
        MapsLocations.Map(app);
        app.MapGet("/api/venues/sponsored", async (Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.GetSponsoredVenues", ct))[0])).RequireRateLimiting("browse");
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
}
public sealed record VenueContact(string? Phone, bool Verified);
