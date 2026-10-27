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

## Auto-survey (questions asked in chat ahead of time)

1. Live game tab → **Connect moderation** (needs to be redone once after this update so it can *post* to chat).
2. **Auto-survey in chat → Running.** Set **Ready after** (5 now, 10 later), **Post every** (minutes between chat posts), **Move on after**.
3. The dashboard posts a bank question to chat. Viewers answer with `!a your answer` (auto-hidden) or on the site.
4. When enough different people answer, it shows in **Ready to play** and the next question goes out.
5. Click **Play** to put it straight on the board (no timer). People who answered earlier get paid when their tile pays out.
6. Surveys pause while a live round is running. The dashboard has to be open (OBS dock) for posting to work.
7. Add questions under **Question bank** (one per line), or click **Survey it** on a viewer-submitted question.
   151 starter questions are loaded by `PICKME_SETUP.sql`.

## How Picks are earned

- **Host vs Chat:** tiles you guess pay nobody. Every tile you miss (after 3 strikes or End round) pays each viewer who gave that answer, worth the tile's count.
- **Chat vs Chat:** every revealed tile pays each viewer who gave that answer, worth the tile's count.
- **Question used:** the asker gets the reward set in the dashboard (default 5).
- **You:** give or take any amount from Players. Every change is in their history and the Logs tab.

## Sending Picks

Players can send Picks to each other from their profile (**Send Picks**) or from anyone's public profile.
They can't send more than they have. Turn it off any time: dashboard → Players → *Players can send Picks to each other*.
Every transfer shows in both players' history and in Logs → Picks sent between players.

## Blocked words

Dashboard → Access → **Blocked words**. Answers, questions and transfer notes containing a blocked word are refused,
from the site and from chat. Default is whole-word (blocking `heck` doesn't block `checker`); tick
*also inside longer words* to catch it anywhere. Rejections show in Logs → Blocked-word rejections.

## Trivia Ladder

Dashboard → **Trivia** tab.
1. Pick category, difficulty, number of questions, seconds per question.
2. Pot: **Prize** (free entry, you set the Picks) or **Buy-in** (players pay to enter, plus an optional bonus). Survivors split it.
3. Optional: paste your own questions (mark the right answer with `*`). They're asked first.
4. **Open lobby** → players join on the site or with `!join` in chat → **Ask question 1**.
5. Players answer A–D on the site or with `!a B` / `!b` in chat. It reveals automatically when time runs out.
   Wrong or no answer = out. If everyone misses, nobody is out (unless you untick that).
6. **Next question** or **Finish & pay**. If nobody survives, buy-ins are refunded. **Cancel** refunds everyone.

Questions come from Open Trivia DB (CC BY-SA 4.0; credited on the overlay). The answer key only lives in your dashboard
browser until each reveal, so nobody can peek. Run the game from one dashboard (your OBS dock).

## The Picks Are Right

Dashboard → **Picks Are Right** tab. Everyone plays a qualifier; the closest to the target **without going over** make the finals.

| Qualifier | How it works | Chat |
|---|---|---|
| Dictation | A passage is read line by line. Type it; land on exactly the target number of correct words (count hidden). | `!t words` (adds to what you've typed) |
| Donations | Everyone gives $500 to someone. Over the target busts, and so does everyone who gave to them. | `!give name` |
| High Rollers | Everyone rolls 3 dice; push your extra die onto someone. Roll over the target and you bust. | `!give name` |
| Math | +/− questions worth $25 each. Stop on the target; one too many busts. Wrong answers stun for 2 s. | site only |

Then pick the main stage (set before you start):
- **Showcase:** type what they're bidding on and the secret value (it stays in your dashboard until the reveal). Finalists bid
  (site or `!bid 1234`), everyone else bets Picks on a finalist (site or `!bet name 50`). Closest bid without going over
  wins the prize (doubled if within your %). Winning bettors split the whole bet pot; no winner = bets refunded.
- **The Wheel:** finalists spin in order (worst qualifier first), up to twice, site or `!spin` / `!stay`.
  Closest to 100 without going over wins; exactly 100 earns your bonus. You can spin/stay for anyone who's away.

**Making the finals pays** gives every finalist a few Picks. Cancel refunds any bets.

## Pick Shop

Viewers spend Picks on cosmetics: **name colors** (solid, fades, animated), **badges**, **avatar frames** and **card themes**.
They show on profiles, the leaderboard (site + overlay) and the overlay's names lists. 31 starter items are loaded by the SQL.
Dashboard → **Shop** tab: change prices, take items off sale, add your own (pick colors, an emoji, or a frame/theme style).
Players tab → **Give a shop item** gifts one for free.

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
