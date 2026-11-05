using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using static Database;

namespace GameOn.Payments;

public static class BookingFees
{
    public const decimal Rate = 0.02m;
    public static decimal ServiceFee(decimal amount)
    {
        if (amount < 0 || amount > 99999999.99m || decimal.Round(amount, 2) != amount)
            throw new ArgumentOutOfRangeException(nameof(amount));
        return decimal.Round(amount * Rate, 2, MidpointRounding.AwayFromZero);
    }
}

// This is GameOn's mock protocol, NOT a guessed Whish production signature scheme.
public sealed class MockPaymentSecurity
{
    private readonly byte[] key;
    private readonly TimeProvider clock;
    public bool Enabled { get; }
    public MockPaymentSecurity(IConfiguration config, IHostEnvironment environment, TimeProvider clock)
    {
        this.clock = clock;
        Enabled = (environment.IsDevelopment() || environment.IsEnvironment("Testing"))
            && config.GetValue<bool>("Payments:EnableMockCheckout");
        var configured = config["Payments:MockWebhookSecret"];
        key = string.IsNullOrEmpty(configured) ? RandomNumberGenerator.GetBytes(32) : Encoding.UTF8.GetBytes(configured);
        if (Enabled && key.Length < 32) throw new InvalidOperationException("Payments:MockWebhookSecret must contain at least 32 UTF-8 bytes.");
    }
    public (string Timestamp, string Signature) Sign(byte[] body)
    {
        if (!Enabled) throw new InvalidOperationException("Mock checkout is disabled.");
        var timestamp = clock.GetUtcNow().ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        return (timestamp, Convert.ToHexString(Digest(timestamp, body)));
    }
    public bool Verify(byte[] body, string timestamp, string signature)
    {
        if (!Enabled || timestamp.Length > 12 || signature.Length != 64 ||
            !long.TryParse(timestamp, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds)) return false;
        var now = clock.GetUtcNow().ToUnixTimeSeconds();
        if (seconds < now - 300 || seconds > now + 300) return false;
        try { return CryptographicOperations.FixedTimeEquals(Digest(timestamp, body), Convert.FromHexString(signature)); }
        catch (FormatException) { return false; }
    }
    private byte[] Digest(string timestamp, byte[] body)
    {
        var prefix = Encoding.UTF8.GetBytes(timestamp + ".");
        var bytes = new byte[prefix.Length + body.Length];
        prefix.CopyTo(bytes, 0); body.CopyTo(bytes, prefix.Length);
        return HMACSHA256.HashData(key, bytes);
    }
}
public sealed record MockWebhook(Guid WebhookEventId, Guid PaymentId, string GatewayTransactionId, string Status, decimal TotalAmount, string Currency);

public sealed class MockPaymentProcessor(Database db, MockPaymentSecurity security)
{
    public async Task<Dictionary<string, object?>> Process(byte[] body, string timestamp, string signature, CancellationToken ct)
    {
        if (!security.Verify(body, timestamp, signature)) throw new UnauthorizedAccessException("Invalid mock webhook signature.");
        var payload = JsonSerializer.Deserialize<MockWebhook>(body, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        if (payload is null || payload.PaymentId == Guid.Empty || payload.WebhookEventId == Guid.Empty ||
            string.IsNullOrWhiteSpace(payload.GatewayTransactionId) || payload.GatewayTransactionId.Length > 128 ||
            payload.Status is not "success" and not "failed" || payload.Currency is not "USD" and not "LBP" ||
            payload.TotalAmount < 0 || payload.TotalAmount > 101999999.99m || decimal.Round(payload.TotalAmount, 2) != payload.TotalAmount)
            throw new ArgumentException("Invalid mock verification payload.");
        var amount = new Microsoft.Data.SqlClient.SqlParameter("@TotalAmount", SqlDbType.Decimal)
        { Precision = 12, Scale = 2, Value = payload.TotalAmount };
        var sets = await db.Call("dbo.ApplyMockPaymentWebhook", ct,
            P("@WebhookEventID", SqlDbType.UniqueIdentifier, payload.WebhookEventId),
            P("@PaymentID", SqlDbType.UniqueIdentifier, payload.PaymentId),
            P("@GatewayTransactionID", SqlDbType.NVarChar, payload.GatewayTransactionId, 128),
            P("@Outcome", SqlDbType.VarChar, payload.Status, 12), amount,
            P("@Currency", SqlDbType.Char, payload.Currency, 3), P("@PayloadHash", SqlDbType.Binary, SHA256.HashData(body), 32));
        return sets[0][0];
    }
}
