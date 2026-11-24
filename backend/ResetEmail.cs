using System.Net;
using System.Net.Mail;
using System.Text.Encodings.Web;

// Sends password-reset and email-verification links over SMTP (Gmail with an app password by default):
//   Email:SmtpUser + Email:SmtpPassword [+ Email:SmtpHost, Email:SmtpPort]. Delivers to any address, no domain needed.
// Credentials stay server-side (user secrets). Without them, Development builds print the link to the API console
// instead, so the flows can be demonstrated locally; Production never logs links.
public sealed class ResetEmail(IConfiguration config, IHostEnvironment env, ILogger<ResetEmail> log)
{
    public bool Enabled => !string.IsNullOrWhiteSpace(config["Email:SmtpUser"])
        && !string.IsNullOrWhiteSpace(config["Email:SmtpPassword"])
        && Uri.TryCreate(config["App:PublicOrigin"], UriKind.Absolute, out var uri)
        && (uri.Scheme == "https" || (uri.IsLoopback && uri.Scheme == "http"));
    /// <summary>True when emails can be delivered: really (SMTP), or to the console in Development.</summary>
    public bool CanDeliver => Enabled || env.IsDevelopment();

    public async Task Send(string to, string token, string purpose, CancellationToken ct)
    {
        bool verify = purpose == "Verify";
        string origin = Uri.TryCreate(config["App:PublicOrigin"], UriKind.Absolute, out var o) ? o.GetLeftPart(UriPartial.Authority) : "http://127.0.0.1:5173";
        string link = new Uri(new Uri(origin), (verify ? "/?verify=" : "/?reset=") + Uri.EscapeDataString(token)).AbsoluteUri;
        string subject = verify ? "Confirm your GameOn email" : "Reset your GameOn password";
        if (!Enabled)
        {
            // Development only (CanDeliver guards callers): show the link so the presenter can open it.
            log.LogWarning("DEV EMAIL to {To}: {Subject}\n    {Link}", to, subject, link);
            return;
        }
        string href = HtmlEncoder.Default.Encode(link);
        string html = verify
            ? "<p>Welcome to GameOn! Confirm your email to start booking and chatting. The link expires in 24 hours.</p><p><a href=\""
                + href + "\">Confirm my email</a></p><p>If you did not create a GameOn account, ignore this email.</p>"
            : "<p>Reset your GameOn password using the link below. It expires in 30 minutes.</p><p><a href=\""
                + href + "\">Reset password</a></p><p>If you did not request this, ignore this email.</p>";
        string text = subject + "\n\nOpen this link: " + link + "\n\nIf you did not request this, ignore this email.";

        string user = config["Email:SmtpUser"]!;
        string host = config["Email:SmtpHost"] is { Length: > 0 } h ? h : "smtp.gmail.com";
        int port = int.TryParse(config["Email:SmtpPort"], out var p) ? p : 587;
        // Gmail only sends as the signed-in account, so the sender address is always the SMTP user.
        using var message = new MailMessage(new MailAddress(user, "GameOn"), new MailAddress(to)) { Subject = subject };
        message.AlternateViews.Add(AlternateView.CreateAlternateViewFromString(text, null, "text/plain"));
        message.AlternateViews.Add(AlternateView.CreateAlternateViewFromString(html, null, "text/html"));
        using var smtp = new SmtpClient(host, port)
        {
            EnableSsl = true, // STARTTLS on 587
            DeliveryMethod = SmtpDeliveryMethod.Network,
            UseDefaultCredentials = false,
            Credentials = new NetworkCredential(user, config["Email:SmtpPassword"]!.Replace(" ", "")),
            Timeout = 20000,
        };
        await smtp.SendMailAsync(message, ct);
    }
}
