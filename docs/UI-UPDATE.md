# Navigation and sports community design update

This update changes the React frontend only. If migrations 13/16 were repaired and migration 18 completed successfully, **do not run another database migration for this update**.

## See it in your current Windows project

1. Stop the terminal running Vite with **Ctrl+C**. Your existing backend can keep running in Visual Studio.
2. Download the latest project ZIP from https://github.com/mariaakikiiiii/Project/archive/refs/heads/main.zip and extract it.
3. Copy the extracted project's **frontend** folder into your existing project folder `C:\Users\User\Downloads\Project-main (4)\Project-main`, replacing the frontend files. Keep your existing backend, database and User Secrets.
4. In the same Developer PowerShell terminal, run these commands **one at a time**:

```powershell
Set-Location "C:\Users\User\Downloads\Project-main (4)\Project-main\frontend"
```

```powershell
$env:NODE_EXTRA_CA_CERTS = "$env:TEMP\gameon-dev.pem"
```

```powershell
npm ci
```

```powershell
npm run dev
```

The certificate command uses the public development certificate you already exported. If that file was removed, export the current .NET development certificate again using the previous certificate setup instructions; do not disable TLS verification.

5. Open the URL Vite prints (normally http://localhost:5173/) and press **Ctrl+Shift+R**. Keep using the same hostname for sign-in cookies; `localhost` and `127.0.0.1` are separate browser origins.

## What changed

- **My games** and **Inbox** now have separate, visible destinations, active navigation indicators and real hash links. Signed-out users see a page explaining what is available and a **Sign in to continue** action instead of both clicks silently opening the same sign-in view.
- Signing in returns to the page/event the user requested. Existing server-side authorization is unchanged. Signed-out views do not fetch private account resources.
- Browser Back, reload and direct links work for discovery, account pages and event details. On phones, the main destinations are persistent, tappable bottom tabs.
- Discovery has a compact welcome section, a single selector covering all 17 activities, simpler filters (extra options are behind Filters on phones), compact sponsored venues and explicit **View game** actions.
- Dark/light modes remain available and remembered. The new palette uses forest/cream surfaces, green status accents and orange primary actions. Large controls and reduced-motion support remain.

The user supplied https://www.sportcietyapp.com/ as a reference. That destination was blocked by the workspace's outbound network policy, so its current screens were not inspected or claimed to be reproduced. This is GameOn's own sports community design; a supplied screenshot can support closer visual matching later.

## Previews

These images use explicit API fixtures, not live production data:

- [Light discovery](light-theme-preview.png)
- [Dark discovery](discovery-preview.png)
- [Mobile viewport](mobile-navigation-preview.png)
- [Signed-out My games page](account-navigation-preview.png)

## Validation

The Vite production build and Chromium fixture suite pass. Navigation checks exercise both tabs signed out and signed in, no anonymous private-data requests, return to My games after login, active links, keyboard activation, mobile taps, viewport-bottom positioning, Back/reload and tablet/mobile overflow. Existing category, hosting, preferences, notifications, deposit, Whish demo/manual and map-fixture flows also pass. This update does not establish live database or payment-provider readiness.
