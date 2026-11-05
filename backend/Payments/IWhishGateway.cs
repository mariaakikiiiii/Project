namespace GameOn.Payments;

// Actual provider field names/signatures must come from the merchant contract.
// This boundary makes that dependency explicit; no invented checkout URL or success.
public interface IWhishGateway
{
    bool IsAvailable { get; }
    Task<WhishCheckout> CreateCheckout(WhishOrder order, CancellationToken ct);
}
public sealed record WhishOrder(Guid OrderId, int EventId, int UserId, decimal Amount, string Currency);
public sealed record WhishCheckout(string ProviderReference, Uri CheckoutUrl);
public sealed class UnconfiguredWhishGateway : IWhishGateway
{
    public bool IsAvailable => false;
    public Task<WhishCheckout> CreateCheckout(WhishOrder order, CancellationToken ct) =>
        throw new InvalidOperationException("Whish merchant API documentation and secure sandbox configuration are required.");
}
