# Watch Page — Setup Guide

Your stream network lives at **chazdyn.com/stream/**. The directory lists every
approved creator; each one gets a cinematic page at **chazdyn.com/stream/<twitch-name>**.

Open `stream/index.html` and edit the `CONFIG` block at the top of the `<script>`:

```js
const CONFIG = {
  parent: 'chazdyn.com',                 // must match your live domain
  twitchClientId: 'zd09p34hzxm6jbhvhlcujem2ypid0m',
  supabaseUrl: 'https://lqayctcgprumnvlaktms.supabase.co',
  supabaseAnonKey: 'sb_publishable_tcWWDYpGBbVY1XKVNUaiZw_miMfMiFG',
  networkName: 'CHAZDYN',
};
```

The page now reads the `creators` table from Supabase. If Supabase is unreachable
or the schema has not been created yet, it falls back to built-in demo creators so
you can still preview the layout.

`listed = false` hides a creator from the main `/stream/` directory, but their
direct page still works as long as `approved = true` and `page_on = true`.

---

## 1. Twitch embed (the viewer-count part)

The embedded **player** is what counts toward your live viewer number — no login
required from the visitor. Twitch only accepts the embed when the `parent`
parameter matches the domain the page is served from. That's why `CONFIG.parent`
must be `chazdyn.com` in production. (In this preview the player shows a poster
instead, because the preview isn't on chazdyn.com.)

## 2. "Sign in with Twitch" (chat identity)

This is **optional** and only affects chat identity — it does not, and legally
cannot, force-add someone to your viewer list (that would be view-botting and
breaks Twitch ToS). It simply lets a visitor be logged in so the embedded chat
is theirs.

To enable it, create a Twitch application:

1. Go to **dev.twitch.tv/console/apps → Register Your Application**.
2. Name: `Chazdyn Stream Network`. Category: *Website Integration*.
3. **OAuth Redirect URLs** — add exactly:
   - `https://chazdyn.com/stream/`
   - `https://chazdyn.com/stream/index.html`
4. Copy the **Client ID** into `CONFIG.twitchClientId`. (No client secret needed —
   the page uses the implicit/token flow, safe for a public site.)

## 3. Discord creator applications

The "Request your own page" form uses Supabase Discord OAuth and inserts into
`creator_requests`. In Supabase Auth, make sure Discord is enabled and add this
redirect URL:

- `https://chazdyn.com/stream/`

Pending applications appear in **Control.Dyn -> Stream Network -> Applications**.

### Creator ReadMe (hand this to guests)
> Your Watch page already embeds your Twitch player, so anyone watching on
> `chazdyn.com/stream/<you>` counts toward your live viewers automatically.
> The "Sign in with Twitch" button is just so your chatters show up as
> themselves — you don't have to do anything for it to work.

---

See `README_STREAMERBOT.md` for redeems + Streamer.bot.
