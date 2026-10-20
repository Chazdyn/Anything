# PickMe — chazdyn.com/pickme

Stream games with Twitch profiles and a shared currency: **Picks**.

| Page | Who | URL |
|---|---|---|
| `index.html` | Viewers: profile, live game, questions, leaderboard | https://chazdyn.com/pickme/ |
| `index.html?u=login` | Anyone's public profile | https://chazdyn.com/pickme/?u=chazdyn |
| `overlay.html` | OBS browser source, 1920×1080 | https://chazdyn.com/pickme/overlay.html |
| `dashboard.html` | You: game, session, players, logs, access | https://chazdyn.com/pickme/dashboard.html |

Overlay options: `?transparent=1`, `?sound=0`, `?volume=0.4`. Tick **Control audio via OBS** on the source.
The old `/chatsays/` links redirect here.

## One-time setup (~10 min)

1. **Supabase SQL Editor** → run `PICKME_SETUP.sql`. (Run `../SUPABASE_SECURITY_FIX.sql` too if you haven't.)
2. **Twitch app** — dev.twitch.tv/console/apps → Register:
   name `Chazdyn PickMe`, category Website Integration, client type Confidential,
   redirect URL `https://lqayctcgprumnvlaktms.supabase.co/auth/v1/callback`. Copy Client ID, click **New Secret**.
3. **Supabase → Authentication → Sign In / Providers → Twitch** → enable, paste ID + secret.
4. **Supabase → Authentication → URL Configuration → Redirect URLs** → add `https://chazdyn.com/pickme/**`
5. Push the repo.

## Stream checklist

1. Open the dashboard (add it as an OBS **Custom Browser Dock**). Sign in with Twitch.
2. **Connect moderation** (Live tab) so `!a` / `!q` chat messages get hidden. Twitch tokens last ~4 hours.
3. **Session tab → Start session.**
4. Pick a mode: **Host vs Chat** (you guess the board) or **Chat vs Chat** (you reveal; players race to match the crowd).
5. Ask a question, or tick **Taking questions** and use one from chat.

## How Picks are earned

- **Host vs Chat:** tiles you guess pay nobody. Every tile you miss (after 3 strikes or End round) pays each viewer who gave that answer, worth the tile's count.
- **Chat vs Chat:** every revealed tile pays each viewer who gave that answer, worth the tile's count.
- **Question used:** the asker gets the reward set in the dashboard (default 5).
- **You:** give or take any amount from Players. Every change is in their history and the Logs tab.

## Players and access

- Viewers get a profile when they sign in with Twitch. People who only answer with `!a` in chat get a profile too; when they later sign in, it becomes theirs, Picks included.
- Late joiners can play any time the session is **Open**. **Closed** = only people who already played this session. **End** = nobody.
- **Whitelist only** sessions let in only whitelisted players. Blocks (everything / Chat Says / this session) always win.

## Adding a game

Add it to `GAMES` in `pickme-core.js`, store rounds with a new `game` key in `pm_rounds`, and pay players with
`pm_admin_award_tile` or `pm_admin_adjust`. Profiles, sessions, access rules and logs already work for any game.

## Co-hosts

```sql
insert into public.pm_hosts (twitch_login) values ('krunch');
```

## Optional art (`pickme/assets/`)

`logo.png` (title), `bg.mp4` (looping background), `strike.png` (strike X), `sfx/ding.mp3 buzz.mp3 tick.mp3 open.mp3 lock.mp3 win.mp3 chat.mp3`.

## If you ran the old Chat Says SQL

Those tables aren't used anymore. Optional cleanup:

```sql
drop table if exists public.chatsays_answers, public.chatsays_rounds, public.chatsays_state, public.chatsays_hosts cascade;
```
