using System.Text;
using GameOn.Payments;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;

var passed = 0;
void Check(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); passed++; Console.WriteLine("PASS: " + name); }
foreach (var (amount, expected) in new[] { (0m, 0m), (0.10m, 0.01m), (0.25m, 0.01m), (1.25m, 0.06m), (15m, 0.75m), (19.99m, 1.00m), (100m, 5m), (99999999.99m, 5000000m) })
    Check(BookingFees.ServiceFee(amount) == expected, "5% exact decimal/half-cent rounding for " + amount);
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
// Fake Google responses: country validation is tested without credentials or network.
var mapsConfig = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> { ["Maps:ServerApiKey"] = "fixture-key" }).Build();
MapsLocations NewMaps(string country) => new(new MapsClientFactory(country), mapsConfig, new Microsoft.Extensions.Caching.Memory.MemoryCache(new Microsoft.Extensions.Caching.Memory.MemoryCacheOptions()), Microsoft.Extensions.Logging.Abstractions.NullLogger<MapsLocations>.Instance);
var maps = NewMaps("LB");
var location = await maps.Verify(new LocationInput(" Host court ", 33.89, 35.5, null), CancellationToken.None);
Check(location.Name == "Host court" && location.Area == "Beirut" && location.Latitude == 33.89m, "host location normalized from verified Lebanese pin");
try { await NewMaps("SY").Verify(new LocationInput("Outside",33.89,35.5,null), CancellationToken.None); throw new InvalidOperationException("Foreign country accepted"); }
catch (ArgumentException) { Check(true, "bounding rectangle alone cannot authorize a foreign-country pin"); }
try { await maps.Verify(new LocationInput("Invalid", double.NaN,35.5,null), CancellationToken.None); throw new InvalidOperationException("Non-finite pin accepted"); }
catch (ArgumentException) { Check(true, "non-finite coordinates rejected before Google request"); }
// Google Maps links pasted by hosts: parsed offline; only Google hosts accepted; exact pin preferred.
var pin = await maps.FromGoogleLink("https://www.google.com/maps/place/Fouad+Chehab+Stadium/@33.97,35.61,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d33.9712345!4d35.6123456", CancellationToken.None);
Check(Math.Abs(pin.Latitude - 33.9712345) < 1e-9 && Math.Abs(pin.Longitude - 35.6123456) < 1e-9 && pin.Name == "Fouad Chehab Stadium", "Google place link: exact pin and name read");
var q = await maps.FromGoogleLink("https://maps.google.com/?q=33.8938,35.5018", CancellationToken.None);
Check(Math.Abs(q.Latitude - 33.8938) < 1e-9, "Google ?q=lat,lng link read");
try { await maps.FromGoogleLink("https://evil.example/maps/@33.9,35.5,15z", CancellationToken.None); throw new InvalidOperationException("Foreign host accepted"); }
catch (ArgumentException) { Check(true, "non-Google link host refused (no request made)"); }
try { await maps.FromGoogleLink("https://www.google.com/maps/@48.85,2.35,15z", CancellationToken.None); throw new InvalidOperationException("Paris accepted"); }
catch (ArgumentException) { Check(true, "link outside Lebanon refused"); }
var coordinate = MapsLocations.Coordinate("@Latitude",33.8912345m);
Check(coordinate.Precision == 10 && coordinate.Scale == 7, "ADO.NET preserves pin precision with explicit decimal scale");
var onboardingToday=new DateOnly(2026,11,5);
Check(OnboardingPolicy.ValidBirth(new DateOnly(1995,5,12),onboardingToday),"valid signup birth date accepted");
Check(!OnboardingPolicy.ValidBirth(null,onboardingToday),"missing birth date rejected");
Check(!OnboardingPolicy.ValidBirth(onboardingToday.AddDays(1),onboardingToday),"future birth date rejected");
Check(!OnboardingPolicy.ValidBirth(new DateOnly(1899,12,31),onboardingToday),"out-of-range birth date rejected");
Check(OnboardingPolicy.ValidSports([1])&&OnboardingPolicy.ValidSports([1,2,3]),"one and three distinct sport IDs accepted");
Check(!OnboardingPolicy.ValidSports([])&&!OnboardingPolicy.ValidSports([1,2,3,4]),"empty and four-sport selections rejected");
Check(!OnboardingPolicy.ValidSports([1,1])&&!OnboardingPolicy.ValidSports([-1]),"duplicate and non-positive preferences rejected");
Check(OnboardingPolicy.Genders.Contains("PreferNotToSay"),"privacy-preserving gender option available");
Console.WriteLine($"PASS: {passed} payment/security, map and onboarding policy checks. No database, Google API calls or money movement involved.");
sealed class TestClock : TimeProvider { public DateTimeOffset Now = new(2026, 11, 5, 12, 0, 0, TimeSpan.Zero); public override DateTimeOffset GetUtcNow() => Now; }
sealed class TestEnvironment(string name) : IHostEnvironment
{
    public string EnvironmentName { get; set; } = name;
    public string ApplicationName { get; set; } = "GameOn.PaymentChecks";
    public string ContentRootPath { get; set; } = Directory.GetCurrentDirectory();
    public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
}

sealed class MapsClientFactory(string country) : IHttpClientFactory
{
 public HttpClient CreateClient(string name) => new(new MapsHandler(country));
}
sealed class MapsHandler(string country) : HttpMessageHandler
{
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
 {
  if (request.RequestUri?.Host != "maps.googleapis.com" || request.Method != HttpMethod.Get) throw new InvalidOperationException("Unexpected map host or method");
  var payload = System.Text.Json.JsonSerializer.Serialize(new {status="OK",results=new[]{new{formatted_address="Fixture, Beirut, Lebanon",address_components=new[]{new{long_name="Country",short_name=country,types=new[]{"country"}},new{long_name="Beirut",short_name="Beirut",types=new[]{"locality"}}}}}});
  return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK){Content=new StringContent(payload)});
 }
}
