# GameOn as an app

GameOn now works three ways:

| Way | What it is | Works now? |
|---|---|---|
| **Website** | http://localhost:5173 in a browser | Yes |
| **Installed app (PWA)** | Install GameOn from Chrome/Edge: it gets an icon and its own window | Yes on your PC; on phones once GameOn is online with HTTPS |
| **Android app (.apk)** | A real Android app built with Capacitor (`frontend/android`) | Yes, on a phone connected by USB (or the emulator) while the API runs on your PC; everywhere once GameOn is online |

## 1. Install GameOn as an app on your PC (2 clicks)

1. Start the API (Visual Studio, F5) and the website (`npm run dev` in `frontend`).
2. Open http://localhost:5173 in **Chrome or Edge**.
3. Click the **Install** icon at the right end of the address bar (a monitor with an arrow), or open the menu (⋮) and choose **Install GameOn** (Edge: **Apps → Install this site as an app**).

GameOn opens in its own window with the GameOn icon, and appears in the Start menu.

## 2. The Android app

The Android project lives in `frontend/android`. The app id is `lb.gameon.app`.

### First build: needs a good internet connection

The first Android build downloads about 300-400 MB (Gradle and Android libraries). Do it on a fast connection; after that everything is cached and builds take about a minute. Easiest way: open `frontendndroid` in **Android Studio**, wait for "Gradle sync" to finish (bottom bar), then press **Run**.

### Build the .apk (Developer PowerShell, in the `frontend` folder)

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17.0.12.7-hotspot"
npm run build
npx cap sync android
cd android
.\gradlew.bat assembleDebug
```

The app is created at `frontend\android\app\build\outputs\apk\debug\app-debug.apk`.

Alternatively, open the `frontend\android` folder in **Android Studio** and press the green **Run** button.

### Run it on your phone (while GameOn runs on your PC)

1. On the phone: **Settings → About phone →** tap **Build number** 7 times, then **Developer options → USB debugging: on**.
2. Connect the phone by USB and accept the "Allow USB debugging" prompt.
3. On the PC (with the API and `npm run dev` running):

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb reverse tcp:5173 tcp:5173
& $adb install -r "frontend\android\app\build\outputs\apk\debug\app-debug.apk"
```

4. Open **GameOn** on the phone.

`adb reverse` forwards the phone's `localhost:5173` to your PC through the cable, which is why the app can reach GameOn while it still runs only on your computer. Run that `reverse` line again each time you reconnect the phone.

### When GameOn is online (for real users)

1. Host the API and database with HTTPS on a real domain (for example `https://app.gameon.lb`).
2. In `frontend/capacitor.config.json`, change `"url": "http://localhost:5173"` to your domain and remove `"cleartext": true`.
3. Rebuild, and sign a **release** build in Android Studio (**Build → Generate Signed App Bundle**). Keep the signing key safe: you need it for every update.
4. Publish on **Google Play Console** ($25 one-time): store listing, screenshots, privacy policy URL, data-safety form, and account deletion (already in the Admin panel).

### iPhone

The same Capacitor project can produce an iPhone app (`npx cap add ios`). Building it needs a **Mac with Xcode** and an Apple developer account ($99/year).

## What is shared and what isn't

- The app shows the same GameOn screens, uses the same API and database, and has the same accounts, wallet and bookings.
- Updating the website updates the app instantly, because it loads GameOn from your server. Rebuild the .apk only when you change the app's icon, name, permissions or server address.
- The service worker never stores accounts, money or chat. It only caches the app's own files, and shows a friendly page when the phone is offline.
