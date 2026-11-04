using System.Data;
using Microsoft.AspNetCore.DataProtection;
using static Database;

// Durable, leased outbox: resets have the same HTTP response for known and unknown accounts.
// Tokens are protected before storage. Configure durable encrypted Data Protection keys in production.
public sealed class ResetDelivery(IServiceProvider services, ILogger<ResetDelivery> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var email = services.GetRequiredService<ResetEmail>();
                if (email.Enabled)
                {
                    var db = services.GetRequiredService<Database>();
                    var lease = Guid.NewGuid();
                    var rows = (await db.Call("dbo.ClaimResetEmail", stoppingToken, P("@Lease", SqlDbType.UniqueIdentifier, lease)))[0];
                    if (rows.Count > 0)
                    {
                        var row = rows[0]; bool sent = false;
                        try
                        {
                            var protector = services.GetRequiredService<IDataProtectionProvider>().CreateProtector("GameOn.ResetEmail.v1");
                            var token = protector.Unprotect(row["protectedToken"]!.ToString()!);
                            await email.Send(row["recipient"]!.ToString()!, token, stoppingToken);
                            sent = true;
                        }
                        catch (Exception ex) when (ex is not OperationCanceledException)
                        { logger.LogWarning("Password email delivery failed ({ErrorType}); retry is queued.", ex.GetType().Name); }
                        await db.Call("dbo.CompleteResetEmail", stoppingToken,
                            P("@Id", SqlDbType.BigInt, row["outboxId"]), P("@Lease", SqlDbType.UniqueIdentifier, lease), P("@Sent", SqlDbType.Bit, sent));
                    }
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            { logger.LogWarning("Email queue unavailable ({ErrorType}).", ex.GetType().Name); }
            try { await Task.Delay(TimeSpan.FromSeconds(10), stoppingToken); }
            catch (OperationCanceledException) { break; }
        }
    }
}
