using System.Data;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Options;
using static Database;

/// <summary>
/// Server-only secrets (User Secrets / environment variables, never Git or the database).
/// Security:PasswordPepper and Security:MessageKey must each be 32 random bytes in base64.
/// The API refuses to start without them, so nothing is ever stored with a missing or weak key.
/// </summary>
public sealed class AppSecrets
{
    public byte[] PasswordPepper { get; }
    public byte[] MessageKey { get; }
    public AppSecrets(IConfiguration config)
    {
        PasswordPepper = Load(config, "Security:PasswordPepper");
        MessageKey = Load(config, "Security:MessageKey");
        if (CryptographicOperations.FixedTimeEquals(PasswordPepper, MessageKey))
            throw new InvalidOperationException("Security:PasswordPepper and Security:MessageKey must be different secrets.");
    }
    static byte[] Load(IConfiguration config, string name)
    {
        byte[] value;
        try { value = Convert.FromBase64String(config[name] ?? ""); } catch (FormatException) { value = []; }
        if (value.Length != 32)
            throw new InvalidOperationException($"{name} is missing or invalid. Generate one with scripts/new-secrets.ps1 (see docs/SECURITY.md).");
        return value;
    }
}

/// <summary>
/// Passwords: PBKDF2-HMAC-SHA512, 210,000 iterations, a unique random 128-bit SALT per password (stored inside the hash),
/// plus a secret PEPPER (HMAC-SHA256 with a server key). A stolen database alone is not enough to test password guesses.
/// Old unpeppered hashes still verify once and are upgraded at the next successful sign-in.
/// </summary>
public sealed class PepperedPasswordHasher(AppSecrets secrets, IOptions<PasswordHasherOptions> options) : IPasswordHasher<string>
{
    public const string Prefix = "p1$";
    readonly PasswordHasher<string> inner = new(options);
    string Pepper(string password) => Convert.ToBase64String(HMACSHA256.HashData(secrets.PasswordPepper, Encoding.UTF8.GetBytes(password)));
    public string HashPassword(string user, string password) => Prefix + inner.HashPassword(user, Pepper(password));
    public PasswordVerificationResult VerifyHashedPassword(string user, string hashedPassword, string providedPassword)
    {
        if (hashedPassword.StartsWith(Prefix, StringComparison.Ordinal))
            return inner.VerifyHashedPassword(user, hashedPassword[Prefix.Length..], Pepper(providedPassword));
        PasswordVerificationResult legacy;
        try { legacy = inner.VerifyHashedPassword(user, hashedPassword, providedPassword); }
        catch (FormatException) { return PasswordVerificationResult.Failed; }
        return legacy == PasswordVerificationResult.Failed ? legacy : PasswordVerificationResult.SuccessRehashNeeded;
    }
}

/// <summary>
/// Chat messages are encrypted with AES-256-GCM before they reach SQL Server. The database only ever holds
/// "enc1:" + base64(nonce | tag | ciphertext). The conversation id is bound as associated data, so a ciphertext
/// copied into another chat fails to decrypt. Anyone reading the Messages table (backup, SSMS, leak) sees no text.
/// </summary>
public sealed class MessageCrypto(AppSecrets secrets)
{
    public const string Prefix = "enc1:";
    static byte[] Aad(long conversationId) => Encoding.UTF8.GetBytes("GameOn.Message.v1:" + conversationId);
    public string Encrypt(long conversationId, string plain)
    {
        byte[] pt = Encoding.UTF8.GetBytes(plain), nonce = RandomNumberGenerator.GetBytes(12), tag = new byte[16], ct = new byte[pt.Length];
        using var aes = new AesGcm(secrets.MessageKey, 16);
        aes.Encrypt(nonce, pt, ct, tag, Aad(conversationId));
        return Prefix + Convert.ToBase64String([.. nonce, .. tag, .. ct]);
    }
    public string Decrypt(long conversationId, string? stored)
    {
        if (string.IsNullOrEmpty(stored) || !stored.StartsWith(Prefix, StringComparison.Ordinal)) return stored ?? "";
        try
        {
            byte[] b = Convert.FromBase64String(stored[Prefix.Length..]);
            if (b.Length < 28) return "(message unavailable)";
            byte[] pt = new byte[b.Length - 28];
            using var aes = new AesGcm(secrets.MessageKey, 16);
            aes.Decrypt(b.AsSpan(0, 12), b.AsSpan(28), b.AsSpan(12, 16), pt, Aad(conversationId));
            return Encoding.UTF8.GetString(pt);
        }
        catch (Exception e) when (e is CryptographicException or FormatException) { return "(message unavailable)"; }
    }
    /// <summary>Decrypts the body column of message rows in place.</summary>
    public List<Dictionary<string, object?>> Open(List<Dictionary<string, object?>> rows)
    {
        foreach (var r in rows) r["body"] = Decrypt(Convert.ToInt64(r["conversationId"]), r["body"]?.ToString());
        return rows;
    }
}

/// <summary>Encrypts chat messages that were stored before encryption existed (runs once at startup, in small batches).</summary>
public sealed class MessageEncryptionBackfill(Database db, MessageCrypto crypto, ILogger<MessageEncryptionBackfill> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try
        {
            int total = 0;
            while (!ct.IsCancellationRequested)
            {
                var rows = (await db.Call("dbo.ListPlainMessages", ct, P("@Top", SqlDbType.Int, 200)))[0];
                if (rows.Count == 0) break;
                foreach (var r in rows)
                {
                    long conv = Convert.ToInt64(r["conversationId"]); string plain = r["body"]!.ToString()!;
                    await db.Call("dbo.EncryptMessageBody", ct, P("@MessageId", SqlDbType.BigInt, Convert.ToInt64(r["messageId"])),
                        P("@Plain", SqlDbType.NVarChar, plain, -1), P("@Cipher", SqlDbType.NVarChar, crypto.Encrypt(conv, plain), -1));
                }
                total += rows.Count;
            }
            if (total > 0) log.LogInformation("Encrypted {Count} older chat messages", total);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        { log.LogWarning("Message encryption backfill skipped ({Error}). Is migration 33 installed?", e.GetType().Name); }
    }
}
