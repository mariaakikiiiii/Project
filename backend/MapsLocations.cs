using System.Data;
using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Caching.Memory;
using static Database;

public sealed record LocationInput(string Name, double Latitude, double Longitude, string? PlaceId);
public sealed record VerifiedLocation(string Name, string Area, string Address, decimal Latitude, decimal Longitude, string? PlaceId);
public sealed record PlaceResult(string Name, string Area, string Address, double Latitude, double Longitude, string Source);
public sealed record LinkInput(string Url);

// Location services for hosts choosing their own meeting point anywhere in Lebanon.
// - With Maps:ServerApiKey: Google Geocoding verifies the pin (country must be LB).
// - Without it: OpenStreetMap Nominatim verifies the pin and powers place search.
//   Nominatim's usage policy is respected: identifying User-Agent, max 1 request/second,
//   results cached, no bulk storage. For a large commercial launch, use Google or a paid provider.
public sealed class MapsLocations(IHttpClientFactory clients, IConfiguration config, IMemoryCache cache, ILogger<MapsLocations> log)
{
    private static readonly SemaphoreSlim NominatimGate = new(1, 1);
    private static DateTime lastNominatim = DateTime.MinValue;
    private static readonly string[] GoogleHosts = ["google.com", "www.google.com", "maps.google.com", "maps.app.goo.gl", "goo.gl", "www.google.com.lb", "google.com.lb"];

    public bool UsesGoogle => !string.IsNullOrWhiteSpace(config["Maps:ServerApiKey"]);

    public static Microsoft.Data.SqlClient.SqlParameter Coordinate(string name, decimal? value)
    {
        var parameter = P(name, SqlDbType.Decimal, value);
        parameter.Precision = 10; parameter.Scale = 7;
        return parameter;
    }

    private static bool InLebanonBox(double lat, double lng) => double.IsFinite(lat) && double.IsFinite(lng) && lat is >= 33 and <= 34.8 && lng is >= 35 and <= 36.7;

