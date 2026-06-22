# Twitch Setup — Stream Network + Reward Sync

Your stream network lives at **https://chazdyn.com/stream/**.

- **/stream/** lists approved creators from Supabase.
- **/stream/{slug}** opens that creator's Twitch player, chat, and web-redeem buttons.
- Creator rows are managed in **Control.Dyn → Stream Network**.
- Creator rows store Streamer.bot WebSocket URLs in `sb_ws_url` and reward buttons in the `redeems` JSON column.

For Chazdyn's row, set:

```txt
sb_ws_url = wss://streamerbot.chazdyn.com/
```

---

## 1. Twitch app setup

Create one Twitch Developer app:

1. Go to **dev.twitch.tv/console/apps**.
2. Register an application named something like `Chazdyn Stream Network`.
3. Category: **Website Integration**.
4. Add this OAuth Redirect URL exactly:

```txt
https://chazdyn.com/stream/
```

Optional, for older testing links only:

```txt
https://chazdyn.com/stream/index.html
```

5. Copy the **Client ID** into the `CONFIG.twitchClientId` value in `stream/index.html` and into the Twitch Client ID field in Control.Dyn.

Do **not** add a Twitch client secret to the public website. This is a static site, so the reward sync uses a browser OAuth token flow and never needs a server-side secret.

---

## 2. Required scopes

### Public viewer sign-in

The public **Sign in with Twitch** button is only for visitor identity/chat display. It requests:

```txt
user:read:email
```

That scope was already part of the existing viewer login flow.

### Control.Dyn reward syncing

The **Sync Twitch Rewards** button in Control.Dyn requests:

```txt
channel:read:redemptions
```

This lets the signed-in broadcaster read their own Channel Point custom rewards through Twitch Helix.

---

## 3. How reward syncing works

In **Control.Dyn → Stream Network**, each creator card now has a **Sync Twitch Rewards** button.

When clicked:

1. Control.Dyn checks the browser's Twitch token.
2. If Twitch is not signed in, the token is expired, or the token is missing `channel:read:redemptions`, it sends the broadcaster to Twitch OAuth.
3. Twitch redirects back to:

```txt
https://chazdyn.com/stream/
```

4. `/stream/` stores the browser token locally, then returns to:

```txt
https://chazdyn.com/Control.Dyn.html#stream-net
```

5. Control.Dyn resumes the sync automatically.
6. It calls:

```txt
GET https://api.twitch.tv/helix/users
```

That identifies the signed-in broadcaster.

7. It then calls:

```txt
GET https://api.twitch.tv/helix/channel_points/custom_rewards?broadcaster_id={id}
```

8. Fetched rewards are normalized and saved back into the creator row's `redeems` JSON.

Synced Twitch rewards use this shape:

```json
{
  "label": "Hydrate",
  "cost": 250,
  "icon": "⭐",
  "twitchRewardId": "...",
  "actionName": "Hydrate",
  "enabled": true,
  "source": "twitch"
}
```

---

## 4. Mapping Twitch rewards to Streamer.bot actions

After syncing, expand a creator card with **Edit**.

The **Redeem mappings** editor lets you change `actionName` without hand-editing JSON. This is how a Twitch reward named `Hydrate` can trigger a Streamer.bot action named `Hydration Alert`, `Hydrate FX`, or anything else.

When syncing again, Control.Dyn preserves existing mappings by matching:

1. `twitchRewardId`
2. Then reward label/title

Manual redeems are preserved when `source` is missing or `source` is `manual`.

---

## 5. Public /stream/ behavior

The public creator page displays only redeems where:

```json
"enabled": true
```

or where `enabled` is missing. Redeems with `enabled: false` stay saved in Supabase but are hidden from the public page.

When a viewer clicks a redeem button on `/stream/{slug}`, the website sends this to the creator's Streamer.bot WebSocket:

```json
{
  "request": "DoAction",
  "action": { "name": "Hydrate" },
  "args": {
    "user": "viewer name or web",
    "source": "web-redeem",
    "cost": 250
  }
}
```

`action.name` is `redeem.actionName || redeem.label`.

---

## 6. Important Channel Points reminder

Website buttons do **not** spend Twitch Channel Points.

The buttons mirror the broadcaster's Twitch rewards and trigger Streamer.bot actions from the website. They are not real Twitch redemptions, they do not deduct points, and they do not create a redemption record in Twitch.

If you need real Twitch point spending, viewers must redeem directly through Twitch chat or Twitch's Channel Points UI.

---

## 7. Common errors

### Not signed into Twitch

Click **Sync Twitch Rewards** and complete the Twitch OAuth prompt.

### Missing `channel:read:redemptions`

The current browser token was probably created by the public viewer login. Sync again and approve the broadcaster reward scope.

### Token expired / Twitch 401

Control.Dyn clears the old token and asks you to sign in again.

### Twitch 403

The signed-in user either lacks the required scope or cannot read rewards for that broadcaster. Make sure the broadcaster is logged into Twitch and approves `channel:read:redemptions`.

### No rewards found

The broadcaster has no custom Channel Point rewards returned by Helix. Existing website redeems are left unchanged.

---

## 8. Live sorting and viewer counts

Control.Dyn now has a **Directory Ordering** panel in **Stream Network**.

`/stream/` always ranks creators like this:

1. Live creators first.
2. Offline creators after live creators.
3. Offline creators use `display_order`, lowest number first.
4. Live creators use either:
   - `live_priority`, lowest number first, or
   - `viewer_count`, highest number first.

The sort mode is saved in `stream_settings` with key `directory`:

```json
{
  "liveSortMode": "priority"
}
```

or:

```json
{
  "liveSortMode": "viewer_count"
}
```

Because the site is static, it cannot refresh Twitch live status in the background by itself. The **Refresh Twitch Live Data** button in Control.Dyn uses a browser Twitch OAuth token to call:

```txt
GET https://api.twitch.tv/helix/streams?user_login={channel}
```

Then it saves `is_live`, `viewer_count`, `live_started_at`, and `live_checked_at` onto each creator row in Supabase. The public `/stream/` directory sorts using those saved values.

---

## 9. Creator creative spaces

Each creator row now supports a creative space that appears below the stream/player area on `/stream/{slug}`.

Control.Dyn supports:

- `off` — no creative space.
- `prefab` — safe title, subtitle, body, and links fields.
- `custom_html` — custom markup rendered inside a sandboxed iframe.

Custom HTML is intentionally isolated below the stream showcase. It cannot affect the top player/chat/redeems area because it is placed in an iframe with a sandbox and no script permission.

---

## 10. Cloudflare Tunnel automation note

A fully automated “create a personalized Cloudflare Tunnel for this creator” button is not safe to run entirely from a static website. Named tunnel creation requires Cloudflare API tokens and tunnel credentials, and those must never be exposed in Control.Dyn or any public JavaScript.

What this build includes instead:

- A **Tunnel setup helper** inside each creator editor.
- Creator-specific instructions for using `cloudflared tunnel --url http://127.0.0.1:8080`.
- A clear path for a future backend/Cloudflare Worker that can hold the Cloudflare API token securely and return only the public `wss://...` URL to Control.Dyn.

For now, creators can use a quick `trycloudflare.com` tunnel and paste the resulting `wss://...trycloudflare.com/` URL into `sb_ws_url`.
