using System.Data;
using System.Security.Claims;
using System.Text.Json;
using static Database;

namespace GameOn.Payments;
public static class CommercialEndpoints
{
    private static int User(ClaimsPrincipal user) => int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    public const string MockWebhookPath = "/api/payments/whish/mock/webhook";
    public static void MapCommercial(this WebApplication app)
    {
        app.MapGet("/api/venues/sponsored", async (Database db, CancellationToken ct) =>
            Results.Ok((await db.Call("dbo.GetSponsoredVenues", ct))[0])).RequireRateLimiting("browse");
        app.MapGet("/api/games/{id:int}/quote", async (int id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var quote = (await db.Call("dbo.GetPaymentQuote", ct, P("@GameId", SqlDbType.Int, id), P("@UserId", SqlDbType.Int, User(user))))[0][0];
            if (BookingFees.ServiceFee(Convert.ToDecimal(quote["amount"])) != Convert.ToDecimal(quote["serviceFee"]))
                throw new InvalidOperationException("Database and API service-fee policies disagree.");
            return Results.Ok(quote);
        }).RequireAuthorization().RequireRateLimiting("browse");
        app.MapPost("/api/games/{id:int}/checkout", async (int id, CheckoutRequest input, ClaimsPrincipal user, Database db, MockPaymentSecurity mock, CancellationToken ct) =>
        {
            if (input.IdempotencyKey == Guid.Empty || input.Method is not "Cash" and not "WhishMock")
                return Results.BadRequest(new { error = "Choose a valid payment method and checkout key." });
            if (input.Method == "WhishMock" && !mock.Enabled)
                return Results.Json(new { error = "Mock checkout is unavailable in this environment." }, statusCode: 503);
            var rows = (await db.Call("dbo.InitializeCheckout", ct, P("@GameId", SqlDbType.Int, id),
                P("@UserId", SqlDbType.Int, User(user)), P("@Mode", SqlDbType.VarChar, input.Method, 12),
                P("@IdempotencyKey", SqlDbType.UniqueIdentifier, input.IdempotencyKey), P("@ExpectedRevision", SqlDbType.Int, input.Revision)))[0];
            return Results.Ok(rows[0]);
        }).RequireAuthorization().RequireRateLimiting("checkout");
        app.MapGet("/api/payments/{id:guid}", async (Guid id, ClaimsPrincipal user, Database db, CancellationToken ct) =>
        {
            var rows = (await db.Call("dbo.GetPayment", ct, P("@PaymentID", SqlDbType.UniqueIdentifier, id), P("@UserId", SqlDbType.Int, User(user))))[0];
            return rows.Count == 0 ? Results.NotFound() : Results.Ok(rows[0]);
        }).RequireAuthorization();
        // Deliberate demo action. Owner + CSRF required. Never available in Production.
        app.MapPost("/api/payments/{id:guid}/mock-complete", async (Guid id, ClaimsPrincipal user, Database db, MockPaymentSecurity security, MockPaymentProcessor processor, CancellationToken ct) =>
        {
            if (!security.Enabled) return Results.NotFound();
            var rows = (await db.Call("dbo.GetPayment", ct, P("@PaymentID", SqlDbType.UniqueIdentifier, id), P("@UserId", SqlDbType.Int, User(user))))[0];
            if (rows.Count == 0) return Results.NotFound();
            var payment = rows[0];
            if (payment["mode"]?.ToString() != "WhishMock") return Results.BadRequest(new { error = "This is not a mock Whish checkout." });
            if (payment["status"]?.ToString() != "MockPending") return Results.Ok(payment);
            var payload = new MockWebhook(Guid.NewGuid(), id, "mock_" + id.ToString("N"), "success", Convert.ToDecimal(payment["totalAmount"]), payment["currency"]!.ToString()!);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            var signed = security.Sign(bytes);
            return Results.Ok(await processor.Process(bytes, signed.Timestamp, signed.Signature, ct));
        }).RequireAuthorization().RequireRateLimiting("checkout");
        // Exact CSRF exemption; the raw-body HMAC authenticates this provider-style route.
        app.MapPost(MockWebhookPath, async (HttpContext context, MockPaymentSecurity security, MockPaymentProcessor processor, CancellationToken ct) =>
        {
            if (!security.Enabled) return Results.NotFound();
            using var body = new MemoryStream();
            await context.Request.Body.CopyToAsync(body, ct);
            try
            {
                var result = await processor.Process(body.ToArray(), context.Request.Headers["X-GameOn-Mock-Timestamp"].ToString(), context.Request.Headers["X-GameOn-Mock-Signature"].ToString(), ct);
                return Results.Ok(result);
            }
            catch (UnauthorizedAccessException) { return Results.Unauthorized(); }
            catch (Exception ex) when (ex is ArgumentException or JsonException)
            { return Results.BadRequest(new { error = "Invalid mock webhook payload." }); }
        }).AllowAnonymous().RequireRateLimiting("checkout");
    }
}
public sealed record CheckoutRequest(string Method, Guid IdempotencyKey, int Revision);
