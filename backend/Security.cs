using System.Data;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Options;
using static Database;

/// <summary>
/// Server-only secrets (User Secrets / environment variables, never Git or the database).
/// Security:PasswordPepper must be 32 random bytes in base64. Chat messages are encrypted inside SQL Server (migration 34).
/// The API refuses to start without them, so nothing is ever stored with a missing or weak key.
/// </summary>
public sealed class AppSecrets
{
    public byte[] PasswordPepper { get; }
    public AppSecrets(IConfiguration config)
    {
        PasswordPepper = Load(config, "Security:PasswordPepper");
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
