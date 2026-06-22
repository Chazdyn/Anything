# Creator Creative Spaces + Cloudflare Tunnel Notes

## Creative spaces

Each creator can have extra page content below the stream/player showcase on `/stream/{slug}`.

In **Control.Dyn → Stream Network → Edit creator → Creative Space**, choose one of three modes:

- **Off**: no lower page content.
- **Prefab page**: title, subtitle, body copy, and a links JSON array.
- **Custom HTML mode**: creator-provided markup inside a sandboxed iframe.

The top stream area remains protected. Even in Custom HTML mode, the creator's HTML is rendered inside its own lower-page iframe, so it cannot rewrite or interfere with the player, chat, redeems, Streamer.bot connection, or network navigation.

Example links JSON:

```json
[
  { "label": "Discord", "url": "https://discord.gg/example" },
  { "label": "TikTok", "url": "https://tiktok.com/@example" }
]
```

## Tunnel helper

Streamer.bot runs locally for each creator. The public website needs a public `wss://` URL that can reach that creator's local Streamer.bot WebSocket server.

The static-safe creator-friendly flow is:

1. In Streamer.bot, enable the WebSocket server on `127.0.0.1:8080`.
2. Install Cloudflare's `cloudflared` tool.
3. Run:

```bash
cloudflared tunnel --url http://127.0.0.1:8080
```

4. Copy the generated `https://....trycloudflare.com` URL.
5. Paste it into Control.Dyn as:

```txt
wss://....trycloudflare.com/
```

## Why Control.Dyn does not auto-create named tunnels yet

Named Cloudflare Tunnels require Cloudflare API credentials and tunnel credentials. This project is a static website, so putting those secrets in browser JavaScript would expose them to anyone who can load the page.

A future fully automated version should use a small backend or Cloudflare Worker:

1. Creator requests tunnel setup from Control.Dyn.
2. Control.Dyn calls the backend.
3. Backend uses the Cloudflare API token privately.
4. Backend creates the tunnel / DNS route.
5. Backend returns only the final public `wss://...` URL.
6. Control.Dyn saves that URL in the creator's `sb_ws_url`.

That gives the nice one-click onboarding experience without leaking Cloudflare credentials.