    public async Task<VerifiedLocation> Verify(LocationInput input, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(input.Name) || input.Name.Length > 120 || !InLebanonBox(input.Latitude, input.Longitude) || input.PlaceId?.Length > 255)
            throw new ArgumentException("Choose a named location in Lebanon.");
        return UsesGoogle ? await VerifyWithGoogle(input, ct) : await VerifyWithOsm(input, ct);
    }

    private async Task<VerifiedLocation> VerifyWithGoogle(LocationInput input, CancellationToken ct)
    {
        // Fixed Google host: never fetch a user-supplied URL here.
        var coordinates = FormattableString.Invariant($"{input.Latitude},{input.Longitude}");
        using var response = await clients.CreateClient("maps").GetAsync("https://maps.googleapis.com/maps/api/geocode/json?latlng=" + Uri.EscapeDataString(coordinates) + "&key=" + Uri.EscapeDataString(config["Maps:ServerApiKey"]!), ct);
        if (!response.IsSuccessStatusCode) throw new ArgumentException("Google Maps is unavailable. Try again later.");
        using var json = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct));
        var status = json.RootElement.GetProperty("status").GetString();
        if (status == "REQUEST_DENIED") { log.LogWarning("Google Geocoding denied the request: check Geocoding API, billing and key restrictions."); throw new ArgumentException("Location check is misconfigured. Ask the GameOn admin to check the Google server key."); }
        if (status != "OK") throw new ArgumentException("Google could not verify this location. Select another pin.");
        var result = json.RootElement.GetProperty("results")[0];
        var components = result.GetProperty("address_components").EnumerateArray().ToArray();
        bool Type(JsonElement e, string type) => e.GetProperty("types").EnumerateArray().Any(t => t.GetString() == type);
        if (!components.Any(c => Type(c, "country") && c.GetProperty("short_name").GetString() == "LB"))
            throw new ArgumentException("The chosen location must be inside Lebanon.");
        var area = components.FirstOrDefault(c => Type(c, "locality") || Type(c, "administrative_area_level_2"));
        var areaName = area.ValueKind == JsonValueKind.Undefined ? "Lebanon" : area.GetProperty("long_name").GetString()!;
        var address = result.GetProperty("formatted_address").GetString()!;
        return new(input.Name.Trim(), Cut(areaName, 80), Cut(address, 250), (decimal)input.Latitude, (decimal)input.Longitude, input.PlaceId);
    }

    private async Task<VerifiedLocation> VerifyWithOsm(LocationInput input, CancellationToken ct)
    {
        var url = string.Create(CultureInfo.InvariantCulture, $"https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&zoom=16&accept-language=en&lat={input.Latitude:F6}&lon={input.Longitude:F6}");
        using var json = await Nominatim(url, ct) ?? throw new ArgumentException("The map service is busy. Try again in a moment.");
        var root = json.RootElement;
        if (!root.TryGetProperty("address", out var address) || !address.TryGetProperty("country_code", out var cc) || cc.GetString() != "lb")
            throw new ArgumentException("The chosen location must be inside Lebanon.");
        return new(input.Name.Trim(), Cut(AreaOf(address), 80), Cut(root.GetProperty("display_name").GetString() ?? "Lebanon", 250),
            Math.Round((decimal)input.Latitude, 7), Math.Round((decimal)input.Longitude, 7), null);
    }

    public async Task<IReadOnlyList<PlaceResult>> Search(string query, CancellationToken ct)
    {
        var q = query.Trim();
        return await cache.GetOrCreateAsync("places:" + q.ToLowerInvariant(), async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromHours(12);
            var url = "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=10&countrycodes=lb&accept-language=en&q=" + Uri.EscapeDataString(q);
            using var json = await Nominatim(url, ct);
            if (json is null) return (IReadOnlyList<PlaceResult>)[];
            var list = new List<PlaceResult>();
            foreach (var r in json.RootElement.EnumerateArray())
            {
                if (!double.TryParse(r.GetProperty("lat").GetString(), CultureInfo.InvariantCulture, out var lat) || !double.TryParse(r.GetProperty("lon").GetString(), CultureInfo.InvariantCulture, out var lng) || !InLebanonBox(lat, lng)) continue;
                var display = r.GetProperty("display_name").GetString() ?? "";
                var name = r.TryGetProperty("name", out var n) && !string.IsNullOrWhiteSpace(n.GetString()) ? n.GetString()! : display.Split(',')[0];
                var area = r.TryGetProperty("address", out var a) ? AreaOf(a) : "Lebanon";
                list.Add(new(Cut(name, 120), Cut(area, 80), Cut(display, 250), lat, lng, "OpenStreetMap"));
            }
            return list;
        }) ?? [];
    }

    // Reads coordinates from a Google Maps link the host copied (Share → Copy link, or the browser address bar).
    // Only Google hosts are contacted; short links are followed manually, max 4 hops, Google hosts only.
    public async Task<PlaceResult> FromGoogleLink(string raw, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(raw) || raw.Length > 2000 || !Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" || !GoogleHosts.Contains(uri.Host.ToLowerInvariant()))
            throw new ArgumentException("Paste a Google Maps link (https://maps.app.goo.gl/… or https://www.google.com/maps/…).");
        var client = clients.CreateClient("googlelinks");
        for (var hop = 0; hop < 4 && Parse(uri) is null; hop++)
        {
            if (uri.Host is not ("maps.app.goo.gl" or "goo.gl")) break;
            using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
            if ((int)response.StatusCode is < 300 or > 399 || response.Headers.Location is null) break;
            var next = response.Headers.Location.IsAbsoluteUri ? response.Headers.Location : new Uri(uri, response.Headers.Location);
            if (next.Scheme != "https" || !GoogleHosts.Contains(next.Host.ToLowerInvariant())) throw new ArgumentException("That link does not lead to Google Maps.");
            uri = next;
        }
        var parsed = Parse(uri) ?? throw new ArgumentException("This link has no exact location. In Google Maps, open the place, tap Share → Copy link, and paste that.");
        if (!InLebanonBox(parsed.Lat, parsed.Lng)) throw new ArgumentException("That place is outside Lebanon.");
        return new(parsed.Name ?? "Pinned location", "", "", parsed.Lat, parsed.Lng, "Google Maps link");
    }

    private static (double Lat, double Lng, string? Name)? Parse(Uri uri)
    {
        var text = WebUtility.UrlDecode(uri.ToString());
        string? name = null;
        var place = Regex.Match(text, @"/maps/place/([^/@]+)");
        if (place.Success) name = Cut(place.Groups[1].Value.Replace('+', ' ').Trim(), 120);
        // Prefer the exact pin (!3d!4d) over the viewport centre (@lat,lng).
        foreach (var pattern in new[] { @"!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)", @"[?&](?:q|query|ll|destination)=(-?\d+\.\d+),\s*(-?\d+\.\d+)", @"@(-?\d+\.\d+),(-?\d+\.\d+)" })
        {
            var m = Regex.Match(text, pattern);
            if (m.Success && double.TryParse(m.Groups[1].Value, CultureInfo.InvariantCulture, out var lat) && double.TryParse(m.Groups[2].Value, CultureInfo.InvariantCulture, out var lng))
                return (lat, lng, name);
        }
        return null;
    }

    private async Task<JsonDocument?> Nominatim(string url, CancellationToken ct)
    {
        if (!await NominatimGate.WaitAsync(TimeSpan.FromSeconds(8), ct)) return null;
        try
        {
            var wait = lastNominatim.AddMilliseconds(1100) - DateTime.UtcNow;
            if (wait > TimeSpan.Zero) await Task.Delay(wait, ct);
            lastNominatim = DateTime.UtcNow;
            using var response = await clients.CreateClient("nominatim").GetAsync(url, ct);
            if (!response.IsSuccessStatusCode) { log.LogWarning("Nominatim returned {Status}", (int)response.StatusCode); return null; }
            return JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct));
        }
        catch (HttpRequestException) { return null; }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { return null; }
        finally { NominatimGate.Release(); }
    }

    private static string AreaOf(JsonElement address)
    {
        foreach (var key in new[] { "city", "town", "village", "suburb", "municipality", "county", "state" })
            if (address.TryGetProperty(key, out var v) && !string.IsNullOrWhiteSpace(v.GetString())) return v.GetString()!;
        return "Lebanon";
    }
    private static string Cut(string s, int max) => s.Length <= max ? s : s[..max];

    public static void Map(WebApplication app)
    {
        app.MapGet("/api/venues/{id:int}/location", async (int id, Database db, CancellationToken ct) =>
        {
            var rows = (await db.Call("dbo.GetVenueLocation", ct, P("@VenueId", SqlDbType.Int, id)))[0];
            return rows.Count == 0 ? Results.NotFound() : Results.Ok(rows[0]);
        }).RequireRateLimiting("browse");
        app.MapGet("/api/places/search", async (string? q, MapsLocations maps, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(q) || q.Trim().Length is < 2 or > 100) return Results.BadRequest(new { error = "Type at least 2 characters." });
            return Results.Ok(await maps.Search(q, ct));
        }).RequireAuthorization().RequireRateLimiting("browse");
        app.MapPost("/api/places/from-link", async (LinkInput input, MapsLocations maps, CancellationToken ct) =>
        {
            try { return Results.Ok(await maps.FromGoogleLink(input.Url, ct)); }
            catch (ArgumentException ex) { return Results.BadRequest(new { error = ex.Message }); }
        }).RequireAuthorization().RequireRateLimiting("checkout");
    }
}
