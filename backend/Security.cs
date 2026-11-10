using System.Data;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Options;
using static Database;

/// <summary>
/// Server-only secrets (User Secrets / environment variables, never Git or the database).
/// Security:PasswordPepper must be 32 random bytes in base64 (Security:MessageKey is only needed to migrate old messages).
/// The API refuses to start without them, so nothing is ever stored with a missing or weak key.
/// </summary>
public sealed class AppSecrets
{
    public byte[] PasswordPepper { get; }
    public byte[]? LegacyMessageKey { get; } // only to read messages encrypted by migration 33
    public AppSecrets(IConfiguration config)
    {
        PasswordPepper = Load(config, "Security:PasswordPepper");
        LegacyMessageKey = config["Security:MessageKey"] is { Length: > 0 } ? Load(config, "Security:MessageKey") : null;
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
/// Passwords: Argon2id (the current OWASP recommendation): 19 MiB memory, 2 passes, 1 lane, 16-byte random salt
/// generated per password and stored INSIDE the hash string ($argon2id$v=19$m=..,t=..,p=..$salt$hash), so no
/// separate salt column exists. The server pepper is passed as Argon2's secret input. Older PBKDF2 hashes still
/// verify once and are upgraded to Argon2id at the next successful sign-in.
/// </summary>
public sealed class Argon2idPasswordHasher(AppSecrets secrets, IOptions<PasswordHasherOptions> options) : IPasswordHasher<string>
{
    const int MemoryKiB = 19456, Passes = 2, Lanes = 1, SaltBytes = 16, HashBytes = 32;
    readonly PasswordHasher<string> legacy = new(options);
    byte[] Compute(string password, byte[] salt, int m, int t, int p)
    {
        using var a = new Konscious.Security.Cryptography.Argon2id(Encoding.UTF8.GetBytes(password))
        { Salt = salt, KnownSecret = secrets.PasswordPepper, MemorySize = m, Iterations = t, DegreeOfParallelism = p };
        return a.GetBytes(HashBytes);
    }
    static string B64(byte[] b) => Convert.ToBase64String(b).TrimEnd('=');
    static byte[] Unb64(string s) => Convert.FromBase64String(s.PadRight(s.Length + (4 - s.Length % 4) % 4, '='));
    public string HashPassword(string user, string password)
    {
        byte[] salt = RandomNumberGenerator.GetBytes(SaltBytes);
        return $"$argon2id$v=19$m={MemoryKiB},t={Passes},p={Lanes}${B64(salt)}${B64(Compute(password, salt, MemoryKiB, Passes, Lanes))}";
    }
    public PasswordVerificationResult VerifyHashedPassword(string user, string hashedPassword, string providedPassword)
    {
        if (hashedPassword.StartsWith("$argon2id$", StringComparison.Ordinal))
        {
            try
            {
                var parts = hashedPassword.Split('$'); // "", argon2id, v=19, m=..,t=..,p=.., salt, hash
                if (parts.Length != 6 || parts[2] != "v=19") return PasswordVerificationResult.Failed;
                var prm = parts[3].Split(',').Select(x => int.Parse(x[2..])).ToArray();
                if (prm.Length != 3 || prm[0] is < 8192 or > 262144 || prm[1] is < 1 or > 10 || prm[2] is < 1 or > 8)
                    return PasswordVerificationResult.Failed;
                byte[] expected = Unb64(parts[5]), actual = Compute(providedPassword, Unb64(parts[4]), prm[0], prm[1], prm[2]);
                if (!CryptographicOperations.FixedTimeEquals(expected, actual)) return PasswordVerificationResult.Failed;
                return prm[0] < MemoryKiB || prm[1] < Passes ? PasswordVerificationResult.SuccessRehashNeeded : PasswordVerificationResult.Success;
            }
            catch (FormatException) { return PasswordVerificationResult.Failed; }
        }
        // Older formats: "p1$" = PBKDF2 of the peppered password (migration 33), otherwise plain PBKDF2.
        string hash = hashedPassword, input = providedPassword;
        if (hash.StartsWith("p1$", StringComparison.Ordinal))
        { hash = hash[3..]; input = Convert.ToBase64String(HMACSHA256.HashData(secrets.PasswordPepper, Encoding.UTF8.GetBytes(providedPassword))); }
        try { return legacy.VerifyHashedPassword(user, hash, input) == PasswordVerificationResult.Failed ? PasswordVerificationResult.Failed : PasswordVerificationResult.SuccessRehashNeeded; }
        catch (FormatException) { return PasswordVerificationResult.Failed; }
    }
}

/// <summary>
/// Chat messages are now encrypted INSIDE SQL Server (AES-256 symmetric key protected by a certificate,
/// ENCRYPTBYKEY / DECRYPTBYKEYAUTOCERT in the stored procedures, migration 34). This class only reads messages
/// that migration 33 had encrypted in the API ("enc1:"), so they can be re-sealed with the SQL Server key.
/// </summary>
public sealed class LegacyMessageCrypto(AppSecrets secrets)
{
    public string? Decrypt(long conversationId, string stored)
    {
        if (secrets.LegacyMessageKey is null || !stored.StartsWith("enc1:", StringComparison.Ordinal)) return null;
        try
        {
            byte[] b = Convert.FromBase64String(stored[5..]);
            byte[] pt = new byte[b.Length - 28];
            using var aes = new AesGcm(secrets.LegacyMessageKey, 16);
            aes.Decrypt(b.AsSpan(0, 12), b.AsSpan(28), b.AsSpan(12, 16), pt, Encoding.UTF8.GetBytes("GameOn.Message.v1:" + conversationId));
            return Encoding.UTF8.GetString(pt);
        }
        catch (Exception e) when (e is CryptographicException or FormatException or ArgumentException) { return null; }
    }
}

/// <summary>Moves messages encrypted by migration 33's API key under the SQL Server key (runs once at startup).</summary>
public sealed class MessageEncryptionBackfill(Database db, LegacyMessageCrypto crypto, ILogger<MessageEncryptionBackfill> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try
        {
            int sealedCount = 0, unreadable = 0; long after = 0;
            while (!ct.IsCancellationRequested)
            {
                var rows = (await db.Call("dbo.ListLegacyMessages", ct, P("@Top", SqlDbType.Int, 500)))[0]
                    .Where(r => Convert.ToInt64(r["messageId"]) > after).ToList();
                if (rows.Count == 0) break;
                foreach (var r in rows)
                {
                    long id = Convert.ToInt64(r["messageId"]); after = Math.Max(after, id);
                    string stored = r["body"]!.ToString()!;
                    var plain = crypto.Decrypt(Convert.ToInt64(r["conversationId"]), stored);
                    if (plain is null) { unreadable++; continue; }
                    await db.Call("dbo.SealLegacyMessage", ct, P("@MessageId", SqlDbType.BigInt, id), P("@Expected", SqlDbType.NVarChar, stored, -1),
                        P("@Plain", SqlDbType.NVarChar, plain.Length > 1000 ? plain[..1000] : plain, 1000));
                    sealedCount++;
                }
            }
            if (sealedCount + unreadable > 0) log.LogInformation("Moved {Count} messages to SQL Server encryption ({Unreadable} unreadable)", sealedCount, unreadable);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        { log.LogWarning("Message re-encryption skipped ({Error}). Is migration 34 installed?", e.GetType().Name); }
    }
}
