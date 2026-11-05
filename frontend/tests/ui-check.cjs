// Browser regression tests with explicit API fixtures. These do NOT execute SQL.
const { chromium } = require("playwright-core");
const fs = require("node:fs"),
  os = require("node:os"),
  path = require("node:path"),
  assert = require("node:assert/strict");
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
    hasTouch: true,
  });
  const names = [
    "Basketball",
    "Football (Soccer)",
    "Padel",
    "Tennis",
    "Volleyball",
    "Badminton",
    "Table Tennis (Ping Pong)",
    "Squash",
    "Swimming",
    "Paintball",
    "Laser Tag",
    "iCombat / Tactical Laser Tag",
    "Escape Rooms",
    "Go-Karting",
    "Bowling",
    "Archery Tag",
    "Airsoft",
  ];
  const types = names.map((name, i) => ({
    sportId: i + 1,
    subtypeId: i + 1,
    name,
    categoryId: i < 9 ? 1 : 2,
    categorySlug: i < 9 ? "sports" : "activities",
  }));
  const future = new Date(Date.now() + 30 * 86400000).toISOString();
  const base = {
    hostUserId: 1,
    venueId: 1,
    startsAt: future,
    capacity: 4,
    playerCount: 2,
    sponsoredSlots: 0,
    sponsoredClaimed: 0,
    venue: "Central Court",
    area: "Beirut",
    address: "Fixture venue address",
    costPerPlayer: 15,
    currency: "USD",
    description: "Bring your friends and your gear.",
    gameStatus: "Open",
    revision: 1,
    hostName: "Maria",
    matchesSport: false,
    matchesArea: false,
  };
  const make = (id, type, extra = {}) => ({
    ...base,
    gameId: id,
    sportId: type.sportId,
    sport: type.name,
    categorySlug: type.categorySlug,
    categoryName:
      type.categorySlug === "sports" ? "Sports" : "Entertainment Activities",
    ...extra,
  });
  const events = [
    make(1, types[0], { sponsoredSlots: 1 }),
    make(2, types[1], { costPerPlayer: 0 }),
    make(3, types[2], {requiresDeposit:true,depositAmount:1,venueIsVerified:true,contactPhoneNumber:"+96100000000",costPerPlayer:2}),
    make(4, types[9], { venue: "Adventure Arena" }),
    make(5, types[14], { capacity: 2, playerCount: 2 }),
  ];
  let mapsEnabled = false, lastCreatedLocation = null, anonymousPrivateRequests = 0, registered = false;
  let viewer = 0,
    profileSaved = false,
    created = false,
    activityCreated = false,
    edited = false,
    sponsored = false,
    cancelled = false,
    cashJoined = false,
    queued = false;
  let depositBooking = null;
  const paymentRecords = new Map();
  const memberships = new Map(),
    errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  const me = () => ({ userId: viewer, name: viewer === 7 ? "NewPlayer" : viewer === 1 ? "Maria" : "Nour", canManageVenues:false });
  const key = (id) => `${viewer}:${id}`;
  await page.route("**/api/**", async (route) => {
    const req = route.request(),
      url = new URL(req.url()),
      p = url.pathname,
      m = req.method();
    if (!viewer && p.startsWith("/api/me/")) anonymousPrivateRequests++;
    let status = 200,
      data = {};
    if (p === "/api/lookups")
      data = {
        sports: types,
        subtypes: types,
        categories: [
          { categoryId: 1, name: "Sports", slug: "sports" },
          {
            categoryId: 2,
            name: "Entertainment Activities",
            slug: "activities",
          },
        ],
        venues: [{ venueId: 1, name: "Central Court", area: "Beirut" }],
      };
    else if(p === "/api/venues/search") {
      const q=(url.searchParams.get("q")||"").toLowerCase();
      data=[{venueId:1,name:"Central Court",area:"Beirut",address:"Fixture court",latitude:null,longitude:null,isVerified:false,isDemo:true,hasActivityDetails:false},{venueId:2,name:"North Field",area:"Jounieh",address:"Fixture field",latitude:null,longitude:null,isVerified:false,isDemo:true,hasActivityDetails:false}].filter(v=>`${v.name} ${v.area} ${v.address}`.toLowerCase().includes(q));
    }
    else if (p === "/api/venues/sponsored")
      data = [
        {
          venueId: 1,
          name: "Central Court",
          area: "Beirut",
          address: "Fixture venue address",
          tier: "Gold",
        },
        {
          venueId: 2,
          name: "North Field",
          area: "Jounieh",
          address: "Fixture field",
          tier: "Silver",
        },
      ];
    else if (p === "/api/config")
      data = {
        mapsEmbedApiKey: "",
        mapsBrowserApiKey: mapsEnabled ? "fixture-browser-key" : "",
        mapsPickerAvailable: mapsEnabled,
        manualWhishAvailable: true,
        manualWhishRecipient: "+96171364432",
        passwordResetAvailable: false,
        onlinePaymentsAvailable: false,
        payoutAvailable: false,
        mockPaymentsAvailable: true,
        serviceFeeRate: 0.05,
      };
    else if (p === "/api/csrf") data = { token: "ui-fixture-token" };
    else if (p === "/api/auth/me") {
      status = viewer ? 200 : 401;
      data = viewer ? me() : {};
    } else if (p === "/api/auth/register") {
      const b=req.postDataJSON();assert.equal(b.gender,"Female");assert.equal(b.dateOfBirth,"1998-05-14");assert.deepEqual(b.sportIds,[1,2,3]);registered=true;viewer=7;data={message:"Your account is ready."};
    } else if (p === "/api/auth/login") {
      viewer = req.postDataJSON().email === "nour@example.invalid" ? 3 : 1;
      data = { name: me().name };
    } else if (p === "/api/auth/logout") {
      viewer = 0;
      status = 204;
    } else if (p === "/api/games" && m === "GET") {
      const q = url.searchParams;
      data = events.filter(
        (g) =>
          g.gameStatus === "Open" &&
          (!q.get("category") || g.categorySlug === q.get("category")) &&
          (!q.get("sportId") || g.sportId === Number(q.get("sportId"))) &&
          (!q.get("openOnly") || g.playerCount < g.capacity),
      );
    } else if (p === "/api/games" && m === "POST") {
      const b = req.postDataJSON();
      lastCreatedLocation = b.location;
      assert.equal(b.currency, "USD");
      if (b.sportId === 1) {
        assert.equal(b.sponsoredSlots, 1);
        created = true;
        data = { gameId: 1 };
      } else {
        assert.equal(b.sportId, 10);
        activityCreated = true;
        events.push(make(6, types[9], { costPerPlayer: 0, playerCount: 1 }));
        data = { gameId: 6 };
      }
    } else if (/^\/api\/games\/\d+$/.test(p)) {
      const id = Number(p.split("/").at(-1)),
        g = events.find((g) => g.gameId === id);
      if (m === "PUT") {
        assert.equal(req.postDataJSON().revision, 1);
        edited = true;
        data = { message: "Event updated." };
      } else
        data = {
          game: g,
          roster: [
            { userId: 1, displayName: "Maria", isSponsored: false },
            { userId: 2, displayName: "Jad", isSponsored: false, depositStatus:"PAID_HELD" },
            ...(memberships.get(`3:${id}`)?.status === "Joined"
              ? [
                  {
                    userId: 3,
                    displayName: "Nour",
                    isSponsored: id === 1 && sponsored,
                  },
                ]
              : []),
          ],
          membership:
            viewer === 1
              ? { status: "Joined", paymentMethod: "Cash" }
              : memberships.get(key(id)) || null,
        };
    } else if (p === "/api/games/3/deposit-quote") {
      data = {gameId:3,revision:1,requiresDeposit:true,depositAmount:1,currency:"USD",baseAmount:2,serviceFee:0.10,totalAmount:3.10,venueIsVerified:true,isOpen:true,isFull:false,paymentMethod:url.searchParams.get("method")||"WhishManual",dueNow:url.searchParams.get("method")==="Cash"?1:3.10};
    } else if (p === "/api/games/3/deposit-checkout") {
      depositBooking = {depositId:"30000000-0000-4000-8000-000000000003",gameId:3,baseAmount:2,serviceFee:0.10,depositAmount:1,totalAmount:3.10,currency:"USD",depositStatus:"PENDING",recipientNumber:"+96171364432",eventRevision:1,currentRevision:1,gameStatus:"Open",startsAt:future,sport:"Padel",venue:"Central Court"};
      data = depositBooking;
    } else if (p === "/api/deposits/30000000-0000-4000-8000-000000000003/transfer") {
      depositBooking = {...depositBooking,transferReference:req.postDataJSON().reference};data = depositBooking;
    } else if (p === "/api/me/deposits") { data={deposits:depositBooking?[depositBooking]:[],canReview:false};
    } else if (/^\/api\/games\/\d+\/quote$/.test(p)) {
      const id = Number(p.split("/")[3]),
        g = events.find((g) => g.gameId === id);
      data = {
        gameId: id,
        amount: g.costPerPlayer,
        serviceFee: 0.75,
        totalAmount: g.costPerPlayer + 0.75,
        currency: g.currency,
        revision: g.revision,
        isFull: g.playerCount >= g.capacity,
        alreadyEnrolled: memberships.has(key(id)),
        isOpen: g.gameStatus === "Open",
      };
    } else if (/^\/api\/games\/\d+\/checkout$/.test(p)) {
      const id = Number(p.split("/")[3]),
        g = events.find((g) => g.gameId === id),
        b = req.postDataJSON();
      assert.equal(b.revision, 1);
      assert.match(b.idempotencyKey, /^[a-f0-9-]{36}$/i);
      const paymentId =
        (b.method === "WhishMock" ? "10000000" : b.method === "WhishManual" ? "20000000" : "00000000") +
        "-0000-4000-8000-" +
        String(id).padStart(12, "0");
      if (b.method === "WhishMock") {
        data = {
          paymentId,
          gameId: id,
          amount: g.costPerPlayer,
          serviceFee: 0.75,
          totalAmount: g.costPerPlayer + 0.75,
          currency: "USD",
          mode: "WhishMock",
          status: "MockPending",
        };
        paymentRecords.set(paymentId, data);
      } else {
        assert(["Cash", "WhishManual"].includes(b.method));
        const state =
          id === 5
            ? { status: "Waitlisted", queuePosition: 1, paymentMethod: "Cash" }
            : { status: "Joined", paymentMethod: "Cash" };
        memberships.set(key(id), state);
        if (id === 5) queued = true;
        else cashJoined = true;
        data = {
          paymentId: state.status === "Waitlisted" ? null : paymentId,
          status: state.status === "Waitlisted" ? "Waitlisted" : "PendingCash",
          mode: b.method,
          recipientNumber: b.method === "WhishManual" ? "+96171364432" : null,
          gameId: id,
          amount: g.costPerPlayer,
          serviceFee: 0.75,
          totalAmount: g.costPerPlayer + 0.75,
          currency: "USD",
        };
        if (b.method === "WhishManual") { data.status = "AwaitingTransfer"; paymentRecords.set(paymentId, data); }
      }
    } else if (p === "/api/me/payments") {
      data = { payments: [...paymentRecords.values()].filter(row => row.mode === "WhishManual").map(row => ({...row, sport:"Paintball", venue:"Adventure Arena"})), canReview:false };
    } else if (/^\/api\/payments\/[a-f0-9-]+\/transfer$/.test(p)) {
      const paymentId = p.split("/")[3];
      assert.equal(req.postDataJSON().reference, "WHISH-TEST-123");
      data = {...paymentRecords.get(paymentId), status:"AwaitingVerification", transferReference:"WHISH-TEST-123"};
      paymentRecords.set(paymentId, data);
    } else if (/^\/api\/payments\/[a-f0-9-]+\/mock-complete$/.test(p)) {
      const paymentId = p.split("/")[3];
      data = { ...paymentRecords.get(paymentId), status: "MockSucceeded" };
      paymentRecords.set(paymentId, data);
      memberships.set(key(data.gameId), {
        status: "Joined",
        paymentMethod: "WhishMock",
      });
    } else if (/^\/api\/games\/\d+\/join$/.test(p)) {
      const id = Number(p.split("/")[3]);
      assert.equal(req.postDataJSON().paymentMethod, "Cash");
      const state =
        id === 5
          ? { status: "Waitlisted", queuePosition: 1, paymentMethod: "Cash" }
          : { status: "Joined", paymentMethod: "Cash" };
      memberships.set(key(id), state);
      if (id === 5) queued = true;
      else cashJoined = true;
      data = state;
    } else if (p === "/api/games/1/sponsored-place") {
      sponsored = true;
      events[0].sponsoredClaimed = 1;
      events[0].playerCount = 3;
      memberships.set(key(1), { status: "Joined", paymentMethod: "Cash" });
      data = { status: "Joined" };
    } else if (/^\/api\/games\/\d+\/participation$/.test(p)) {
      memberships.delete(key(Number(p.split("/")[3])));
      data = { status: "Cancelled" };
    } else if (p === "/api/games/1/cancel") {
      cancelled = true;
      events[0].gameStatus = "Cancelled";
      data = { message: "Event cancelled." };
    } else if (p === "/api/me/profile" && m === "GET")
      data = {
        profile: {
          ...me(),
          email: "maria@example.invalid",
          displayName:viewer===7?"NewPlayer":"Maria",
          gender:viewer===7?"Female":null,dateOfBirth:viewer===7?"1998-05-14":null,
          bio: "Weekend player",
          area: "Beirut",
          skillLevel: "Beginner",
        },
        sports:viewer===7?[1,2,3]:[1],
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
            createdAt: new Date().toISOString(),
            readAt: null,
          },
        ],
        unreadCount: 1,
      };
    else if (p === "/api/me/notifications/1/read") status = 204;
    else if (p === "/api/me/games") data = [{ ...events[0], status: "Joined" }];
    else {
      status = 404;
      data = { error: `Unexpected fixture request ${m} ${p}` };
    }
    await route.fulfill({
      status,
      contentType: "application/json",
      body: status === 204 ? "" : JSON.stringify(data),
    });
  });
  async function login(email, name) {
    await page.getByRole("button", { name: "Sign in ↗" }).click();
    await page.getByLabel("Email", { exact: true }).fill(email);
    await page
      .getByLabel("Password", { exact: true })
      .fill("ui-only-fake-password");
    await page.getByRole("button", { name: "Let’s play ↗" }).click();
    await page
      .getByRole("heading", { name: `Your next game, ${name}.` })
      .waitFor();
  }
  async function discover() {
    await page.getByRole("link", { name: "Discover", exact: true }).click();
    await page.locator(".game-card").first().waitFor();
  }
  async function open(sport, venue) {
    await page
      .getByRole("button", { name: `View ${sport} at ${venue}`, exact: true })
      .click();
    await page
      .getByRole("heading", { name: `${sport} at ${venue}`, exact: true })
      .waitFor();
  }
  // Explicit Google library fixture; no real Google request or credential is used.
  await page.addInitScript(() => {
    const point = {lat:() => 33.89, lng:() => 35.5};
    class MapFixture {
      constructor(element) { this.element = element; }
      addListener(type, callback) { const button = document.createElement("button"); button.type="button"; button.textContent="Choose fixture pin"; button.onclick=() => callback({latLng:point}); this.element.appendChild(button); return {remove:() => button.remove()}; }
      setCenter() {} setZoom() {}
    }
    class MarkerFixture { constructor(options) { Object.assign(this, options); } addListener() {} }
    const Place = {searchByText: async request => { window.__mapsSearch = request; return {places:[
      {id:"fixture-lb", displayName:"Lebanese Court Fixture", formattedAddress:"Beirut, Lebanon", location:point, addressComponents:[{types:["country"],shortText:"LB"}],googleMapsURI:"https://www.google.com/maps/search/?api=1&query=Beirut"},
      {id:"fixture-foreign", displayName:"Outside Lebanon Fixture", formattedAddress:"Outside", location:point, addressComponents:[{types:["country"],shortText:"SY"}]}
    ]}; }};
    window.google = {maps:{importLibrary:async name => name === "maps" ? {Map:MapFixture} : name === "marker" ? {AdvancedMarkerElement:MarkerFixture} : {Place}}};
  });
  await page.goto(process.env.GAMEON_UI_URL || "http://127.0.0.1:5173");
  await page
    .getByRole("heading", { name: "Find your next game." })
    .waitFor();
  await page.locator(".game-card").nth(4).waitFor();
  await page
    .getByRole("heading", { name: "Featured venues" })
    .waitFor();
  const nav=page.getByRole("navigation",{name:"Main navigation"});
  for(const name of ["My games","Inbox","My profile"])assert.equal(await nav.getByRole("link",{name,exact:true}).count(),0);
  assert.equal(await page.getByRole("button",{name:"+ Host event",exact:true}).count(),0);
  await nav.getByRole("link",{name:"Venues",exact:true}).click();
  await page.getByRole("heading",{name:"Find your venue",exact:true}).waitFor();
  await page.getByLabel("Town or neighborhood",{exact:true}).fill("Jounieh");
  assert.equal(await page.getByRole("link",{name:/Google Maps/}).count(),0);
  await page.getByRole("button",{name:"Search venues",exact:true}).click();
  await page.locator(".venue-results").getByText("North Field",{exact:true}).waitFor();
  assert.match(page.url(),/#\/venues$/);
  assert.equal(await page.getByRole("link",{name:/Google Maps/}).count(),0);
  await page.getByRole("button",{name:"View venue",exact:true}).click();
  await page.getByRole("heading",{name:"North Field",exact:true}).waitFor();
  assert.match(await page.getByRole("link",{name:"Open selected venue in Google Maps ↗",exact:true}).getAttribute("href"),/North%20Field/);
  await page.screenshot({path:path.join(os.tmpdir(),"GameOn-venue-search.png"),animations:"disabled"});
  await page.getByRole("button",{name:"Sign up",exact:true}).click();
  await page.getByLabel("Your name",{exact:true}).fill("NewPlayer");
  await page.getByLabel("Email",{exact:true}).fill("new@example.invalid");
  await page.getByLabel("Password",{exact:true}).fill("ui-only-fake-password");
  await page.getByLabel("Gender",{exact:true}).selectOption("Female");
  await page.getByLabel("Date of birth",{exact:true}).fill("1998-05-14");
  await page.getByRole("button",{name:"Join the crew ↗",exact:true}).click();
  await page.getByText("Choose at least one sport (up to three).",{exact:true}).waitFor();
  assert.equal(registered,false);
  for(const sport of ["Basketball","Football (Soccer)","Padel"])await page.getByLabel(sport,{exact:true}).check();
  assert.equal(await page.getByLabel("Tennis",{exact:true}).isDisabled(),true);
  assert.equal(await page.getByLabel("Paintball",{exact:true}).count(),0);
  await page.setViewportSize({width:390,height:844});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.screenshot({path:path.join(os.tmpdir(),"GameOn-signup-mobile.png"),fullPage:true,animations:"disabled"});
  await page.setViewportSize({width:1440,height:1080});
  await page.screenshot({path:path.join(os.tmpdir(),"GameOn-signup.png"),fullPage:true,animations:"disabled"});
  await page.getByRole("button",{name:"Join the crew ↗",exact:true}).click();
  await page.getByRole("heading",{name:"Your next game, NewPlayer.",exact:true}).waitFor();
  assert(registered);
  for(const name of ["My games","Inbox","My profile"])assert.equal(await nav.getByRole("link",{name:new RegExp(name)}).count(),1);
  await nav.getByRole("link",{name:"My profile",exact:true}).click();
  await page.getByLabel("Date of birth",{exact:true}).waitFor();
  assert.equal(await page.getByLabel("Date of birth",{exact:true}).inputValue(),"1998-05-14");
  assert.equal(await page.getByLabel("Gender",{exact:true}).inputValue(),"Female");
  assert.equal(await page.locator(".sports-picker input:checked").count(),3);
  await page.getByRole("button",{name:/Sign out/}).click();
  await page.getByRole("heading",{name:"Find your next game.",exact:true}).waitFor();
  for(const name of ["My games","Inbox","My profile"])assert.equal(await nav.getByRole("link",{name,exact:true}).count(),0);
  // A manually opened protected bookmark still uses the sign-in gate, without exposing private menu links.
  await page.goto((process.env.GAMEON_UI_URL||"http://127.0.0.1:5173")+"/#/my-games");
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  await page.getByRole("link",{name:"Skip to content",exact:true}).focus();await page.keyboard.press("Enter");
  assert.equal(await page.evaluate(()=>document.activeElement.id),"main");
  await page.goto((process.env.GAMEON_UI_URL||"http://127.0.0.1:5173")+"/#/inbox");
  await page.getByRole("heading",{name:"Inbox",exact:true}).waitFor();
  await page.goBack();
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  await page.reload();
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  assert.equal(anonymousPrivateRequests,0,"signed-out tabs do not request private data");
  await page.screenshot({path:path.join(os.tmpdir(),"GameOn-account-gate.png"),animations:"disabled"});
  await page.getByRole("button",{name:"Sign in to continue",exact:true}).click();
  await page.getByText("Sign in to continue to My games.",{exact:true}).waitFor();
  await page.getByLabel("Email",{exact:true}).fill("maria@example.invalid");
  await page.getByLabel("Password",{exact:true}).fill("ui-only-fake-password");
  await page.getByRole("button",{name:"Let’s play ↗",exact:true}).click();
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  assert.equal(await page.locator(".account-gate").count(),0);
  await page.getByRole("button",{name:"View Basketball at Central Court",exact:true}).waitFor();
  await page.reload();
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  await nav.getByRole("link",{name:/Inbox/}).click();
  await page.getByRole("heading",{name:"Inbox",exact:true}).waitFor();
  await page.goBack();
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  await page.getByRole("button",{name:/Sign out/}).click();
  await page.getByRole("heading",{name:"Find your next game.",exact:true}).waitFor();
  await page.locator(".sponsored-label").nth(1).waitFor();
  assert.equal(await page.locator(".sponsored-label").count(), 2);
  assert.equal(await page.getByLabel("Sport or activity", {exact:true}).locator("option").count(), 18);
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
  await page.getByRole("button", { name: "Switch to light mode" }).click();
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "light");
  await page.reload();
  await page.locator(".game-card").nth(4).waitFor();
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "light");
  await page.screenshot({ path: path.join(os.tmpdir(), "GameOn-light.png"), fullPage: true, animations: "disabled" });
  await page.getByRole("button", { name: "Switch to dark mode" }).click();
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--page").trim()), "#000000");
  await page.screenshot({
    path: path.join(os.tmpdir(), "GameOn-desktop.png"),
    fullPage: true,
    animations: "disabled",
  });
  await page.getByRole("button", { name: "Activities", exact: true }).click();
  await page
    .getByRole("button", { name: "View Paintball at Adventure Arena" })
    .waitFor();
  assert.equal(await page.locator(".game-card").count(), 2);
  assert.equal(await page.getByLabel("Sport or activity", {exact:true}).locator("option").count(), 9);
  await page.getByRole("button", { name: "Sports", exact: true }).click();
  await page
    .getByRole("button", { name: "View Basketball at Central Court" })
    .waitFor();
  assert.equal(await page.locator(".game-card").count(), 3);
  await page.getByRole("button", { name: "All", exact: true }).click();
  await page.locator(".game-card").nth(4).waitFor();
  await page.getByLabel("Open spots only").check();
  await page.getByRole("button", { name: "Find events ↗" }).click();
  await page.waitForFunction(
    () => document.querySelectorAll(".game-card").length === 4,
  );
  await page.getByLabel("Open spots only").uncheck();
  await page.getByRole("button", { name: "Find events ↗" }).click();
  await page.locator(".game-card").nth(4).waitFor();
  await login("maria@example.invalid", "Maria");
  await page.getByRole("link", { name: "My profile", exact: true }).click();
  await page.getByLabel("Padel", { exact: true }).check();
  await page.getByRole("button", { name: "Save my preferences ↗" }).click();
  await page.getByRole("heading", { name: "Your next game, Maria." }).waitFor();
  assert(profileSaved);
  await page.getByRole("button", { name: "+ Host event", exact: true }).click();
  await page.getByLabel("Sport or activity type").selectOption("1");
  await page.getByRole("button", { name: "Continue →" }).click();
  await page
    .getByLabel("Date & time (your local time)")
    .fill(future.slice(0, 16));
  await page.getByText("Find Basketball venues in Lebanon",{exact:true}).click();
  await page.getByLabel("Town or neighborhood",{exact:true}).fill("Jounieh");
  await page.getByRole("button",{name:"Search venues",exact:true}).click();
  await page.getByRole("button",{name:"Choose venue",exact:true}).click();
  assert.equal(await page.getByLabel("Venue",{exact:true}).inputValue(),"2");
  await page.getByLabel("Venue", { exact: true }).selectOption("1");
  await page.getByRole("button", { name: "Continue →" }).click();
  await page.getByLabel("Venue share per person").fill("15");
  await page.getByLabel("Host-covered places").fill("1");
  await page.getByRole("button", { name: "Publish event →" }).click();
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
  await page.getByRole("button", { name: "Continue →" }).click();
  await page.getByLabel("Set the vibe").fill("Updated event information.");
  await page.getByRole("button", { name: "Save & notify the crew" }).click();
  await page
    .getByRole("heading", { name: "Basketball at Central Court" })
    .waitFor();
  assert(edited);
  await page.getByRole("button", { name: /Sign out/ }).click();
  await login("nour@example.invalid", "Nour");
  await open("Basketball", "Central Court");
  assert.equal(
    await page.getByRole("button", { name: "Edit game", exact: true }).count(),
    0,
  );

  await page.getByRole("button", { name: "Claim a free place ↗" }).click();
  await page
    .getByText("Playing with a host-covered place", { exact: true })
    .waitFor();
  assert(sponsored);
  await discover();
  await open("Bowling", "Central Court");
  await page
    .getByRole("button", { name: "FULL — Join Waitlist", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Join waitlist — no payment now" })
    .click();
  await page.getByText(/Waitlisted · position #1/).waitFor();
  assert(queued);
  await page.getByRole("button", { name: "Leave game / waitlist" }).click();
  await page
    .getByRole("button", { name: "FULL — Join Waitlist", exact: true })
    .waitFor();
  await discover();
  await open("Paintball", "Adventure Arena");
  await page
    .getByRole("button", { name: "Join this event", exact: true })
    .click();
  const checkout = page.getByRole("dialog", { name: "Review your booking" });
  await checkout
    .getByText("Platform service fee (5%)", { exact: true })
    .waitFor();
  assert.match(
    (await checkout.locator("dd").allTextContents()).join(" "),
    /15\.75/,
  );
  await checkout.screenshot({path:path.join(os.tmpdir(),"GameOn-checkout.png")});
  await checkout
    .getByRole("button", { name: "Confirm cash reservation" })
    .click();
  await page.getByText(/Your place is confirmed · cash at venue/).waitFor();
  assert(cashJoined);
  await page.getByRole("button", { name: "Leave game / waitlist" }).click();
  await page
    .getByRole("button", { name: "Join this event", exact: true })
    .click();
  await page.getByRole("radio", { name: /Whish Pay — demo/ }).check();
  await page
    .getByRole("button", { name: "Initialize mock Whish checkout" })
    .click();
  await page
    .getByText("Mock Whish checkout initialized", { exact: true })
    .waitFor();
  await page
    .getByRole("button", { name: "Simulate Whish payment — no real charge" })
    .click();
  await page.getByText(/DEMO Whish — no real charge/).waitFor();

  await page.getByRole("button", { name: "Leave game / waitlist" }).click();
  await page.getByRole("button", { name: "Join this event", exact:true }).click();
  await page.getByRole("radio", { name: /Whish Money transfer/ }).check();
  await page.getByRole("button", { name: "Reserve & show Whish instructions" }).click();
  await page.getByRole("heading", { name: "Your place is reserved. Transfer with Whish." }).waitFor();
  assert.equal(await page.locator(".transfer-number a").textContent(), "+96171364432");
  await page.locator(".checkout-dialog").screenshot({path:path.join(os.tmpdir(),"GameOn-manual-whish.png")});
  await page.getByLabel("Whish transfer reference").fill("WHISH-TEST-123");
  await page.getByRole("button", { name: "I transferred — submit reference" }).click();
  await page.getByText("Awaiting verification", {exact:true}).waitFor();
  await page.getByRole("button", { name: "Close checkout" }).click();
  await page.getByRole("button",{name:"Payments & venue shares ↗",exact:true}).click();
  await page.getByText(/Paintball at Adventure Arena · USD 15.75 · Awaiting verification/).waitFor();
  await page.locator(".payment-record summary").click();
  await page.getByText("Awaiting verification", {exact:true}).waitFor();
  assert.equal(await page.getByRole("heading", {name:"Whish transfer reviews"}).count(), 0);
  await discover();
  await page.locator(".venue-discovery summary").click();
  await page.locator(".venue-discovery input").fill("Tripoli");
  await page.locator(".venue-discovery").getByRole("button",{name:"Search venues",exact:true}).click();
  await page.getByText("No venues matched this search. Try a nearby town or another activity. No external page was opened.",{exact:true}).waitFor();
  assert.equal(await page.getByRole("link",{name:/Open selected venue/}).count(),0);
  await discover();
  await open("Padel","Central Court");
  await page.getByRole("heading",{name:"Call Venue to Reserve",exact:true}).waitFor();
  assert.equal(await page.getByRole("link",{name:"Call Now",exact:true}).getAttribute("href"),"tel:+96100000000");
  await page.getByText("Deposit Verified · Spot Reserved",{exact:true}).waitFor();
  await page.getByRole("button",{name:"Join this event",exact:true}).click();
  const depositDialog = page.getByRole("dialog",{name:"Review your deposit booking"});
  await depositDialog.getByText("Platform fee (5% of game share)",{exact:true}).waitFor();
  assert.match((await depositDialog.locator("dd").allTextContents()).join(" "),/\$2\.00.*\$1\.00.*\$0\.10.*\$3\.10/);
  await page.getByRole("radio",{name:"Pay the $1 deposit now; share and fee in cash at the venue",exact:true}).check();
  await page.waitForFunction(()=>document.querySelector(".checkout-dialog .fee-breakdown .total dd")?.textContent==="$1.00");
  await page.getByRole("radio",{name:"Pay share, fee and deposit with Whish",exact:true}).check();
  await page.waitForFunction(()=>document.querySelector(".checkout-dialog .fee-breakdown .total dd")?.textContent==="$3.10");
  await depositDialog.screenshot({path:path.join(os.tmpdir(),"GameOn-deposit-checkout.png")});
  await page.getByRole("button",{name:"Continue to Whish deposit transfer"}).click();
  await depositDialog.getByLabel("Whish transfer reference").fill("DEPOSIT-FIXTURE-123");
  await page.getByRole("button",{name:"Submit deposit transfer reference"}).click();
  await page.getByText("Reference submitted. Awaiting operator verification. Do not transfer again.",{exact:true}).waitFor();
  assert.equal(depositBooking.depositStatus,"PENDING");
  await page.getByRole("button",{name:"Close deposit checkout"}).click();
  await page.getByRole("button",{name:"Payments & venue shares ↗",exact:true}).click();
  await page.getByText("Padel at Central Court · Deposit pending",{exact:true}).waitFor();
  await page.getByRole("button", { name: /Sign out/ }).click();
  await login("maria@example.invalid", "Maria");
  await page.getByRole("link", { name: /Inbox/ }).click();
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
      .getByRole("button", { name: "Join this event", exact: true })
      .count(),
    0,
  );
  await page.getByRole("button", { name: "+ Host event", exact: true }).click();
  await page.getByRole("button", { name: "Activities", exact: true }).click();
  await page.getByLabel("Sport or activity type").selectOption("10");
  await page.getByRole("button", { name: "Continue →" }).click();
  await page
    .getByLabel("Date & time (your local time)")
    .fill(future.slice(0, 16));
  await page.getByLabel("Venue", { exact: true }).selectOption("1");
  await page.getByRole("button", { name: "Continue →" }).click();
  await page.getByRole("button", { name: "Publish event →" }).click();
  await page
    .getByRole("heading", { name: "Paintball at Central Court" })
    .waitFor();
  assert(activityCreated);
  await discover();
  await page.setViewportSize({ width: 390, height: 844 });
  if (await page.getByRole("button",{name:"Dismiss notification",exact:true}).count()) await page.getByRole("button",{name:"Dismiss notification",exact:true}).click();
  await page.screenshot({path:path.join(os.tmpdir(),"GameOn-mobile-viewport.png"),animations:"disabled"});
  await page.screenshot({
    path: path.join(os.tmpdir(), "GameOn-mobile.png"),
    fullPage: true,
    animations: "disabled",
  });
  assert(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  );
  await page.getByRole("button",{name:/^Filters/}).tap();
  await page.getByLabel("Neighborhood",{exact:true}).waitFor({state:"visible"});
  await page.getByRole("button",{name:/^Filters/}).tap();
  await page.getByLabel("Neighborhood",{exact:true}).waitFor({state:"hidden"});
  await nav.getByRole("link",{name:"My games",exact:true}).tap();
  await page.getByRole("heading",{name:"My games",exact:true}).waitFor();
  await nav.getByRole("link",{name:/Inbox/}).tap();
  await page.getByRole("heading",{name:"Inbox",exact:true}).waitFor();
  const bar=await nav.boundingBox();
  assert(bar.y>600 && bar.y+bar.height<=845,"mobile tabs are fixed to the viewport bottom and tappable");
  await discover();
  await page.setViewportSize({width:820,height:1000});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),"tablet layout stays within viewport");
  await page.setViewportSize({width:390,height:844});
  await page.emulateMedia({ reducedMotion: "reduce" });
  assert.equal(await page.locator(".live-dot").evaluate(el => getComputedStyle(el).animationName), "none");
  await page.getByRole("button", { name: "Switch to light mode" }).click();
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  mapsEnabled = true;
  await page.setViewportSize({width:1440,height:1080});
  await page.reload();
  await page.locator(".game-card").first().waitFor();
  await page.getByLabel("Sport or activity",{exact:true}).selectOption("1");
  await page.locator(".venue-discovery summary").click();
  await page.locator(".venue-discovery").getByRole("button",{name:"Search venues",exact:true}).click();
  await page.getByText("Lebanese Court Fixture",{exact:true}).waitFor();
  assert.equal(await page.getByText("Outside Lebanon Fixture",{exact:true}).count(),0);
  assert.match(await page.evaluate(() => window.__mapsSearch.textQuery), /basketball court rental/);
  await page.getByRole("button", {name:"+ Host event",exact:true}).click();
  await page.getByLabel("Sport or activity type").selectOption("1");
  await page.getByRole("button", {name:"Continue →"}).click();
  await page.getByLabel("Date & time (your local time)").fill(future.slice(0,16));
  await page.getByText("Find Basketball venues in Lebanon", {exact:true}).click();
  await page.getByLabel("Choose my own location on Google Maps").check();
  await page.getByRole("button", {name:"Choose fixture pin",exact:true}).click();
  await page.getByLabel("Selected location name").fill("My chosen court");
  await page.getByRole("button", {name:"Continue →"}).click();
  await page.getByLabel("Host-covered places").fill("1");
  await page.getByRole("button", {name:"Publish event →"}).click();
  await page.getByRole("heading", {name:"Basketball at Central Court",exact:true}).waitFor();
  assert.equal(lastCreatedLocation.name,"My chosen court");
  assert.equal(lastCreatedLocation.latitude,33.89);
  assert.equal(lastCreatedLocation.longitude,35.5);
  assert.deepEqual(errors, []);
  await browser.close();
  console.log(
    "PASS: guest-only navigation, automatic signup with private demographics/1–3 sports, in-app Jounieh search/selected map link, signed-out/in My games and Inbox navigation, post-login destination, keyboard/mobile taps, Back/reload, 17-type catalog, category/open-spot filtering, sports/activity wizard, preferences, host controls, sponsored places, 5% cash fee breakdown, $1 deposit/5% quote and cash-balance option, venue tel link, deposit roster badge and pending reference/history, signed-demo checkout UI, manual Whish reference submission/history, map search links, Lebanese listing filtering/custom pin (Google library fixtures), persisted dark/light themes, reduced motion, waitlist, notifications and mobile layout (API fixtures).",
  );
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
