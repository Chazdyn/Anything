# Redeems + Streamer.bot — Setup Guide

## What the clickable redeems can (and can't) do

There are two very different things people mean by "redeems". Pick per button:

**A) Web redeems → Streamer.bot actions (recommended, fully in your control)**
A button on the page sends a message to Streamer.bot, which runs any Action you
built (play a sound, change lights, queue a song, fire an OBS source, etc.).
These are **free** by default — *you* decide who can press them and what they
cost in your own system. This is what the page does today.

**B) Mirror real Twitch Channel-Point rewards**
You can *display* your real channel-point rewards on the page, but a website
**cannot spend a viewer's channel points** — only Twitch's own UI does that. So
a web button can't deduct points. If you want true point-spending, keep that in
the Twitch player; use web redeems (A) for everything else.

> Recommendation: use **(A)** for interactive buttons, and optionally show your
> real point rewards as a read-only list so viewers know what exists on Twitch.

Each redeem in the data model is:
```json
{ "icon": "🎵", "label": "Song Request", "cost": 500, "actionName": "Song Request" }
```
`actionName` must match the **Action name** in Streamer.bot exactly.

---

## Making Streamer.bot reachable from the website

Streamer.bot runs on your PC; a public website can't see `localhost`. You expose
its WebSocket server through a tunnel and put that `wss://…` URL in your
creator row's `sb_ws_url` (or `CONFIG`/demo for testing).

1. In Streamer.bot → **Servers/Clients → WebSocket Server**: enable it, note the
   port (default `8080`), and set **Address** to `0.0.0.0`.
2. Tunnel it (pick one):
   - **Cloudflare Tunnel (free, stable):** `cloudflared tunnel --url http://localhost:8080`
     → gives a `https://xxx.trycloudflare.com` host; use `wss://xxx.trycloudflare.com/`.
   - **ngrok:** `ngrok http 8080` → use the `wss://` form of the URL it prints.
3. Put that `wss://…` URL into the creator's `sb_ws_url`.
4. **Security:** turn on **Authentication** in the Streamer.bot WebSocket server
   and only enable the specific Actions you want web-triggerable. Anyone with the
   URL can send those actions, so keep the action list intentional.

The page shows a live **"Streamer.bot: connected / offline"** badge on the
redeems dock so you always know the bridge state.

### Creator ReadMe (hand this to guests)
> 1. Build the Actions you want viewers to trigger in Streamer.bot.
> 2. Enable the WebSocket Server (port 8080) and start a Cloudflare/ngrok tunnel.
> 3. Paste the `wss://…` URL into your Control panel → Redeems → "Streamer.bot URL".
> 4. Add a redeem button for each Action (the label + the exact Action name).
> Keep the tunnel running while you stream; the badge turns green when connected.

---

## Cloudflare Tunnel helper in Control.Dyn

Each creator editor now includes a **Tunnel setup helper** next to `sb_ws_url`.

The website cannot safely create named Cloudflare Tunnels directly because this is a static site and Cloudflare API tokens must stay server-side. The helper gives creators a quick no-secret path using Cloudflare Quick Tunnels:

```bash
cloudflared tunnel --url http://127.0.0.1:8080
```

Then paste the generated URL into `sb_ws_url` as `wss://...trycloudflare.com/`.

A future one-click version should be handled by a backend or Cloudflare Worker that stores Cloudflare credentials privately.
