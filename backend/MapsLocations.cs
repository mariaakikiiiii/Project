using System.Data;
using System.Text.Json;
using static Database;

public sealed record LocationInput(string Name, double Latitude, double Longitude, string? PlaceId);
public sealed record VerifiedLocation(string Name, string Area, string Address, decimal Latitude, decimal Longitude, string? PlaceId);
public sealed class MapsLocations(IHttpClientFactory clients, IConfiguration config)
{
    public static Microsoft.Data.SqlClient.SqlParameter Coordinate(string name, decimal? value)
    {
        var parameter = P(name, SqlDbType.Decimal, value);
        parameter.Precision = 10; parameter.Scale = 7;
        return parameter;
    }
    public async Task<VerifiedLocation> Verify(LocationInput input, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(input.Name) || input.Name.Length > 120 || !double.IsFinite(input.Latitude) || !double.IsFinite(input.Longitude)
            || input.Latitude is < 33 or > 34.8 || input.Longitude is < 35 or > 36.7 || input.PlaceId?.Length > 255)
            throw new ArgumentException("Choose a named location in Lebanon.");
        var key = config["Maps:ServerApiKey"];
        if (string.IsNullOrWhiteSpace(key)) throw new ArgumentException("Google Maps location verification is not configured. Choose an existing venue for now.");
        // Fixed Google host: never fetch a user-supplied URL or follow arbitrary map links.
        var coordinates = FormattableString.Invariant($"{input.Latitude},{input.Longitude}");
        using var response = await clients.CreateClient("maps").GetAsync("https://maps.googleapis.com/maps/api/geocode/json?latlng=" + Uri.EscapeDataString(coordinates) + "&key=" + Uri.EscapeDataString(key), ct);
        if (!response.IsSuccessStatusCode) throw new ArgumentException("Google Maps is unavailable. Try again later.");
        using var json = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct));
        if (json.RootElement.GetProperty("status").GetString() != "OK") throw new ArgumentException("Google could not verify this location. Select another pin.");
        // Country is checked server-side; Lebanon's bounding rectangle alone includes neighboring countries.
        var result = json.RootElement.GetProperty("results")[0];
        var components = result.GetProperty("address_components").EnumerateArray().ToArray();
        bool Type(JsonElement e, string type) => e.GetProperty("types").EnumerateArray().Any(t => t.GetString() == type);
        if (!components.Any(c => Type(c, "country") && c.GetProperty("short_name").GetString() == "LB"))
            throw new ArgumentException("The chosen location must be inside Lebanon.");
        var area = components.FirstOrDefault(c => Type(c, "locality") || Type(c, "administrative_area_level_2"));
        var areaName = area.ValueKind == JsonValueKind.Undefined ? "Lebanon" : area.GetProperty("long_name").GetString()!;
        var address = result.GetProperty("formatted_address").GetString()!;
        return new(input.Name.Trim(), areaName[..Math.Min(80, areaName.Length)], address[..Math.Min(250, address.Length)], (decimal)input.Latitude, (decimal)input.Longitude, null);
    }
    public static void Map(WebApplication app)
    {
        app.MapGet("/api/venues/{id:int}/location", async (int id, Database db, CancellationToken ct) =>
        {
            var rows = (await db.Call("dbo.GetVenueLocation", ct, P("@VenueId", SqlDbType.Int, id)))[0];
            return rows.Count == 0 ? Results.NotFound() : Results.Ok(rows[0]);
        }).RequireRateLimiting("browse");
    }
}
