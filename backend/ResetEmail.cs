using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Encodings.Web;

// HTTPS email API. API key stays server-side; browser receives only an availability flag.
public sealed class ResetEmail(IConfiguration config, IHttpClientFactory clients)
{
    public bool Enabled => !string.IsNullOrWhiteSpace(config["Email:ApiKey"])
        && !string.IsNullOrWhiteSpace(config["Email:From"])
        && Uri.TryCreate(config["App:PublicOrigin"], UriKind.Absolute, out var uri)
        && (uri.Scheme == "https" || (uri.IsLoopback && uri.Scheme == "http"));
    public async Task Send(string to, string token, CancellationToken ct)
    {
        var origin = new Uri(config["App:PublicOrigin"]!);
        string link = new Uri(origin, "/?reset=" + Uri.EscapeDataString(token)).AbsoluteUri;
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.resend.com/emails");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config["Email:ApiKey"]);
        // Retries of the same delivery must not send duplicate messages.
        request.Headers.TryAddWithoutValidation("Idempotency-Key", "gameon-reset-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(token))));
        request.Content = JsonContent.Create(new
        {
            from = config["Email:From"],
            to = new[] { to },
            subject = "Reset your GameOn password",
            html = "<p>Reset your GameOn password using the link below. It expires in 30 minutes.</p><p><a href=\""
                + HtmlEncoder.Default.Encode(link) + "\">Reset password</a></p><p>If you did not request this, ignore this email.</p>"
        });
        using var response = await clients.CreateClient("email").SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
    }
}
