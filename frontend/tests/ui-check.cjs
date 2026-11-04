// Run npm run dev in another terminal first. API fixtures intentionally do not test SQL.
const { chromium } = require("playwright-core");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
(async () => {
  const browser = await chromium.launch({
    ...(process.env.GAMEON_CHROMIUM_PATH
      ? { executablePath: process.env.GAMEON_CHROMIUM_PATH }
      : fs.existsSync("/usr/bin/chromium")
        ? { executablePath: "/usr/bin/chromium" }
        : { channel: "chrome" }),
    headless: true,
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1080 },
  });
  let viewerId = 1;
  let logged = false,
    profileSaved = false,
    created = false,
    sponsored = false,
    edited = false,
    cancelled = false;
  const future = new Date(Date.now() + 30 * 86400000).toISOString();
  const game = {
    gameId: 1,
    hostUserId: 1,
    sportId: 1,
    venueId: 1,
    startsAt: future,
    capacity: 4,
    playerCount: 2,
    sponsoredSlots: 1,
    sponsoredClaimed: 0,
    sport: "Basketball",
    venue: "Central Court",
    area: "Beirut",
    address: "Central sports complex",
    costPerPlayer: 15,
    currency: "USD",
    description: "A welcoming crew. Bring your sneakers.",
    gameStatus: "Open",
    revision: 1,
    hostName: "Maria",
    matchesSport: true,
    matchesArea: true,
  };
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.route("**/api/**", async (route) => {
    const req = route.request(),
      url = new URL(req.url()),
      p = url.pathname,
      m = req.method();
    let status = 200,
      data = {};
    if (p === "/api/lookups")
      data = {
        sports: [
          { sportId: 1, name: "Basketball" },
          { sportId: 2, name: "Football" },
          { sportId: 3, name: "Padel" },
        ],
        venues: [{ venueId: 1, name: "Central Court", area: "Beirut" }],
      };
    else if (p === "/api/config")
      data = {
        mapsEmbedApiKey: "",
        passwordResetAvailable: false,
        onlinePaymentsAvailable: false,
      };
    else if (p === "/api/auth/me") {
      status = logged ? 200 : 401;
      data = logged
        ? { name: viewerId === 1 ? "Maria" : "Nour", userId: viewerId }
        : {};
    } else if (p === "/api/csrf") data = { token: "ui-fixture-token" };
    else if (p === "/api/auth/login") {
      logged = true;
      viewerId = req.postDataJSON().email === "nour@example.invalid" ? 3 : 1;
      data = { name: viewerId === 1 ? "Maria" : "Nour" };
    } else if (p === "/api/games" && m === "GET")
      data = [
        game,
        {
          ...game,
          gameId: 2,
          sport: "Football",
          sportId: 2,
          venue: "North Field",
          area: "Jounieh",
          costPerPlayer: 0,
          sponsoredSlots: 0,
        },
        {
          ...game,
          gameId: 3,
          sport: "Padel",
          sportId: 3,
          costPerPlayer: 25,
          sponsoredSlots: 0,
        },
      ];
    else if (p === "/api/games" && m === "POST") {
      const b = req.postDataJSON();
      assert.equal(b.sponsoredSlots, 1);
      assert.equal(b.currency, "USD");
      created = true;
      data = { gameId: 1 };
    } else if (p === "/api/games/1" && m === "GET")
      data = {
        game,
        roster: [
          { userId: 1, displayName: "Maria", isSponsored: false },
          { userId: 2, displayName: "Jad", isSponsored: false },
          ...(sponsored
            ? [{ userId: 3, displayName: "Nour", isSponsored: true }]
            : []),
        ],
      };
    else if (p === "/api/games/1" && m === "PUT") {
      const b = req.postDataJSON();
      assert.equal(b.revision, 1);
      edited = true;
      data = { message: "Game updated." };
    } else if (p === "/api/games/1/cancel") {
      cancelled = true;
      game.gameStatus = "Cancelled";
      data = { message: "Game cancelled." };
    } else if (p === "/api/games/1/sponsored-place") {
      sponsored = true;
      game.sponsoredClaimed = 1;
      game.playerCount = 3;
      data = { status: "Joined" };
    } else if (p === "/api/me/profile" && m === "GET")
      data = {
        profile: {
          userId: 1,
          email: "maria@example.invalid",
          displayName: "Maria",
          bio: "Weekend player",
          area: "Beirut",
          skillLevel: "Beginner",
        },
        sports: [1],
      };
    else if (p === "/api/me/profile" && m === "PUT") {
      assert.deepEqual(req.postDataJSON().sportIds, [1, 3]);
      profileSaved = true;
      data = { message: "Saved" };
    } else if (p === "/api/me/notifications")
      data = {
        items: [
          {
            notificationId: 1,
            gameId: 1,
            title: "A place opened. You are in!",
            body: "Your place is confirmed.",
            createdAt: "2026-11-05T09:00:00",
            readAt: null,
          },
        ],
        unreadCount: 1,
      };
    else if (p === "/api/me/notifications/1/read") data = null;
    else if (p === "/api/me/games") data = [{ ...game, status: "Joined" }];
    else if (p === "/api/auth/logout") {
      logged = false;
      status = 204;
      data = null;
    } else {
      console.log("UNHANDLED", m, p);
      status = 404;
      data = { error: "Unexpected UI request" };
    }
    await route.fulfill({
      status,
      contentType: "application/json",
      body: status === 204 ? "" : JSON.stringify(data),
    });
  });
  await page.goto(process.env.GAMEON_UI_URL || "http://127.0.0.1:5173");
  await page
    .getByRole("heading", { name: "Less scrolling. More playing." })
    .waitFor();
  await page.screenshot({
    path: path.join(os.tmpdir(), "GameOn-desktop.png"),
    fullPage: true,
  });
  assert.equal(await page.locator(".game-card").count(), 3);
  await page.getByRole("button", { name: "Sign in ↗" }).click();
  await page.getByLabel("Email", { exact: true }).fill("maria@example.invalid");
  await page
    .getByLabel("Password", { exact: true })
    .fill("ui-only-fake-password");
  await page.getByRole("button", { name: "Let’s play ↗" }).click();
  await page.getByRole("heading", { name: "Your next game, Maria." }).waitFor();
  await page.getByRole("button", { name: "My profile", exact: true }).click();
  await page.getByRole("heading", { name: "What’s your game?" }).waitFor();
  await page.getByLabel("Padel", { exact: true }).check();
  await page.getByRole("button", { name: "Save my preferences ↗" }).click();
  await page.getByRole("heading", { name: "Your next game, Maria." }).waitFor();
  assert(profileSaved);
  await page
    .getByRole("button", { name: "+ Host a game", exact: true })
    .click();
  await page.getByLabel("What are we playing?").selectOption("1");
  await page.getByLabel("Where’s the game?").selectOption("1");
  await page
    .getByLabel("Date & time (your local time)")
    .fill(future.slice(0, 16));
  await page.getByLabel("Venue share per player").fill("15");
  await page.getByLabel("Host-covered places").fill("1");
  await page.getByRole("button", { name: "Make this game happen ↗" }).click();
  await page
    .getByRole("heading", { name: "Basketball at Central Court" })
    .waitFor();
  assert(created);
  assert(
    (
      await page
        .getByRole("link", { name: "Get directions ↗" })
        .getAttribute("href")
    ).includes("google.com/maps/dir/"),
  );
  await page.getByRole("button", { name: "Edit game", exact: true }).click();
  await page.getByLabel("Set the vibe").fill("Updated crew details.");
  await page.getByRole("button", { name: "Save & notify the crew" }).click();
  await page
    .getByRole("heading", { name: "Basketball at Central Court" })
    .waitFor();
  assert(edited);
  // A different player can claim the covered place; host-only controls must be absent.
  await page.getByRole("button", { name: /Sign out/ }).click();
  await page.getByRole("button", { name: "Sign in ↗" }).click();
  await page.getByLabel("Email", { exact: true }).fill("nour@example.invalid");
  await page
    .getByLabel("Password", { exact: true })
    .fill("ui-only-fake-password");
  await page.getByRole("button", { name: "Let’s play ↗" }).click();
  await page.getByRole("heading", { name: "Your next game, Nour." }).waitFor();
  await page
    .getByRole("button", { name: "View Basketball at Central Court" })
    .click();
  await page
    .getByRole("heading", { name: "Basketball at Central Court" })
    .waitFor();
  assert.equal(
    await page.getByRole("button", { name: "Edit game", exact: true }).count(),
    0,
  );
  await page.getByRole("button", { name: "Claim a free place ↗" }).click();
  await page
    .getByText("Playing with a host-covered place", { exact: true })
    .waitFor();
  assert(sponsored);
  await page.getByRole("button", { name: /Sign out/ }).click();
  await page.getByRole("button", { name: "Sign in ↗" }).click();
  await page.getByLabel("Email", { exact: true }).fill("maria@example.invalid");
  await page
    .getByLabel("Password", { exact: true })
    .fill("ui-only-fake-password");
  await page.getByRole("button", { name: "Let’s play ↗" }).click();
  await page.getByRole("heading", { name: "Your next game, Maria." }).waitFor();
  await page.getByRole("button", { name: /Inbox/ }).click();
  await page.getByText("A place opened. You are in!", { exact: true }).click();
  await page
    .getByRole("heading", { name: "Basketball at Central Court" })
    .waitFor();
  await page.getByRole("button", { name: "Cancel hosted game" }).click();
  await page.getByRole("button", { name: "Yes, cancel this game" }).click();
  await page.getByText("This game was cancelled", { exact: true }).waitFor();
  assert(cancelled);
  assert.equal(
    await page
      .getByRole("button", { name: "Join this game", exact: true })
      .count(),
    0,
  );
  await page.getByRole("button", { name: "Discover", exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({
    path: path.join(os.tmpdir(), "GameOn-mobile.png"),
    fullPage: true,
  });
  assert(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  );
  assert.deepEqual(errors, []);
  await browser.close();
  console.log(
    "PASS: desktop/mobile layout, sign-in, preferences, host offer form, details/directions, host editing, non-host controls, sponsored-place claim, notifications and cancellation (mock API UI fixtures).",
  );
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
