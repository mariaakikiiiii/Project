using System.Text;
using GameOn.Payments;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;

var passed = 0;
void Check(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); passed++; Console.WriteLine("PASS: " + name); }
foreach (var (amount, expected) in new[] { (0m, 0m), (0.25m, 0.01m), (1.25m, 0.03m), (15m, 0.30m), (19.99m, 0.40m), (100m, 2m), (99999999.99m, 2000000m) })
    Check(BookingFees.ServiceFee(amount) == expected, "2% exact decimal/half-cent rounding for " + amount);
foreach (var amount in new[] { -1m, 0.001m, 100000000m })
{
    try { BookingFees.ServiceFee(amount); throw new InvalidOperationException("Invalid amount accepted"); }
    catch (ArgumentOutOfRangeException) { Check(true, "invalid base amount rejected"); }
}
var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Payments:EnableMockCheckout"] = "true" }).Build();
var time = new TestClock();
var security = new MockPaymentSecurity(config, new TestEnvironment("Development"), time);
var body = Encoding.UTF8.GetBytes("{\"paymentId\":\"fixture\",\"totalAmount\":15.30}");
var signed = security.Sign(body);
Check(security.Verify(body, signed.Timestamp, signed.Signature), "valid raw-body HMAC accepted");
Check(!security.Verify(Encoding.UTF8.GetBytes("{\"totalAmount\":0}"), signed.Timestamp, signed.Signature), "tampered amount/body rejected");
Check(!security.Verify(body, signed.Timestamp, new string('0', 64)), "forged signature rejected");
Check(!security.Verify(body, "not-a-time", signed.Signature), "invalid timestamp rejected");
time.Now = time.Now.AddMinutes(6);
Check(!security.Verify(body, signed.Timestamp, signed.Signature), "expired signature rejected");
time.Now = time.Now.AddMinutes(-12);
Check(!security.Verify(body, signed.Timestamp, signed.Signature), "future signature rejected");
time.Now = time.Now.AddMinutes(6);
var other = new MockPaymentSecurity(config, new TestEnvironment("Development"), time);
Check(!other.Verify(body, signed.Timestamp, signed.Signature), "unrelated ephemeral signing key rejected");
var production = new MockPaymentSecurity(config, new TestEnvironment("Production"), time);
Check(!production.Enabled && !production.Verify(body, signed.Timestamp, signed.Signature), "Production cannot enable mock checkout even with the flag set");
var disabled = new MockPaymentSecurity(new ConfigurationBuilder().Build(), new TestEnvironment("Development"), time);
Check(!disabled.Enabled, "mock checkout flag must be enabled explicitly");
Console.WriteLine($"PASS: {passed} payment policy/security checks. No database or money movement involved.");
sealed class TestClock : TimeProvider { public DateTimeOffset Now = new(2026, 11, 5, 12, 0, 0, TimeSpan.Zero); public override DateTimeOffset GetUtcNow() => Now; }
sealed class TestEnvironment(string name) : IHostEnvironment
{
    public string EnvironmentName { get; set; } = name;
    public string ApplicationName { get; set; } = "GameOn.PaymentChecks";
    public string ContentRootPath { get; set; } = Directory.GetCurrentDirectory();
    public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
}
