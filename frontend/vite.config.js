import { defineConfig } from 'vite';
import { existsSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { Agent } from 'node:https';
import { join } from 'node:path';
import { tmpdir, hostname } from 'node:os';

// The API runs on HTTPS with the .NET developer certificate. Node.js does not trust it by default,
// which made every /api call fail with error 500 unless NODE_EXTRA_CA_CERTS was set by hand.
// We now load (or export once) that certificate and trust ONLY it for the proxy. Verification stays on.
const target = process.env.GAMEON_API || 'https://localhost:7043';
function devCertificate() {
  if (process.env.NODE_EXTRA_CA_CERTS) return undefined; // already trusted globally
  const pem = join(tmpdir(), 'gameon-dev.pem');
  if (!existsSync(pem)) {
    try { execFileSync('dotnet', ['dev-certs', 'https', '--export-path', pem, '--format', 'PEM', '--no-password'], { stdio: 'ignore' }); }
    catch { console.warn('[gameon] Could not export the .NET dev certificate. Run: dotnet dev-certs https --trust'); return undefined; }
  }
  try { return readFileSync(pem); } catch { return undefined; }
}
const ca = devCertificate();
const agent = ca ? new Agent({ ca, keepAlive: true }) : undefined;

// Network access: with the certificate from scripts/lan-cert.ps1, the site listens on ALL network addresses over HTTPS,
// so phones and other PCs can use it. Without it, it stays on this PC only: plain HTTP from another device
// would expose passwords and session cookies on the network, and secure cookies would not work anyway.
const lanDir = join(process.env.LOCALAPPDATA || tmpdir(), 'GameOn');
const lanPfx = join(lanDir, 'lan-cert.pfx'), lanPass = join(lanDir, 'lan-cert.pass');
const lan = existsSync(lanPfx) && existsSync(lanPass) ? { pfx: readFileSync(lanPfx), passphrase: readFileSync(lanPass, 'utf8').trim() } : null;
if (!lan) console.warn('[gameon] Local only (http://localhost). For phones/other PCs run: powershell -File scripts/lan-cert.ps1');

export default defineConfig({
  server: {
    host: lan ? '0.0.0.0' : 'localhost',
    https: lan || undefined,
    allowedHosts: [hostname().toLowerCase()], // IP addresses and localhost are always allowed
    proxy: {
      '/api': { target, secure: true, agent,
        configure: (proxy) => proxy.on('error', (err) => console.error(`[gameon] API proxy error: ${err.code || err.message}. Is the API running on ${target}?`)) },
      '/hubs': { target, secure: true, ws: true, agent } // SignalR live chat (WebSockets)
    }
  }
});
