namespace GameOn.Payments;

// Base URLs supplied by the merchant. Operation paths, signing/authentication headers
// and response schemas are private and must be confirmed before implementing calls.
public sealed class WhishMerchantConfiguration(IConfiguration configuration)
{
    public const string SandboxBaseUrl = "https://lb.sandbox.whish.money/itel-service/api/";
    public const string ProductionBaseUrl = "https://whish.money/itel-service/api/";
    public Uri BaseAddress => new(configuration["Whish:Environment"] == "Production" ? ProductionBaseUrl : SandboxBaseUrl);
    public bool HasMerchantConfiguration => !string.IsNullOrWhiteSpace(configuration["Whish:ChannelId"])
        && !string.IsNullOrWhiteSpace(configuration["Whish:SecretKey"])
        && Uri.TryCreate(configuration["Whish:WebsiteUrl"], UriKind.Absolute, out var website)
        && website.Scheme == "https";
    // SecretKey and ChannelId remain in IConfiguration; never expose them through API DTOs.
    // No live/sandbox requests are executed by this release, per merchant instruction.
}
