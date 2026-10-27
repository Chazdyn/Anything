-- ════════════════════════════════════════════════════════════
--  PICKME — Supabase setup (chazdyn.com/pickme)
--  Player profiles (Twitch), Picks ledger, sessions, access lists,
--  activity logs, and the Chat Says game. Run once in SQL Editor.
--  Safe to re-run.
--
--  Writes go through security-definer functions (pm_*). Players can
--  only read; they never write tables directly. Identity comes from
--  auth.identities, which users cannot edit.
-- ════════════════════════════════════════════════════════════

-- ── 0. Hosts + identity helpers ─────────────────────────────
create table if not exists public.pm_hosts (twitch_login text primary key);
insert into public.pm_hosts (twitch_login) values ('chazdyn') on conflict do nothing;
alter table public.pm_hosts enable row level security;

create or replace function public.pm_twitch_names(d jsonb)
returns text[] language sql immutable set search_path = '' as $$
  select array_remove(array[
    lower(d->>'name'), lower(d->>'nickname'), lower(d->>'preferred_username'),
    lower(d->>'user_name'), lower(d->>'slug'), lower(d->>'full_name')], null);
$$;

create or replace function public.pm_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from auth.identities i
    where i.user_id = auth.uid()
      and ((i.provider = 'discord' and i.provider_id = '562352729482067968')
        or (i.provider = 'twitch' and exists (
              select 1 from public.pm_hosts h
              where h.twitch_login = any (public.pm_twitch_names(i.identity_data))))));
$$;

create or replace function public.pm_now()
returns timestamptz language sql stable as $$ select now(); $$;

-- ── 1. Tables ───────────────────────────────────────────────
create table if not exists public.pm_profiles (
  id           uuid primary key default gen_random_uuid(),
  twitch_id    text not null unique,
  login        text,
  display_name text,
  avatar_url   text,
  user_id      uuid unique,                 -- null until they sign in on the site (chat-only players)
  balance      int  not null default 0,     -- Picks; maintained from pm_ledger
  source       text not null default 'app', -- where we first saw them: app | chat
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists pm_profiles_balance_idx on public.pm_profiles (balance desc);
create index if not exists pm_profiles_login_idx on public.pm_profiles (login);

create table if not exists public.pm_sessions (
  id         uuid primary key default gen_random_uuid(),
  title      text not null default 'Stream session',
  game       text not null default 'chatsays',
  status     text not null default 'open'     check (status in ('open','closed','ended')),
  access     text not null default 'everyone' check (access in ('everyone','whitelist')),
  created_at timestamptz not null default now(),
  ended_at   timestamptz
);

create table if not exists public.pm_participants (
  session_id uuid not null references public.pm_sessions(id) on delete cascade,
  profile_id uuid not null references public.pm_profiles(id) on delete cascade,
  via        text not null default 'app',
  joined_at  timestamptz not null default now(),
  primary key (session_id, profile_id)
);

-- scope: global (everything) | game (scope_value = game key) | session (scope_value = session id)
create table if not exists public.pm_access (
  id          bigint generated always as identity primary key,
  profile_id  uuid not null references public.pm_profiles(id) on delete cascade,
  scope       text not null check (scope in ('global','game','session')),
  scope_value text not null default '',
  kind        text not null check (kind in ('allow','block')),
  note        text,
  created_at  timestamptz not null default now(),
  unique (profile_id, scope, scope_value, kind)
);

create table if not exists public.pm_questions (
  id           bigint generated always as identity primary key,
  session_id   uuid references public.pm_sessions(id) on delete set null,
  profile_id   uuid not null references public.pm_profiles(id) on delete cascade,
  display_name text,
  text         text not null check (char_length(btrim(text)) between 3 and 200),
  source       text not null default 'app',
  status       text not null default 'new' check (status in ('new','used','dismissed')),
  created_at   timestamptz not null default now()
);

create table if not exists public.pm_rounds (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid references public.pm_sessions(id) on delete set null,
  game        text not null default 'chatsays',
  mode        text not null default 'versus' check (mode in ('versus','crowd')),
  question    text not null check (char_length(btrim(question)) between 1 and 200),
  question_id bigint references public.pm_questions(id) on delete set null,
  seconds     int  not null default 45 check (seconds between 5 and 600),
  status      text not null default 'collecting' check (status in ('collecting','closed','cancelled')),
  opened_at   timestamptz not null default now(),
  closes_at   timestamptz,
  created_at  timestamptz not null default now()
);
-- live = a timed round on stream; survey = an open-ended question asked in chat ahead of time
alter table public.pm_rounds add column if not exists kind text not null default 'live';
do $$ begin
  alter table public.pm_rounds add constraint pm_rounds_kind_chk check (kind in ('live','survey'));
exception when duplicate_object then null; end $$;
create index if not exists pm_rounds_kind_idx on public.pm_rounds (kind, status, created_at desc);

-- Survey questions the dashboard asks in chat automatically
create table if not exists public.pm_bank (
  id            bigint generated always as identity primary key,
  text          text not null unique check (char_length(btrim(text)) between 3 and 200),
  source        text not null default 'bank',
  active        boolean not null default true,
  times_asked   int not null default 0,
  last_asked_at timestamptz,
  created_at    timestamptz not null default now()
);

-- Words that get answers, questions and notes rejected
create table if not exists public.pm_blocklist (
  word       text primary key check (char_length(btrim(word)) between 1 and 60),
  whole_word boolean not null default true,   -- false = also match inside longer words
  created_at timestamptz not null default now()
);

create table if not exists public.pm_answers (
  id           bigint generated always as identity primary key,
  round_id     uuid not null references public.pm_rounds(id) on delete cascade,
  profile_id   uuid not null references public.pm_profiles(id) on delete cascade,
  display_name text,
  avatar_url   text,
  answer       text not null check (char_length(btrim(answer)) between 1 and 60),
  source       text not null default 'app',
  tile_key     text,
  awarded      boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (round_id, profile_id)
);
create index if not exists pm_answers_round_idx on public.pm_answers (round_id, id desc);

create table if not exists public.pm_ledger (
  id         bigint generated always as identity primary key,
  profile_id uuid not null references public.pm_profiles(id) on delete cascade,
  delta      int  not null check (delta <> 0),
  reason     text,
  game       text,
  round_id   uuid references public.pm_rounds(id) on delete set null,
  actor      text not null default 'system',
  created_at timestamptz not null default now()
);
create index if not exists pm_ledger_profile_idx on public.pm_ledger (profile_id, id desc);

create table if not exists public.pm_events (
  id         bigint generated always as identity primary key,
  profile_id uuid references public.pm_profiles(id) on delete cascade,
  session_id uuid references public.pm_sessions(id) on delete set null,
  kind       text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists pm_events_profile_idx on public.pm_events (profile_id, id desc);
create index if not exists pm_events_id_idx on public.pm_events (id desc);

create table if not exists public.pm_state (
  key        text primary key,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.pm_state (key, data)
values ('live', '{"phase":"idle","mode":"versus","scene":"game","roundNo":0,"scores":{"host":0,"chat":0},"board":[],"strikes":0}'::jsonb)
on conflict (key) do nothing;

-- ── 2. Triggers ─────────────────────────────────────────────
create or replace function public.pm_ledger_apply()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.pm_profiles set balance = balance + new.delta where id = new.profile_id;
  return new;
end $$;
drop trigger if exists pm_ledger_apply on public.pm_ledger;
create trigger pm_ledger_apply after insert on public.pm_ledger
  for each row execute function public.pm_ledger_apply();

create or replace function public.pm_rounds_before()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'collecting';
    new.opened_at := now();
    -- surveys stay open until the host plays or discards them
    new.closes_at := case when new.kind = 'survey' then null else now() + make_interval(secs => new.seconds) end;
  elsif old.status = 'collecting' and new.status <> 'collecting' then
    new.closes_at := least(coalesce(old.closes_at, now()), now());
  end if;
  return new;
end $$;
drop trigger if exists pm_rounds_before on public.pm_rounds;
create trigger pm_rounds_before before insert or update on public.pm_rounds
  for each row execute function public.pm_rounds_before();

create or replace function public.pm_sessions_before()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'ended' and (tg_op = 'INSERT' or old.status <> 'ended') then new.ended_at := now(); end if;
  return new;
end $$;
drop trigger if exists pm_sessions_before on public.pm_sessions;
create trigger pm_sessions_before before insert or update on public.pm_sessions
  for each row execute function public.pm_sessions_before();

create or replace function public.pm_access_log()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r public.pm_access := coalesce(new, old);
begin
  if exists (select 1 from public.pm_profiles where id = r.profile_id) then
    insert into public.pm_events (profile_id, kind, detail)
    values (r.profile_id, case when tg_op = 'INSERT' then 'access_added' else 'access_removed' end,
            jsonb_build_object('scope', r.scope, 'scope_value', r.scope_value, 'kind', r.kind));
  end if;
  return null;
end $$;
drop trigger if exists pm_access_log on public.pm_access;
create trigger pm_access_log after insert or delete on public.pm_access
  for each row execute function public.pm_access_log();

-- ── 3. Internal helpers (not callable by players) ───────────
create or replace function public.pm_log(p_profile uuid, p_kind text, p_detail jsonb, p_session uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.pm_events (profile_id, kind, detail, session_id)
  values (p_profile, p_kind, coalesce(p_detail, '{}'::jsonb), p_session);
$$;

create or replace function public.pm_my_profile()
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.pm_profiles where user_id = auth.uid();
$$;

create or replace function public.pm_filtered(p_text text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.pm_blocklist b
    where case when b.whole_word
      then lower(coalesce(p_text, '')) ~ ('(^|[^[:alnum:]])'
             || regexp_replace(lower(btrim(b.word)), '([][(){}.*+?^$|\\-])', '\\\1', 'g')
             || '($|[^[:alnum:]])')
      else position(lower(btrim(b.word)) in lower(coalesce(p_text, ''))) > 0 end);
$$;

-- null = may play; otherwise a reason code
-- p_game: which game is being played (access rules are per game); defaults to the session's game
drop function if exists public.pm_check(uuid, uuid);
drop function if exists public.pm_enter(uuid, uuid, text);
create or replace function public.pm_check(p_profile uuid, p_session uuid, p_game text default null)
returns text language plpgsql stable security definer set search_path = '' as $$
declare s public.pm_sessions; g text;
begin
  if exists (select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'block' and a.scope = 'global') then
    return 'blocked';
  end if;
  if p_game is not null and exists (select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'block'
                                     and a.scope = 'game' and a.scope_value = p_game) then
    return 'blocked';
  end if;
  if p_session is null then return null; end if;
  select * into s from public.pm_sessions where id = p_session;
  if not found then return 'no_session'; end if;
  if s.status = 'ended' then return 'ended'; end if;
  g := coalesce(p_game, s.game);
  if exists (select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'block'
             and ((a.scope = 'game' and a.scope_value = g) or (a.scope = 'session' and a.scope_value = s.id::text))) then
    return 'blocked';
  end if;
  if s.access = 'whitelist' and not exists (
       select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'allow'
       and (a.scope = 'global' or (a.scope = 'game' and a.scope_value = g) or (a.scope = 'session' and a.scope_value = s.id::text))) then
    return 'not_whitelisted';
  end if;
  if s.status = 'closed' and not exists (
       select 1 from public.pm_participants p where p.session_id = s.id and p.profile_id = p_profile) then
    return 'closed';
  end if;
  return null;
end $$;

create or replace function public.pm_enter(p_profile uuid, p_session uuid, p_via text, p_game text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare r text; n int;
begin
  r := public.pm_check(p_profile, p_session, p_game);
  if r is not null then return r; end if;
  if p_session is not null then
    insert into public.pm_participants (session_id, profile_id, via) values (p_session, p_profile, p_via)
      on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then perform public.pm_log(p_profile, 'joined', jsonb_build_object('via', p_via), p_session); end if;
  end if;
  return null;
end $$;

create or replace function public.pm_answer_as(p_profile uuid, p_round uuid, p_answer text, p_source text)
returns text language plpgsql security definer set search_path = '' as $$
declare rd public.pm_rounds; pr public.pm_profiles; r text; ans text := left(btrim(coalesce(p_answer, '')), 60);
begin
  select * into rd from public.pm_rounds where id = p_round;
  if not found or rd.status <> 'collecting'
     or (rd.closes_at is not null and now() > rd.closes_at + interval '2 seconds') then return 'round_closed'; end if;
  if ans = '' then return 'empty'; end if;
  if public.pm_filtered(ans) then
    perform public.pm_log(p_profile, 'answer_rejected', jsonb_build_object('reason', 'filtered', 'source', p_source, 'round', p_round, 'answer', ans), rd.session_id);
    return 'filtered';
  end if;
  if rd.session_id is null and exists (select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'block'
                                        and a.scope = 'game' and a.scope_value = rd.game) then
    perform public.pm_log(p_profile, 'answer_rejected', jsonb_build_object('reason', 'blocked', 'source', p_source, 'round', p_round), null);
    return 'blocked';
  end if;
  r := public.pm_enter(p_profile, rd.session_id, p_source, rd.game);
  if r is not null then
    perform public.pm_log(p_profile, 'answer_rejected', jsonb_build_object('reason', r, 'source', p_source, 'round', p_round), rd.session_id);
    return r;
  end if;
  select * into pr from public.pm_profiles where id = p_profile;
  insert into public.pm_answers (round_id, profile_id, display_name, avatar_url, answer, source)
  values (p_round, p_profile, coalesce(pr.display_name, pr.login, 'viewer'), pr.avatar_url, ans, p_source)
  on conflict (round_id, profile_id) do nothing;
  if not found then return 'already'; end if;
  perform public.pm_log(p_profile, 'answered',
    jsonb_build_object('round', p_round, 'question', rd.question, 'answer', ans, 'source', p_source), rd.session_id);
  return 'ok';
end $$;

create or replace function public.pm_question_as(p_profile uuid, p_text text, p_source text)
returns text language plpgsql security definer set search_path = '' as $$
declare st jsonb; sid uuid; r text; t text := left(btrim(coalesce(p_text, '')), 200); pr public.pm_profiles;
begin
  select data into st from public.pm_state where key = 'live';
  if coalesce(st->>'questionCall', 'false') <> 'true' then return 'questions_closed'; end if;
  if char_length(t) < 3 then return 'too_short'; end if;
  if public.pm_filtered(t) then
    perform public.pm_log(p_profile, 'question_rejected', jsonb_build_object('reason', 'filtered', 'text', t, 'source', p_source), null);
    return 'filtered';
  end if;
  sid := nullif(st->>'sessionId', '')::uuid;
  r := public.pm_enter(p_profile, sid, p_source);
  if r is not null then return r; end if;
  if (select count(*) from public.pm_questions q where q.profile_id = p_profile and q.status = 'new') >= 3 then
    return 'limit';
  end if;
  select * into pr from public.pm_profiles where id = p_profile;
  insert into public.pm_questions (session_id, profile_id, display_name, text, source)
  values (sid, p_profile, coalesce(pr.display_name, pr.login), t, p_source);
  perform public.pm_log(p_profile, 'question', jsonb_build_object('text', t, 'source', p_source), sid);
  return 'ok';
end $$;

-- ── 4. Player functions ─────────────────────────────────────
-- Creates the caller's profile from their Twitch sign-in, or claims the
-- chat-only profile with the same Twitch ID.
create or replace function public.pm_ensure_profile()
returns public.pm_profiles language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); tid text; d jsonb; lg text; dn text; av text; p public.pm_profiles;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select i.provider_id, i.identity_data into tid, d from auth.identities i
   where i.user_id = uid and i.provider = 'twitch' order by i.created_at limit 1;
  if tid is null then return null; end if;
  lg := lower(coalesce(d->>'name', d->>'preferred_username', d->>'user_name', d->>'slug', d->>'nickname'));
  dn := coalesce(d->>'nickname', d->>'slug', d->>'full_name', d->>'name', lg);
  av := coalesce(d->>'avatar_url', d->>'picture');
  select * into p from public.pm_profiles where twitch_id = tid;
  if not found then
    insert into public.pm_profiles (twitch_id, login, display_name, avatar_url, user_id, source)
    values (tid, lg, dn, av, uid, 'app') returning * into p;
    perform public.pm_log(p.id, 'profile_created', jsonb_build_object('via', 'app'), null);
  else
    if p.user_id is null then perform public.pm_log(p.id, 'profile_claimed', '{}'::jsonb, null); end if;
    update public.pm_profiles
       set user_id = uid, login = coalesce(lg, login), display_name = coalesce(dn, display_name),
           avatar_url = coalesce(av, avatar_url), last_seen_at = now()
     where id = p.id returning * into p;
  end if;
  return p;
end $$;

create or replace function public.pm_join(p_session uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return coalesce(public.pm_enter(pid, p_session, 'app'), 'ok');
end $$;

create or replace function public.pm_submit_answer(p_round uuid, p_answer text)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_answer_as(pid, p_round, p_answer, 'app');
end $$;

create or replace function public.pm_submit_question(p_text text)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_question_as(pid, p_text, 'app');
end $$;

-- Send Picks to another player. Atomic; you can't send more than you have.
create or replace function public.pm_send_picks(p_to uuid, p_amount int, p_note text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := public.pm_my_profile();
  st jsonb; bal int; note text := nullif(left(btrim(coalesce(p_note, '')), 80), '');
  from_name text; to_name text;
begin
  if me is null then return 'no_profile'; end if;
  if p_to is null or p_to = me then return 'self'; end if;
  if coalesce(p_amount, 0) < 1 or p_amount > 1000000 then return 'bad_amount'; end if;
  select data into st from public.pm_state where key = 'live';
  if coalesce(st->>'transfersOff', 'false') = 'true' then return 'transfers_off'; end if;
  if exists (select 1 from public.pm_access a where a.profile_id = me and a.kind = 'block' and a.scope = 'global') then return 'blocked'; end if;
  if note is not null and public.pm_filtered(note) then return 'filtered'; end if;
  -- lock both rows in a fixed order so two people sending to each other can't deadlock
  perform 1 from public.pm_profiles where id in (me, p_to) order by id for update;
  select coalesce(display_name, login) into to_name from public.pm_profiles where id = p_to;
  if not found then return 'no_player'; end if;
  select balance, coalesce(display_name, login) into bal, from_name from public.pm_profiles where id = me;
  if bal < p_amount then return 'not_enough'; end if;
  insert into public.pm_ledger (profile_id, delta, reason, actor)
  values (me, -p_amount, 'Sent to ' || to_name || coalesce(': ' || note, ''), 'transfer'),
         (p_to, p_amount, 'From ' || from_name || coalesce(': ' || note, ''), 'transfer');
  perform public.pm_log(me, 'sent', jsonb_build_object('to', to_name, 'amount', p_amount, 'note', note), null);
  perform public.pm_log(p_to, 'received', jsonb_build_object('from', from_name, 'amount', p_amount, 'note', note), null);
  return 'ok';
end $$;

-- ── 5. Host / admin functions ───────────────────────────────
create or replace function public.pm_require_admin()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.pm_is_admin() then raise exception 'host only' using errcode = '42501'; end if;
end $$;

-- Profile for someone who only plays from Twitch chat (claimed later if they sign in).
create or replace function public.pm_admin_chatter(p_twitch_id text, p_login text, p_display text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare pid uuid;
begin
  perform public.pm_require_admin();
  if coalesce(p_twitch_id, '') = '' then raise exception 'twitch id required'; end if;
  select id into pid from public.pm_profiles where twitch_id = p_twitch_id;
  if pid is null then
    insert into public.pm_profiles (twitch_id, login, display_name, source)
    values (p_twitch_id, lower(p_login), coalesce(nullif(p_display, ''), p_login), 'chat') returning id into pid;
    perform public.pm_log(pid, 'profile_created', jsonb_build_object('via', 'chat'), null);
  else
    update public.pm_profiles set login = coalesce(lower(nullif(p_login, '')), login),
           display_name = coalesce(nullif(p_display, ''), display_name), last_seen_at = now()
     where id = pid;
  end if;
  return pid;
end $$;

create or replace function public.pm_admin_chat_answer(p_round uuid, p_twitch_id text, p_login text, p_display text, p_answer text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  return public.pm_answer_as(public.pm_admin_chatter(p_twitch_id, p_login, p_display), p_round, p_answer, 'chat');
end $$;

create or replace function public.pm_admin_chat_question(p_twitch_id text, p_login text, p_display text, p_text text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  return public.pm_question_as(public.pm_admin_chatter(p_twitch_id, p_login, p_display), p_text, 'chat');
end $$;

-- Give (positive) or take (negative) Picks. Returns the new balance.
create or replace function public.pm_admin_adjust(p_profile uuid, p_delta int, p_reason text)
returns int language plpgsql security definer set search_path = '' as $$
declare b int;
begin
  perform public.pm_require_admin();
  if coalesce(p_delta, 0) = 0 then raise exception 'amount must not be 0'; end if;
  insert into public.pm_ledger (profile_id, delta, reason, actor) values (p_profile, p_delta, nullif(btrim(p_reason), ''), 'admin');
  perform public.pm_log(p_profile, 'adjusted', jsonb_build_object('delta', p_delta, 'reason', p_reason), null);
  select balance into b from public.pm_profiles where id = p_profile;
  return b;
end $$;

-- Which board tile each answer counts toward: [{"id":123,"key":"pizza"}, ...]
create or replace function public.pm_admin_tag_answers(p_round uuid, p_tags jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform public.pm_require_admin();
  update public.pm_answers a set tile_key = t.key
    from jsonb_to_recordset(p_tags) as t(id bigint, key text)
   where a.id = t.id and a.round_id = p_round and not a.awarded;
  get diagnostics n = row_count;
  return n;
end $$;

-- Pay every player whose answer is on a tile. Each answer is paid once.
create or replace function public.pm_admin_award_tile(p_round uuid, p_tile_key text, p_amount int, p_reason text)
returns int language plpgsql security definer set search_path = '' as $$
declare a record; n int := 0; g text;
begin
  perform public.pm_require_admin();
  if coalesce(p_amount, 0) <= 0 then return 0; end if;
  select game into g from public.pm_rounds where id = p_round;
  for a in select id, profile_id from public.pm_answers
            where round_id = p_round and tile_key = p_tile_key and not awarded for update loop
    insert into public.pm_ledger (profile_id, delta, reason, game, round_id) values (a.profile_id, p_amount, p_reason, g, p_round);
    update public.pm_answers set awarded = true where id = a.id;
    n := n + 1;
  end loop;
  return n;
end $$;


-- ════════════════════════════════════════════════════════════
--  TRIVIA LADDER — multiple choice, wrong answer = out, survivors split the pot
-- ════════════════════════════════════════════════════════════
create table if not exists public.pm_trivia_games (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid references public.pm_sessions(id) on delete set null,
  status     text not null default 'lobby' check (status in ('lobby','playing','done','cancelled')),
  buy_in     int  not null default 0 check (buy_in between 0 and 100000),
  prize      int  not null default 0 check (prize between 0 and 1000000),   -- added by the host on top of buy-ins
  total_q    int  not null default 10 check (total_q between 1 and 50),
  current_q  int  not null default 0,
  revive     boolean not null default true,   -- if everyone misses a question, nobody is knocked out
  category   text,
  created_at timestamptz not null default now(),
  ended_at   timestamptz
);
create table if not exists public.pm_trivia_entries (
  game_id      uuid not null references public.pm_trivia_games(id) on delete cascade,
  profile_id   uuid not null references public.pm_profiles(id) on delete cascade,
  display_name text,
  avatar_url   text,
  via          text not null default 'app',
  paid         int  not null default 0,
  alive        boolean not null default true,
  out_at       int,
  payout       int  not null default 0,
  joined_at    timestamptz not null default now(),
  primary key (game_id, profile_id)
);
create table if not exists public.pm_trivia_questions (
  game_id   uuid not null references public.pm_trivia_games(id) on delete cascade,
  qno       int  not null,
  question  text not null,
  choices   jsonb not null,
  correct   int check (correct between 0 and 3),   -- null until revealed, so nobody can peek
  seconds   int  not null default 20 check (seconds between 5 and 120),
  opens_at  timestamptz not null default now(),
  closes_at timestamptz not null,
  status    text not null default 'open' check (status in ('open','revealed')),
  primary key (game_id, qno)
);
create table if not exists public.pm_trivia_answers (
  game_id    uuid not null,
  qno        int  not null,
  profile_id uuid not null references public.pm_profiles(id) on delete cascade,
  choice     int  not null check (choice between 0 and 3),
  created_at timestamptz not null default now(),
  primary key (game_id, qno, profile_id),
  foreign key (game_id, qno) references public.pm_trivia_questions(game_id, qno) on delete cascade
);

create or replace function public.pm_trivia_enter(p_profile uuid, p_game uuid, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare g public.pm_trivia_games; pr public.pm_profiles; r text;
begin
  select * into g from public.pm_trivia_games where id = p_game;
  if not found or g.status in ('done','cancelled') then return 'trivia_closed'; end if;
  if g.status <> 'lobby' then return 'trivia_started'; end if;
  if exists (select 1 from public.pm_trivia_entries e where e.game_id = p_game and e.profile_id = p_profile) then return 'already'; end if;
  r := public.pm_enter(p_profile, g.session_id, p_via, 'trivia');
  if r is not null then return r; end if;
  select * into pr from public.pm_profiles where id = p_profile for update;
  if g.buy_in > 0 then
    if pr.balance < g.buy_in then return 'not_enough'; end if;
    insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (p_profile, -g.buy_in, 'Trivia Ladder buy-in', 'trivia', 'trivia');
  end if;
  insert into public.pm_trivia_entries (game_id, profile_id, display_name, avatar_url, via, paid)
  values (p_game, p_profile, coalesce(pr.display_name, pr.login), pr.avatar_url, p_via, g.buy_in)
  on conflict do nothing;
  perform public.pm_log(p_profile, 'trivia_joined', jsonb_build_object('buy_in', g.buy_in, 'via', p_via), g.session_id);
  return 'ok';
end $$;

create or replace function public.pm_trivia_answer_as(p_profile uuid, p_game uuid, p_qno int, p_choice int)
returns text language plpgsql security definer set search_path = '' as $$
declare q public.pm_trivia_questions; e public.pm_trivia_entries;
begin
  select * into q from public.pm_trivia_questions where game_id = p_game and qno = p_qno;
  if not found or q.status <> 'open' or now() > q.closes_at + interval '2 seconds' then return 'round_closed'; end if;
  select * into e from public.pm_trivia_entries where game_id = p_game and profile_id = p_profile;
  if not found then return 'not_in_game'; end if;
  if not e.alive then return 'out'; end if;
  if p_choice is null or p_choice < 0 or p_choice >= jsonb_array_length(q.choices) then return 'bad_choice'; end if;
  insert into public.pm_trivia_answers (game_id, qno, profile_id, choice) values (p_game, p_qno, p_profile, p_choice)
  on conflict do nothing;
  if not found then return 'already'; end if;
  return 'ok';
end $$;

-- players
create or replace function public.pm_trivia_join(p_game uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_trivia_enter(pid, p_game, 'app');
end $$;
create or replace function public.pm_trivia_answer(p_game uuid, p_qno int, p_choice int)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_trivia_answer_as(pid, p_game, p_qno, p_choice);
end $$;
-- counts only (anyone): how many alive players have answered the current question
create or replace function public.pm_trivia_progress(p_game uuid, p_qno int)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'entrants', (select count(*) from public.pm_trivia_entries where game_id = p_game),
    'alive',    (select count(*) from public.pm_trivia_entries where game_id = p_game and alive),
    'answered', (select count(*) from public.pm_trivia_answers where game_id = p_game and qno = p_qno));
$$;

-- host
create or replace function public.pm_admin_trivia_create(p_session uuid, p_buy_in int, p_prize int, p_total int, p_revive boolean, p_category text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  perform public.pm_require_admin();
  insert into public.pm_trivia_games (session_id, buy_in, prize, total_q, revive, category)
  values (p_session, greatest(coalesce(p_buy_in, 0), 0), greatest(coalesce(p_prize, 0), 0), coalesce(p_total, 10), coalesce(p_revive, true), p_category)
  returning id into gid;
  return gid;
end $$;

create or replace function public.pm_admin_trivia_chat_join(p_game uuid, p_twitch_id text, p_login text, p_display text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  return public.pm_trivia_enter(public.pm_admin_chatter(p_twitch_id, p_login, p_display), p_game, 'chat');
end $$;

create or replace function public.pm_admin_trivia_chat_answer(p_game uuid, p_qno int, p_twitch_id text, p_choice int)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid;
begin
  perform public.pm_require_admin();
  select id into pid from public.pm_profiles where twitch_id = p_twitch_id;
  if pid is null then return 'not_in_game'; end if;
  return public.pm_trivia_answer_as(pid, p_game, p_qno, p_choice);
end $$;

-- Show a question. Re-asking the same number replaces it (skip) as long as it wasn't revealed.
create or replace function public.pm_admin_trivia_ask(p_game uuid, p_qno int, p_question text, p_choices jsonb, p_seconds int)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare g public.pm_trivia_games; closes timestamptz;
begin
  perform public.pm_require_admin();
  select * into g from public.pm_trivia_games where id = p_game for update;
  if not found or g.status not in ('lobby','playing') then raise exception 'game is not running'; end if;
  if jsonb_typeof(p_choices) <> 'array' or jsonb_array_length(p_choices) not between 2 and 4 then raise exception 'need 2 to 4 choices'; end if;
  if exists (select 1 from public.pm_trivia_questions where game_id = p_game and qno = p_qno and status = 'revealed') then
    raise exception 'question % was already revealed', p_qno;
  end if;
  closes := now() + make_interval(secs => coalesce(p_seconds, 20));
  delete from public.pm_trivia_questions where game_id = p_game and qno = p_qno;
  insert into public.pm_trivia_questions (game_id, qno, question, choices, seconds, opens_at, closes_at)
  values (p_game, p_qno, left(p_question, 300), p_choices, coalesce(p_seconds, 20), now(), closes);
  update public.pm_trivia_games set status = 'playing', current_q = p_qno where id = p_game;
  return closes;
end $$;

create or replace function public.pm_admin_trivia_close(p_game uuid, p_qno int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.pm_require_admin();
  update public.pm_trivia_questions set closes_at = least(closes_at, now()) where game_id = p_game and qno = p_qno;
end $$;

-- Reveal: record the correct choice and knock out everyone alive who didn't pick it.
create or replace function public.pm_admin_trivia_reveal(p_game uuid, p_qno int, p_correct int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.pm_trivia_games; q public.pm_trivia_questions; alive_before int; right_n int; out_n int := 0; revived boolean := false; dist jsonb;
begin
  perform public.pm_require_admin();
  select * into g from public.pm_trivia_games where id = p_game for update;
  select * into q from public.pm_trivia_questions where game_id = p_game and qno = p_qno for update;
  if not found then raise exception 'no such question'; end if;
  if q.status = 'revealed' then raise exception 'already revealed'; end if;
  update public.pm_trivia_questions set correct = p_correct, status = 'revealed', closes_at = least(closes_at, now())
   where game_id = p_game and qno = p_qno;
  select count(*) into alive_before from public.pm_trivia_entries where game_id = p_game and alive;
  select count(*) into right_n from public.pm_trivia_entries e
   where e.game_id = p_game and e.alive
     and exists (select 1 from public.pm_trivia_answers a where a.game_id = p_game and a.qno = p_qno and a.profile_id = e.profile_id and a.choice = p_correct);
  if right_n = 0 and g.revive and alive_before > 0 then
    revived := true;
  else
    update public.pm_trivia_entries e set alive = false, out_at = p_qno
     where e.game_id = p_game and e.alive
       and not exists (select 1 from public.pm_trivia_answers a where a.game_id = p_game and a.qno = p_qno and a.profile_id = e.profile_id and a.choice = p_correct);
    get diagnostics out_n = row_count;
  end if;
  select jsonb_agg(coalesce(c.n, 0) order by i) into dist
    from generate_series(0, jsonb_array_length(q.choices) - 1) i
    left join (select choice, count(*) n from public.pm_trivia_answers where game_id = p_game and qno = p_qno group by choice) c on c.choice = i;
  return jsonb_build_object('correct', p_correct, 'dist', dist, 'alive_before', alive_before,
    'right', right_n, 'out', out_n, 'alive', alive_before - out_n, 'revived', revived);
end $$;

-- End the game: survivors split buy-ins + prize. Nobody left = buy-ins refunded.
create or replace function public.pm_admin_trivia_finish(p_game uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.pm_trivia_games; pot int; n int; each int; rem int; i int := 0; amt int; e record;
begin
  perform public.pm_require_admin();
  select * into g from public.pm_trivia_games where id = p_game for update;
  if not found or g.status not in ('lobby','playing') then raise exception 'game is not running'; end if;
  select coalesce(sum(paid), 0) + g.prize into pot from public.pm_trivia_entries where game_id = p_game;
  select count(*) into n from public.pm_trivia_entries where game_id = p_game and alive;
  update public.pm_trivia_games set status = 'done', ended_at = now() where id = p_game;
  if n = 0 then
    for e in select * from public.pm_trivia_entries where game_id = p_game and paid > 0 loop
      insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (e.profile_id, e.paid, 'Trivia Ladder refund (nobody survived)', 'trivia', 'trivia');
    end loop;
    return jsonb_build_object('winners', 0, 'pot', pot, 'refunded', true);
  end if;
  each := pot / n; rem := pot % n;
  for e in select * from public.pm_trivia_entries where game_id = p_game and alive order by joined_at loop
    amt := each + case when i < rem then 1 else 0 end;
    i := i + 1;
    if amt > 0 then
      insert into public.pm_ledger (profile_id, delta, reason, game, actor)
      values (e.profile_id, amt, 'Trivia Ladder: survived ' || g.current_q || ' question' || case when g.current_q = 1 then '' else 's' end, 'trivia', 'trivia');
    end if;
    update public.pm_trivia_entries set payout = amt where game_id = p_game and profile_id = e.profile_id;
    perform public.pm_log(e.profile_id, 'trivia_won', jsonb_build_object('payout', amt, 'survivors', n, 'questions', g.current_q), g.session_id);
  end loop;
  return jsonb_build_object('winners', n, 'pot', pot, 'each', each);
end $$;

create or replace function public.pm_admin_trivia_cancel(p_game uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare g public.pm_trivia_games; e record; n int := 0;
begin
  perform public.pm_require_admin();
  select * into g from public.pm_trivia_games where id = p_game for update;
  if not found or g.status not in ('lobby','playing') then return 0; end if;
  update public.pm_trivia_games set status = 'cancelled', ended_at = now() where id = p_game;
  for e in select * from public.pm_trivia_entries where game_id = p_game and paid > 0 loop
    insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (e.profile_id, e.paid, 'Trivia Ladder refund (cancelled)', 'trivia', 'trivia');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ════════════════════════════════════════════════════════════
--  PICK SHOP — cosmetics bought with Picks
-- ════════════════════════════════════════════════════════════
alter table public.pm_profiles add column if not exists cosmetics jsonb not null default '{}'::jsonb;

create table if not exists public.pm_shop_items (
  id         text primary key check (id ~ '^[a-z0-9_-]{2,40}$'),
  kind       text not null check (kind in ('namecolor','badge','frame','theme')),
  name       text not null check (char_length(btrim(name)) between 1 and 40),
  price      int  not null default 50 check (price between 0 and 1000000),
  data       jsonb not null default '{}'::jsonb,
  active     boolean not null default true,
  sort       int not null default 100,
  created_at timestamptz not null default now()
);
create table if not exists public.pm_inventory (
  profile_id uuid not null references public.pm_profiles(id) on delete cascade,
  item_id    text not null references public.pm_shop_items(id) on delete cascade,
  price      int  not null default 0,
  bought_at  timestamptz not null default now(),
  primary key (profile_id, item_id)
);

create or replace function public.pm_shop_buy(p_item text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := public.pm_my_profile(); it public.pm_shop_items; bal int;
begin
  if me is null then return 'no_profile'; end if;
  select * into it from public.pm_shop_items where id = p_item and active;
  if not found then return 'no_item'; end if;
  if exists (select 1 from public.pm_inventory where profile_id = me and item_id = p_item) then return 'owned'; end if;
  select balance into bal from public.pm_profiles where id = me for update;
  if bal < it.price then return 'not_enough'; end if;
  if it.price > 0 then
    insert into public.pm_ledger (profile_id, delta, reason, actor) values (me, -it.price, 'Pick Shop: ' || it.name, 'shop');
  end if;
  insert into public.pm_inventory (profile_id, item_id, price) values (me, p_item, it.price);
  update public.pm_profiles set cosmetics = cosmetics || jsonb_build_object(it.kind, it.id) where id = me;
  perform public.pm_log(me, 'bought', jsonb_build_object('item', it.id, 'name', it.name, 'price', it.price), null);
  return 'ok';
end $$;

-- p_item null = take that slot off
create or replace function public.pm_shop_equip(p_kind text, p_item text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := public.pm_my_profile(); k text;
begin
  if me is null then return 'no_profile'; end if;
  if p_kind not in ('namecolor','badge','frame','theme') then return 'bad_kind'; end if;
  if p_item is null then
    update public.pm_profiles set cosmetics = cosmetics - p_kind where id = me;
    return 'ok';
  end if;
  select i.kind into k from public.pm_inventory v join public.pm_shop_items i on i.id = v.item_id
   where v.profile_id = me and v.item_id = p_item;
  if k is null then return 'not_owned'; end if;
  if k <> p_kind then return 'bad_kind'; end if;
  update public.pm_profiles set cosmetics = cosmetics || jsonb_build_object(p_kind, p_item) where id = me;
  return 'ok';
end $$;

create or replace function public.pm_admin_give_item(p_profile uuid, p_item text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  perform public.pm_require_admin();
  if not exists (select 1 from public.pm_shop_items where id = p_item) then return 'no_item'; end if;
  insert into public.pm_inventory (profile_id, item_id, price) values (p_profile, p_item, 0) on conflict do nothing;
  if not found then return 'owned'; end if;
  perform public.pm_log(p_profile, 'item_gift', jsonb_build_object('item', p_item), null);
  return 'ok';
end $$;


-- ════════════════════════════════════════════════════════════
--  THE PICKS ARE RIGHT — closest without going over
--  Qualifier (everyone): dictation | donations | highrollers | math
--  Main stage (finalists): showcase (bids + chat bets) | wheel (two spins, 100 max)
-- ════════════════════════════════════════════════════════════
create table if not exists public.pm_pir_shows (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid references public.pm_sessions(id) on delete set null,
  qual         text not null check (qual in ('dictation','donations','highrollers','math','none')),
  stage        text not null check (stage in ('showcase','wheel','plinko','cliff','wof','jeopardy')),
  target       int  not null check (target between 1 and 1000000),
  finalists_n  int  not null default 3 check (finalists_n between 0 and 500),
  prize        int  not null default 50 check (prize between 0 and 1000000),
  qual_reward  int  not null default 0 check (qual_reward between 0 and 100000),
  per_gift     int  not null default 500,
  passage      text,
  phase        text not null default 'qualifier' check (phase in ('qualifier','closed','results','stage','locked','done','cancelled')),
  closes_at    timestamptz,
  wheel_turn   int  not null default 0,
  item         text,
  secret       int,            -- showcase value, only stored at reveal
  created_at   timestamptz not null default now(),
  ended_at     timestamptz
);
-- v5: lobby mode (qual 'none' = everyone who joins plays), more finals games, public game board
alter table public.pm_pir_shows add column if not exists opts  jsonb not null default '{}'::jsonb;
alter table public.pm_pir_shows add column if not exists board jsonb not null default '{}'::jsonb;
alter table public.pm_pir_shows drop constraint if exists pm_pir_shows_qual_check;
alter table public.pm_pir_shows add constraint pm_pir_shows_qual_check check (qual in ('dictation','donations','highrollers','math','none'));
alter table public.pm_pir_shows drop constraint if exists pm_pir_shows_stage_check;
alter table public.pm_pir_shows add constraint pm_pir_shows_stage_check check (stage in ('showcase','wheel','plinko','cliff','wof','jeopardy'));
alter table public.pm_pir_shows drop constraint if exists pm_pir_shows_finalists_n_check;
alter table public.pm_pir_shows add constraint pm_pir_shows_finalists_n_check check (finalists_n between 0 and 500);
create table if not exists public.pm_pir_players (
  show_id       uuid not null references public.pm_pir_shows(id) on delete cascade,
  profile_id    uuid not null references public.pm_profiles(id) on delete cascade,
  display_name  text,
  avatar_url    text,
  via           text not null default 'app',
  score         int,
  busted        boolean not null default false,
  bust_reason   text,
  locked        boolean not null default false,
  typed         text,
  rolls         int[],
  math_idx      int not null default 0,
  stunned_until timestamptz,
  qualified     boolean not null default false,
  rank          int,
  spins         int[] not null default '{}',
  wheel_done    boolean not null default false,
  payout        int not null default 0,
  acted_at      timestamptz,
  joined_at     timestamptz not null default now(),
  primary key (show_id, profile_id)
);
alter table public.pm_pir_players add column if not exists stage_score int not null default 0;   -- plinko total / cliff steps / wof bank / jeopardy score
alter table public.pm_pir_players add column if not exists round_score int not null default 0;   -- wof: this puzzle
alter table public.pm_pir_players add column if not exists chips int not null default 0;         -- plinko chips left
alter table public.pm_pir_players add column if not exists drops jsonb not null default '[]'::jsonb;
alter table public.pm_pir_players add column if not exists guess int;                             -- cliff: this round
alter table public.pm_pir_players add column if not exists guess_at timestamptz;
alter table public.pm_pir_players add column if not exists out boolean not null default false;    -- cliff: fell off
-- answers the players must not see (cliff answers, puzzles, jeopardy key). Host-only.
create table if not exists public.pm_pir_secrets (
  show_id uuid primary key references public.pm_pir_shows(id) on delete cascade,
  data    jsonb not null default '{}'::jsonb
);
-- question banks for Cliff Hangers (number answers) and Wheel of Fortune (puzzles). Host-only.
create table if not exists public.pm_pir_bank (
  id         bigserial primary key,
  kind       text not null check (kind in ('cliff','wof')),
  category   text,
  text       text not null,
  answer     text,
  active     boolean not null default true,
  used_at    timestamptz,
  created_at timestamptz not null default now(),
  unique (kind, text)
);
-- secret moves: who you gave to (donations / high rollers) and finalist bids
create table if not exists public.pm_pir_moves (
  show_id    uuid not null references public.pm_pir_shows(id) on delete cascade,
  profile_id uuid not null references public.pm_profiles(id) on delete cascade,
  kind       text not null check (kind in ('give','bid')),
  to_profile uuid references public.pm_profiles(id) on delete cascade,
  amount     int,
  updated_at timestamptz not null default now(),
  primary key (show_id, profile_id, kind)
);
create table if not exists public.pm_pir_bets (
  show_id    uuid not null references public.pm_pir_shows(id) on delete cascade,
  profile_id uuid not null references public.pm_profiles(id) on delete cascade,
  on_profile uuid not null references public.pm_profiles(id) on delete cascade,
  amount     int  not null check (amount > 0),
  payout     int  not null default 0,
  created_at timestamptz not null default now(),
  primary key (show_id, profile_id)
);

-- word-count helper for dictation: correct words, any order, each passage word counted at most as often as it appears
create or replace function public.pm_pir_words(p_passage text, p_typed text)
returns int language sql immutable set search_path = '' as $$
  with p as (select w, count(*) c from regexp_split_to_table(btrim(regexp_replace(lower(coalesce(p_passage, '')), '[^a-z0-9'']+', ' ', 'g')), ' ') w where w <> '' group by w),
       t as (select w, count(*) c from regexp_split_to_table(btrim(regexp_replace(lower(coalesce(p_typed, '')), '[^a-z0-9'']+', ' ', 'g')), ' ') w where w <> '' group by w)
  select coalesce(sum(least(p.c, t.c)), 0)::int from p join t using (w);
$$;

-- math problem n for a player (deterministic): small +/- like the original, 4 choices
create or replace function public.pm_pir_problem(p_show uuid, p_profile uuid, p_idx int)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare h text := md5(p_show::text || p_profile::text || p_idx::text);
  a int; b int; plus boolean; ans int; offs int[] := array[-10,-5,-4,-3,-2,-1,1,2,3,4,5,10]; ch int[]; o int; i int := 0; k int; tmp int;
begin
  a := ('x' || substr(h, 1, 2))::bit(8)::int % 19 + 1;
  b := ('x' || substr(h, 3, 2))::bit(8)::int % 19 + 1;
  plus := ('x' || substr(h, 5, 1))::bit(4)::int < 8;
  ans := case when plus then a + b else a - b end;
  ch := array[ans];
  while array_length(ch, 1) < 4 loop
    o := offs[(('x' || substr(h, 7 + (i % 20), 2))::bit(8)::int + i) % 12 + 1];
    if not (ans + o = any(ch)) then ch := ch || (ans + o); end if;
    i := i + 1;
  end loop;
  -- shuffle
  for k in reverse 4..2 loop
    i := ('x' || substr(h, 25 + k, 2))::bit(8)::int % k + 1;
    tmp := ch[k]; ch[k] := ch[i]; ch[i] := tmp;
  end loop;
  return jsonb_build_object('a', a, 'b', b, 'op', case when plus then '+' else '-' end,
    'choices', to_jsonb(ch), 'correct', array_position(ch, ans) - 1);
end $$;

create or replace function public.pm_pir_enter(p_profile uuid, p_show uuid, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; pr public.pm_profiles; r text;
begin
  select * into s from public.pm_pir_shows where id = p_show;
  if not found or s.phase <> 'qualifier' then return 'round_closed'; end if;
  if exists (select 1 from public.pm_pir_players where show_id = p_show and profile_id = p_profile) then return null; end if;
  r := public.pm_enter(p_profile, s.session_id, p_via, 'pir');
  if r is not null then return r; end if;
  select * into pr from public.pm_profiles where id = p_profile;
  insert into public.pm_pir_players (show_id, profile_id, display_name, avatar_url, via)
  values (p_show, p_profile, coalesce(pr.display_name, pr.login), pr.avatar_url, p_via) on conflict do nothing;
  return null;
end $$;

create or replace function public.pm_pir_open(p_show uuid)
returns public.pm_pir_shows language sql stable security definer set search_path = '' as $$
  select * from public.pm_pir_shows where id = p_show and phase = 'qualifier' and (closes_at is null or now() <= closes_at + interval '2 seconds');
$$;

-- ── qualifier actions (internal, by profile) ──
create or replace function public.pm_pir_type_as(p_profile uuid, p_show uuid, p_text text, p_append boolean, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; r text; t text;
begin
  s := public.pm_pir_open(p_show);
  if s.id is null or s.qual <> 'dictation' then return 'round_closed'; end if;
  r := public.pm_pir_enter(p_profile, p_show, p_via); if r is not null then return r; end if;
  select typed into t from public.pm_pir_players where show_id = p_show and profile_id = p_profile;
  t := left(case when p_append then coalesce(t, '') || ' ' || coalesce(p_text, '') else coalesce(p_text, '') end, 4000);
  update public.pm_pir_players set typed = t, score = public.pm_pir_words(s.passage, t), acted_at = now()
   where show_id = p_show and profile_id = p_profile;
  return 'ok';
end $$;

create or replace function public.pm_pir_give_as(p_profile uuid, p_show uuid, p_to uuid, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; r text;
begin
  s := public.pm_pir_open(p_show);
  if s.id is null or s.qual not in ('donations','highrollers') then return 'round_closed'; end if;
  if p_to is null or p_to = p_profile then return 'self'; end if;
  if not exists (select 1 from public.pm_profiles where id = p_to) then return 'no_player'; end if;
  r := public.pm_pir_enter(p_profile, p_show, p_via); if r is not null then return r; end if;
  -- the receiver is in the game too (you can push dice/money onto anyone playing)
  r := public.pm_pir_enter(p_to, p_show, 'app');
  if r is not null and r <> 'round_closed' then return 'no_player'; end if;
  insert into public.pm_pir_moves (show_id, profile_id, kind, to_profile) values (p_show, p_profile, 'give', p_to)
  on conflict (show_id, profile_id, kind) do update set to_profile = excluded.to_profile, updated_at = now();
  update public.pm_pir_players set acted_at = now() where show_id = p_show and profile_id = p_profile;
  return 'ok';
end $$;

create or replace function public.pm_pir_join_as(p_profile uuid, p_show uuid, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare r text;
begin
  if public.pm_pir_open(p_show) is null then
    -- everyone-plays games (Plinko / Jeopardy) also let people in after the lobby closed
    r := public.pm_pir_late_as(p_profile, p_show, p_via);
    return coalesce(r, 'ok');
  end if;
  r := public.pm_pir_enter(p_profile, p_show, p_via);
  return coalesce(r, 'ok');
end $$;

-- ── players ──
create or replace function public.pm_pir_join(p_show uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_pir_join_as(pid, p_show, 'app');
end $$;

create or replace function public.pm_pir_type(p_show uuid, p_text text)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_pir_type_as(pid, p_show, p_text, false, 'app');
end $$;

create or replace function public.pm_pir_give(p_show uuid, p_to uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_pir_give_as(pid, p_show, p_to, 'app');
end $$;

-- Math: get the current problem (no answer included)
create or replace function public.pm_pir_math_next(p_show uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile(); s public.pm_pir_shows; r text; pl public.pm_pir_players; pb jsonb;
begin
  if pid is null then return jsonb_build_object('error', 'no_profile'); end if;
  s := public.pm_pir_open(p_show);
  if s.id is null or s.qual <> 'math' then return jsonb_build_object('error', 'round_closed'); end if;
  r := public.pm_pir_enter(pid, p_show, 'app'); if r is not null then return jsonb_build_object('error', r); end if;
  select * into pl from public.pm_pir_players where show_id = p_show and profile_id = pid;
  pb := public.pm_pir_problem(p_show, pid, pl.math_idx);
  return jsonb_build_object('idx', pl.math_idx, 'a', pb->'a', 'b', pb->'b', 'op', pb->'op', 'choices', pb->'choices',
    'score', coalesce(pl.score, 0), 'busted', pl.busted, 'locked', pl.locked, 'stunned_until', pl.stunned_until);
end $$;

create or replace function public.pm_pir_math_answer(p_show uuid, p_idx int, p_choice int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile(); s public.pm_pir_shows; pl public.pm_pir_players; pb jsonb; ok boolean; sc int;
begin
  if pid is null then return jsonb_build_object('error', 'no_profile'); end if;
  s := public.pm_pir_open(p_show);
  if s.id is null or s.qual <> 'math' then return jsonb_build_object('error', 'round_closed'); end if;
  select * into pl from public.pm_pir_players where show_id = p_show and profile_id = pid for update;
  if not found then return jsonb_build_object('error', 'not_in_game'); end if;
  if pl.busted or pl.locked then return public.pm_pir_math_next(p_show); end if;
  if p_idx <> pl.math_idx then return public.pm_pir_math_next(p_show); end if;
  if pl.stunned_until is not null and now() < pl.stunned_until then return jsonb_build_object('error', 'stunned', 'stunned_until', pl.stunned_until); end if;
  pb := public.pm_pir_problem(p_show, pid, pl.math_idx);
  ok := (pb->>'correct')::int = p_choice;
  sc := coalesce(pl.score, 0) + case when ok then 25 else 0 end;
  update public.pm_pir_players set math_idx = math_idx + 1, score = sc, acted_at = now(),
    stunned_until = case when ok then null else now() + interval '2 seconds' end,
    busted = sc > s.target, bust_reason = case when sc > s.target then 'over' else null end
   where show_id = p_show and profile_id = pid;
  return public.pm_pir_math_next(p_show) || jsonb_build_object('was_correct', ok);
end $$;

create or replace function public.pm_pir_lock(p_show uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  if public.pm_pir_open(p_show) is null then return 'round_closed'; end if;
  update public.pm_pir_players set locked = true, acted_at = now() where show_id = p_show and profile_id = pid;
  return case when found then 'ok' else 'not_in_game' end;
end $$;

-- ── stage (internal, by profile) ──
create or replace function public.pm_pir_bid_as(p_profile uuid, p_show uuid, p_amount int)
returns text language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows;
begin
  select * into s from public.pm_pir_shows where id = p_show;
  if not found or s.stage <> 'showcase' or s.phase <> 'stage' then return 'round_closed'; end if;
  if not exists (select 1 from public.pm_pir_players where show_id = p_show and profile_id = p_profile and qualified) then return 'not_finalist'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 100000000 then return 'bad_amount'; end if;
  insert into public.pm_pir_moves (show_id, profile_id, kind, amount) values (p_show, p_profile, 'bid', p_amount)
  on conflict (show_id, profile_id, kind) do update set amount = excluded.amount, updated_at = now();
  return 'ok';
end $$;

create or replace function public.pm_pir_bet_as(p_profile uuid, p_show uuid, p_on uuid, p_amount int)
returns text language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; bal int; r text;
begin
  select * into s from public.pm_pir_shows where id = p_show;
  if not found or s.phase <> 'stage' or not (s.stage = 'showcase' or coalesce((s.board->>'bets_open')::boolean, false)) then return 'bets_closed'; end if;
  if exists (select 1 from public.pm_pir_players where show_id = p_show and profile_id = p_profile and qualified) then return 'finalist_no_bet'; end if;
  if not exists (select 1 from public.pm_pir_players where show_id = p_show and profile_id = p_on and qualified) then return 'not_finalist'; end if;
  if p_amount is null or p_amount < 1 then return 'bad_amount'; end if;
  if exists (select 1 from public.pm_pir_bets where show_id = p_show and profile_id = p_profile) then return 'already'; end if;
  r := public.pm_check(p_profile, s.session_id, 'pir'); if r is not null then return r; end if;
  select balance into bal from public.pm_profiles where id = p_profile for update;
  if bal < p_amount then return 'not_enough'; end if;
  insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (p_profile, -p_amount, 'The Picks Are Right: bet', 'pir', 'pir');
  insert into public.pm_pir_bets (show_id, profile_id, on_profile, amount) values (p_show, p_profile, p_on, p_amount);
  perform public.pm_log(p_profile, 'pir_bet', jsonb_build_object('amount', p_amount), s.session_id);
  return 'ok';
end $$;

-- wheel: only the current spinner can act; spin (max 2) or stay after 1
create or replace function public.pm_pir_wheel_as(p_profile uuid, p_show uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; cur uuid; pl public.pm_pir_players; v int; tot int; nxt boolean := false; n int;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'wheel' or s.phase <> 'stage' then return jsonb_build_object('error', 'round_closed'); end if;
  select profile_id into cur from public.pm_pir_players where show_id = p_show and qualified order by rank desc offset s.wheel_turn limit 1;
  if cur is null or cur <> p_profile then return jsonb_build_object('error', 'not_your_turn'); end if;
  select * into pl from public.pm_pir_players where show_id = p_show and profile_id = p_profile for update;
  n := coalesce(array_length(pl.spins, 1), 0);
  if p_action = 'spin' then
    if n >= 2 then return jsonb_build_object('error', 'no_spins'); end if;
    v := (floor(random() * 20)::int + 1) * 5;
    pl.spins := pl.spins || v;
    update public.pm_pir_shows set board = board || jsonb_build_object('bets_open', false, 'spin_seq', coalesce((board->>'spin_seq')::int, 0) + 1) where id = p_show;
    tot := (select sum(x) from unnest(pl.spins) x);
    update public.pm_pir_players set spins = pl.spins, score = tot, busted = tot > 100, bust_reason = case when tot > 100 then 'over' end,
      wheel_done = (tot > 100 or n + 1 >= 2) where show_id = p_show and profile_id = p_profile;
    nxt := tot > 100 or n + 1 >= 2;
  elsif p_action = 'stay' then
    if n < 1 then return jsonb_build_object('error', 'spin_first'); end if;
    update public.pm_pir_players set wheel_done = true where show_id = p_show and profile_id = p_profile;
    tot := pl.score; nxt := true;
  else return jsonb_build_object('error', 'bad_action'); end if;
  if nxt then
    update public.pm_pir_shows set wheel_turn = wheel_turn + 1,
      phase = case when wheel_turn + 1 >= (select count(*) from public.pm_pir_players where show_id = p_show and qualified) then 'locked' else phase end
     where id = p_show;
  end if;
  return jsonb_build_object('value', v, 'total', tot, 'spins', to_jsonb(pl.spins), 'busted', coalesce(tot, 0) > 100, 'next', nxt);
end $$;

create or replace function public.pm_pir_bid(p_show uuid, p_amount int)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_pir_bid_as(pid, p_show, p_amount);
end $$;
create or replace function public.pm_pir_bet(p_show uuid, p_on uuid, p_amount int)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return 'no_profile'; end if;
  return public.pm_pir_bet_as(pid, p_show, p_on, p_amount);
end $$;
create or replace function public.pm_pir_wheel(p_show uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return jsonb_build_object('error', 'no_profile'); end if;
  return public.pm_pir_wheel_as(pid, p_show, p_action);
end $$;

-- public counts (no secrets)
create or replace function public.pm_pir_progress(p_show uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'players', (select count(*) from public.pm_pir_players where show_id = p_show),
    'gave',    (select count(*) from public.pm_pir_moves where show_id = p_show and kind = 'give'),
    'locked',  (select count(*) from public.pm_pir_players where show_id = p_show and (locked or busted)),
    'typed',   (select count(*) from public.pm_pir_players where show_id = p_show and typed is not null),
    'bids',    (select coalesce(jsonb_agg(profile_id), '[]'::jsonb) from public.pm_pir_moves where show_id = p_show and kind = 'bid'),
    'pools',   (select coalesce(jsonb_object_agg(on_profile, s), '{}'::jsonb) from (select on_profile, sum(amount) s from public.pm_pir_bets where show_id = p_show group by on_profile) x),
    'bettors', (select count(*) from public.pm_pir_bets where show_id = p_show));
$$;

-- ── host ──
create or replace function public.pm_admin_pir_create(p_session uuid, p_qual text, p_stage text, p_target int, p_finalists int,
  p_prize int, p_qual_reward int, p_passage text, p_seconds int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  perform public.pm_require_admin();
  update public.pm_pir_shows set phase = 'cancelled', ended_at = now() where phase not in ('done','cancelled');
  insert into public.pm_pir_shows (session_id, qual, stage, target, finalists_n, prize, qual_reward, passage, closes_at)
  values (p_session, p_qual, p_stage, p_target, coalesce(p_finalists, 3), coalesce(p_prize, 50), coalesce(p_qual_reward, 0), p_passage,
          case when p_seconds is null then null else now() + make_interval(secs => p_seconds) end)
  returning id into sid;
  return sid;
end $$;

-- (re)start the qualifier timer, e.g. after the dictation passage finishes reading
create or replace function public.pm_admin_pir_timer(p_show uuid, p_seconds int)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare c timestamptz;
begin
  perform public.pm_require_admin();
  update public.pm_pir_shows set closes_at = case when p_seconds is null then null else now() + make_interval(secs => p_seconds) end
   where id = p_show and phase = 'qualifier' returning closes_at into c;
  return c;
end $$;

create or replace function public.pm_admin_pir_chat(p_show uuid, p_twitch_id text, p_login text, p_display text, p_action text, p_arg text)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid; to_id uuid; r jsonb;
begin
  pid := public.pm_admin_chatter(p_twitch_id, p_login, p_display);   -- checks admin
  if p_action = 'join' then return public.pm_pir_join_as(pid, p_show, 'chat');
  elsif p_action = 'type' then return public.pm_pir_type_as(pid, p_show, p_arg, true, 'chat');
  elsif p_action = 'give' then
    select id into to_id from public.pm_profiles where login = lower(ltrim(btrim(p_arg), '@'));
    if to_id is null then return 'no_player'; end if;
    return public.pm_pir_give_as(pid, p_show, to_id, 'chat');
  elsif p_action = 'bid' then return public.pm_pir_bid_as(pid, p_show, nullif(regexp_replace(p_arg, '[^0-9]', '', 'g'), '')::int);
  elsif p_action in ('spin','stay') and (select stage from public.pm_pir_shows where id = p_show) = 'wheel' then
    r := public.pm_pir_wheel_as(pid, p_show, p_action);
    return coalesce(r->>'error', 'ok');
  elsif p_action in ('drop','guess','spin','letter','buy','solve','pick','answer') then
    r := public.pm_pir_play_as(pid, p_show, p_action, p_arg, 'chat');
    return coalesce(r->>'error', 'ok');
  end if;
  return 'bad_action';
end $$;

create or replace function public.pm_admin_pir_chat_bet(p_show uuid, p_twitch_id text, p_login text, p_display text, p_on_login text, p_amount int)
returns text language plpgsql security definer set search_path = '' as $$
declare pid uuid; on_id uuid;
begin
  pid := public.pm_admin_chatter(p_twitch_id, p_login, p_display);
  select id into on_id from public.pm_profiles where login = lower(ltrim(btrim(p_on_login), '@'));
  if on_id is null then return 'not_finalist'; end if;
  return public.pm_pir_bet_as(pid, p_show, on_id, p_amount);
end $$;

-- Close the qualifier: score donations / high rollers, bust anyone over, pick finalists.
create or replace function public.pm_admin_pir_close(p_show uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; e record; n int; dice int;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.phase <> 'qualifier' then raise exception 'qualifier is not running'; end if;
  update public.pm_pir_shows set phase = 'closed', closes_at = least(coalesce(closes_at, now()), now()) where id = p_show;
  if s.qual = 'donations' then
    update public.pm_pir_players p set score = s.per_gift * (select count(*) from public.pm_pir_moves m where m.show_id = p_show and m.kind = 'give' and m.to_profile = p.profile_id)
     where p.show_id = p_show;
    update public.pm_pir_players set busted = true, bust_reason = 'over' where show_id = p_show and score > s.target;
    -- donated to someone who went over? you bust too
    update public.pm_pir_players p set busted = true, bust_reason = 'donor'
     where p.show_id = p_show and not p.busted and exists (
       select 1 from public.pm_pir_moves m join public.pm_pir_players q on q.show_id = m.show_id and q.profile_id = m.to_profile
        where m.show_id = p_show and m.kind = 'give' and m.profile_id = p.profile_id and q.bust_reason = 'over');
  elsif s.qual = 'highrollers' then
    for e in select profile_id from public.pm_pir_players where show_id = p_show loop
      select 3 + count(*) into dice from public.pm_pir_moves m where m.show_id = p_show and m.kind = 'give' and m.to_profile = e.profile_id;
      update public.pm_pir_players set rolls = (select array_agg(floor(random() * 6)::int + 1) from generate_series(1, dice))
       where show_id = p_show and profile_id = e.profile_id;
    end loop;
    update public.pm_pir_players set score = (select sum(x) from unnest(rolls) x) where show_id = p_show;
    update public.pm_pir_players set busted = true, bust_reason = 'over' where show_id = p_show and score > s.target;
  elsif s.qual <> 'none' then
    update public.pm_pir_players set busted = true, bust_reason = 'over' where show_id = p_show and coalesce(score, 0) > s.target and not busted;
  end if;
  if s.qual = 'none' then
    -- lobby: everyone who joined plays, or draw finalists_n contestants at random
    update public.pm_pir_players p set qualified = true, rank = x.rk
      from (select profile_id, row_number() over (order by case when s.finalists_n > 0 then random() else 0 end, joined_at) rk
              from public.pm_pir_players where show_id = p_show) x
     where p.show_id = p_show and p.profile_id = x.profile_id and (s.finalists_n = 0 or x.rk <= s.finalists_n);
  else
  -- finalists: closest without going over (highest score <= target), earliest to act wins ties
  update public.pm_pir_players p set qualified = true, rank = x.rk
    from (select profile_id, row_number() over (order by score desc, acted_at nulls last, joined_at) rk
            from public.pm_pir_players where show_id = p_show and not busted and coalesce(score, 0) > 0) x
   where p.show_id = p_show and p.profile_id = x.profile_id and x.rk <= s.finalists_n;
  end if;
  select count(*) into n from public.pm_pir_players where show_id = p_show and qualified;
  if s.qual_reward > 0 then
    insert into public.pm_ledger (profile_id, delta, reason, game, actor)
    select profile_id, s.qual_reward, 'The Picks Are Right: made the finals', 'pir', 'pir' from public.pm_pir_players where show_id = p_show and qualified;
  end if;
  update public.pm_pir_shows set phase = 'results' where id = p_show;
  return jsonb_build_object('finalists', n,
    'players', (select count(*) from public.pm_pir_players where show_id = p_show),
    'busted', (select count(*) from public.pm_pir_players where show_id = p_show and busted));
end $$;

create or replace function public.pm_admin_pir_stage(p_show uuid, p_item text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.pm_admin_pir_begin(p_show, p_item, '{}'::jsonb);
end $$;

create or replace function public.pm_admin_pir_lock(p_show uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.pm_require_admin();
  update public.pm_pir_shows set phase = 'locked' where id = p_show and phase = 'stage';
end $$;

-- host acts for the current wheel spinner (if they're away)
create or replace function public.pm_admin_pir_wheel(p_show uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; cur uuid;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show;
  select profile_id into cur from public.pm_pir_players where show_id = p_show and qualified order by rank desc offset s.wheel_turn limit 1;
  if cur is null then return jsonb_build_object('error', 'no_spinner'); end if;
  return public.pm_pir_wheel_as(cur, p_show, p_action);
end $$;

create or replace function public.pm_pir_pay_bets(p_show uuid, p_winners uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pot int; win_total int; b record; amt int; paid int := 0; first_id uuid;
begin
  select coalesce(sum(amount), 0) into pot from public.pm_pir_bets where show_id = p_show;
  select coalesce(sum(amount), 0) into win_total from public.pm_pir_bets where show_id = p_show and on_profile = any(p_winners);
  if pot = 0 then return jsonb_build_object('pot', 0); end if;
  if win_total = 0 then
    for b in select * from public.pm_pir_bets where show_id = p_show loop
      insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (b.profile_id, b.amount, 'The Picks Are Right: bet refunded', 'pir', 'pir');
      update public.pm_pir_bets set payout = b.amount where show_id = p_show and profile_id = b.profile_id;
    end loop;
    return jsonb_build_object('pot', pot, 'refunded', true);
  end if;
  for b in select * from public.pm_pir_bets where show_id = p_show and on_profile = any(p_winners) order by amount desc, created_at loop
    if first_id is null then first_id := b.profile_id; end if;
    amt := (b.amount::bigint * pot / win_total)::int;
    paid := paid + amt;
    update public.pm_pir_bets set payout = amt where show_id = p_show and profile_id = b.profile_id;
  end loop;
  update public.pm_pir_bets set payout = payout + (pot - paid) where show_id = p_show and profile_id = first_id;
  for b in select * from public.pm_pir_bets where show_id = p_show and payout > 0 loop
    insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (b.profile_id, b.payout, 'The Picks Are Right: bet won', 'pir', 'pir');
    perform public.pm_log(b.profile_id, 'pir_bet_won', jsonb_build_object('bet', b.amount, 'payout', b.payout), null);
  end loop;
  return jsonb_build_object('pot', pot, 'winning_bets', win_total);
end $$;

-- Showcase reveal: closest bid without going over wins; within p_bonus_pct of the value = double prize
create or replace function public.pm_admin_pir_reveal(p_show uuid, p_secret int, p_bonus_pct int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; w record; prize int; bets jsonb; bids jsonb;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'showcase' or s.phase not in ('stage','locked') then raise exception 'showcase is not running'; end if;
  update public.pm_pir_shows set phase = 'done', secret = p_secret, ended_at = now() where id = p_show;
  select coalesce(jsonb_object_agg(profile_id, amount), '{}'::jsonb) into bids from public.pm_pir_moves where show_id = p_show and kind = 'bid';
  update public.pm_pir_players p set score = m.amount, busted = m.amount > p_secret, bust_reason = case when m.amount > p_secret then 'over' end
    from public.pm_pir_moves m where m.show_id = p_show and m.kind = 'bid' and m.profile_id = p.profile_id and p.show_id = p_show and p.qualified;
  select m.profile_id, m.amount into w from public.pm_pir_moves m
   join public.pm_pir_players p on p.show_id = m.show_id and p.profile_id = m.profile_id and p.qualified
   where m.show_id = p_show and m.kind = 'bid' and m.amount <= p_secret order by m.amount desc, m.updated_at limit 1;
  if w.profile_id is null then
    bets := public.pm_pir_pay_bets(p_show, array[]::uuid[]);
    return jsonb_build_object('winner', null, 'secret', p_secret, 'bids', bids, 'bets', bets);
  end if;
  prize := s.prize * case when p_secret - w.amount <= p_secret * coalesce(p_bonus_pct, 0) / 100 then 2 else 1 end;
  if prize > 0 then
    insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (w.profile_id, prize, 'The Picks Are Right: won the showcase', 'pir', 'pir');
  end if;
  update public.pm_pir_players set payout = prize where show_id = p_show and profile_id = w.profile_id;
  perform public.pm_log(w.profile_id, 'pir_won', jsonb_build_object('payout', prize, 'stage', 'showcase'), s.session_id);
  bets := public.pm_pir_pay_bets(p_show, array[w.profile_id]);
  return jsonb_build_object('winner', w.profile_id, 'bid', w.amount, 'secret', p_secret, 'prize', prize,
    'doubled', prize > s.prize, 'bids', bids, 'bets', bets);
end $$;

-- Wheel finish: highest total <= 100 wins (ties split); exactly 100 earns the bonus
create or replace function public.pm_admin_pir_wheel_finish(p_show uuid, p_bonus int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; best int; n int; each int; rem int; i int := 0; e record; amt int; bets jsonb; ws uuid[];
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'wheel' or s.phase not in ('stage','locked') then raise exception 'wheel is not running'; end if;
  update public.pm_pir_shows set phase = 'done', ended_at = now() where id = p_show;
  select max(score) into best from public.pm_pir_players where show_id = p_show and qualified and not busted and coalesce(array_length(spins, 1), 0) > 0;
  if best is null then return jsonb_build_object('winners', '[]'::jsonb, 'bets', public.pm_pir_pay_bets(p_show, array[]::uuid[])); end if;
  select count(*), array_agg(profile_id) into n, ws from public.pm_pir_players where show_id = p_show and qualified and not busted and score = best;
  each := s.prize / n; rem := s.prize % n;
  for e in select profile_id from public.pm_pir_players where show_id = p_show and qualified and not busted and score = best order by rank loop
    amt := each + case when i < rem then 1 else 0 end + case when best = 100 then coalesce(p_bonus, 0) else 0 end;
    i := i + 1;
    if amt > 0 then
      insert into public.pm_ledger (profile_id, delta, reason, game, actor)
      values (e.profile_id, amt, 'The Picks Are Right: won the wheel' || case when best = 100 then ' (hit 100!)' else '' end, 'pir', 'pir');
    end if;
    update public.pm_pir_players set payout = amt where show_id = p_show and profile_id = e.profile_id;
    perform public.pm_log(e.profile_id, 'pir_won', jsonb_build_object('payout', amt, 'stage', 'wheel', 'total', best), s.session_id);
  end loop;
  bets := public.pm_pir_pay_bets(p_show, ws);
  return jsonb_build_object('best', best, 'winners', to_jsonb(ws), 'bets', bets);
end $$;

create or replace function public.pm_admin_pir_cancel(p_show uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare b record; n int := 0;
begin
  perform public.pm_require_admin();
  update public.pm_pir_shows set phase = 'cancelled', ended_at = now() where id = p_show and phase not in ('done','cancelled');
  if not found then return 0; end if;
  for b in select * from public.pm_pir_bets where show_id = p_show and payout = 0 loop
    insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (b.profile_id, b.amount, 'The Picks Are Right: bet refunded', 'pir', 'pir');
    update public.pm_pir_bets set payout = b.amount where show_id = p_show and profile_id = b.profile_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ════════════════════════════════════════════════════════════
--  FINALS GAMES: Plinko · Cliff Hangers · Wheel of Fortune · Jeopardy
--  Played by the finalists, or by everyone in a lobby (qual = 'none').
--  The public game board lives in pm_pir_shows.board; answers live in pm_pir_secrets (host only).
-- ════════════════════════════════════════════════════════════
create or replace function public.pm_pir_wof_wedges()
returns text[] language sql immutable set search_path = '' as $$
  select array['2500','600','700','600','650','500','700','BANKRUPT','600','550','500','600',
               'LOSE','650','500','700','BANKRUPT','800','500','650','500','900','550','1000']::text[];
$$;

-- Plinko slot values: the middle slot is the stage prize
create or replace function public.pm_pir_plinko_slots(p_prize int)
returns jsonb language sql immutable set search_path = '' as $$
  select to_jsonb(array[greatest(least(p_prize, 1), p_prize / 100), greatest(least(p_prize, 1), p_prize / 20), greatest(least(p_prize, 1), p_prize / 10), 0,
                        greatest(p_prize, 0), 0, greatest(least(p_prize, 1), p_prize / 10), greatest(least(p_prize, 1), p_prize / 20), greatest(least(p_prize, 1), p_prize / 100)]);
$$;

-- Wheel of Fortune puzzle: uppercase, fits a 4 x 14 board. null = not usable
create or replace function public.pm_pir_wof_clean(p text)
returns text language plpgsql immutable set search_path = '' as $$
declare t text := upper(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'))); w text; rows int := 1; cur int := 0;
begin
  t := translate(t, '’‘', '''''');
  if t = '' or t !~ '[A-Z]' or t ~ '[^A-Z0-9 ''&?!.,:-]' or length(t) > 52 then return null; end if;
  foreach w in array string_to_array(t, ' ') loop
    if length(w) > 14 then return null; end if;
    if cur = 0 then cur := length(w);
    elsif cur + 1 + length(w) <= 14 then cur := cur + 1 + length(w);
    else rows := rows + 1; cur := length(w); end if;
  end loop;
  return case when rows <= 4 then t end;
end $$;

create or replace function public.pm_pir_wof_mask(p_text text, p_used text)
returns text language sql immutable set search_path = '' as $$
  select coalesce(string_agg(case when c ~ '[A-Z]' and position(c in coalesce(p_used, '')) = 0 then '_' else c end, '' order by i), '')
    from (select substr(p_text, i, 1) c, i from generate_series(1, length(coalesce(p_text, ''))) i) x;
$$;

-- late joiners: in an everyone-plays Plinko or Jeopardy you can jump in any time
create or replace function public.pm_pir_late_as(p_profile uuid, p_show uuid, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; pr public.pm_profiles; r text; rk int;
begin
  select * into s from public.pm_pir_shows where id = p_show;
  if not found or s.phase <> 'stage' or s.qual <> 'none' or s.finalists_n <> 0 or s.stage not in ('plinko','jeopardy') then return 'round_closed'; end if;
  if exists (select 1 from public.pm_pir_players where show_id = p_show and profile_id = p_profile) then return null; end if;
  r := public.pm_enter(p_profile, s.session_id, p_via, 'pir');
  if r is not null then return r; end if;
  select * into pr from public.pm_profiles where id = p_profile;
  select coalesce(max(rank), 0) + 1 into rk from public.pm_pir_players where show_id = p_show;
  insert into public.pm_pir_players (show_id, profile_id, display_name, avatar_url, via, qualified, rank, chips)
  values (p_show, p_profile, coalesce(pr.display_name, pr.login), pr.avatar_url, p_via, true, rk,
          case when s.stage = 'plinko' then coalesce((s.opts->>'chips')::int, 3) else 0 end)
  on conflict do nothing;
  return null;
end $$;

-- ── host: start the main stage (all stages) ──
create or replace function public.pm_admin_pir_begin(p_show uuid, p_item text, p_opts jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; o jsonb := coalesce(p_opts, '{}'::jsonb); b jsonb; sec jsonb; n int; k int; q jsonb;
  picked jsonb := '[]'::jsonb; e record; ord jsonb; t text;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.phase <> 'results' then raise exception 'show the results first'; end if;
  select count(*) into n from public.pm_pir_players where show_id = p_show and qualified;
  if n = 0 and not (s.qual = 'none' and s.finalists_n = 0 and s.stage in ('plinko','jeopardy')) then raise exception 'nobody is playing'; end if;
  b := coalesce(s.board, '{}'::jsonb) || jsonb_build_object('bets_open', true);
  sec := coalesce((select data from public.pm_pir_secrets where show_id = p_show), '{}'::jsonb);

  if s.stage = 'plinko' then
    k := least(10, greatest(1, coalesce((o->>'chips')::int, 3)));
    o := o || jsonb_build_object('chips', k);
    update public.pm_pir_players set chips = k, stage_score = 0, drops = '[]'::jsonb where show_id = p_show and qualified;
    b := b || jsonb_build_object('slots', public.pm_pir_plinko_slots(s.prize), 'drops', 0);

  elsif s.stage = 'cliff' then
    k := least(5, greatest(1, coalesce((o->>'rounds')::int, 3)));
    for q in select x from jsonb_array_elements(case when jsonb_typeof(o->'questions') = 'array' then o->'questions' else '[]'::jsonb end) x loop
      if jsonb_array_length(picked) < k and coalesce(btrim(q->>'q'), '') <> '' and coalesce(q->>'a', '') ~ '^-?[0-9]{1,7}$' then
        picked := picked || jsonb_build_array(jsonb_build_object('q', left(btrim(q->>'q'), 200), 'a', (q->>'a')::int));
      end if;
    end loop;
    if jsonb_array_length(picked) < k then
      for e in select id, text, answer from public.pm_pir_bank where kind = 'cliff' and active and answer ~ '^-?[0-9]{1,7}$'
                order by used_at nulls first, random() limit k - jsonb_array_length(picked) loop
        picked := picked || jsonb_build_array(jsonb_build_object('q', e.text, 'a', e.answer::int));
        update public.pm_pir_bank set used_at = now() where id = e.id;
      end loop;
    end if;
    k := jsonb_array_length(picked);
    if k = 0 then raise exception 'no Cliff Hangers questions (add some in the dashboard)'; end if;
    sec := sec || jsonb_build_object('qs', picked);
    o := (o || jsonb_build_object('rounds', k)) - 'questions';
    b := b || jsonb_build_object('round', 0, 'rounds', k, 'limit', least(100, greatest(5, coalesce((o->>'limit')::int, 25))),
                                 'open', false, 'q', null, 'answer', null);
    update public.pm_pir_players set stage_score = 0, out = false, guess = null, guess_at = null where show_id = p_show and qualified;

  elsif s.stage = 'wof' then
    k := least(3, greatest(1, coalesce((o->>'rounds')::int, 1)));
    for q in select x from jsonb_array_elements(case when jsonb_typeof(o->'puzzles') = 'array' then o->'puzzles' else '[]'::jsonb end) x loop
      t := public.pm_pir_wof_clean(q->>'text');
      if jsonb_array_length(picked) < k and t is not null then
        picked := picked || jsonb_build_array(jsonb_build_object('cat', upper(left(coalesce(nullif(btrim(q->>'cat'), ''), 'PHRASE'), 30)), 'text', t));
      end if;
    end loop;
    if jsonb_array_length(picked) < k then
      for e in select id, category, text from public.pm_pir_bank where kind = 'wof' and active and public.pm_pir_wof_clean(text) is not null
                order by used_at nulls first, random() limit k - jsonb_array_length(picked) loop
        picked := picked || jsonb_build_array(jsonb_build_object('cat', upper(coalesce(e.category, 'PHRASE')), 'text', public.pm_pir_wof_clean(e.text)));
        update public.pm_pir_bank set used_at = now() where id = e.id;
      end loop;
    end if;
    k := jsonb_array_length(picked);
    if k = 0 then raise exception 'no Wheel of Fortune puzzles (add some in the dashboard)'; end if;
    sec := sec || jsonb_build_object('puzzles', picked);
    select jsonb_agg(profile_id::text order by rank) into ord from public.pm_pir_players where show_id = p_show and qualified;
    o := (o || jsonb_build_object('rounds', k)) - 'puzzles';
    b := b || jsonb_build_object('rounds', k, 'order', ord, 'turn_secs', least(90, greatest(10, coalesce((o->>'turn_secs')::int, 25))), 'spin_seq', 0);
    update public.pm_pir_players set stage_score = 0, round_score = 0 where show_id = p_show and qualified;

  elsif s.stage = 'jeopardy' then
    if not (sec ? 'cells') then raise exception 'build the Jeopardy board first'; end if;
    b := b || jsonb_build_object('secs', least(60, greatest(5, coalesce((o->>'secs')::int, 15))), 'control', null, 'cur', null,
                                 'answered', '[]'::jsonb, 'wrong', '[]'::jsonb, 'seq', 0);
    update public.pm_pir_players set stage_score = 0 where show_id = p_show and qualified;
  end if;

  insert into public.pm_pir_secrets (show_id, data) values (p_show, sec)
  on conflict (show_id) do update set data = excluded.data;
  update public.pm_pir_shows set phase = 'stage', item = left(p_item, 200), wheel_turn = 0, opts = o, board = b, closes_at = null where id = p_show;
  if s.stage = 'wof' then perform public.pm_pir_wof_load(p_show, 0); end if;
  return (select board from public.pm_pir_shows where id = p_show);
end $$;

-- ── Plinko ──
create or replace function public.pm_pir_drop(p_profile uuid, p_show uuid, p_pos int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; pl public.pm_pir_players; x int; path int[]; i int; slot int; v int; seq int;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  select * into pl from public.pm_pir_players where show_id = p_show and profile_id = p_profile for update;
  if pl.chips <= 0 then return jsonb_build_object('error', 'no_chips'); end if;
  if p_pos is null or p_pos < 1 or p_pos > 9 then return jsonb_build_object('error', 'bad_slot'); end if;
  -- 12 rows of pegs; the chip moves half a slot left or right at each peg and bounces off the walls
  x := (p_pos - 1) * 2; path := array[x];
  for i in 1..12 loop
    if x = 0 then x := 1; elsif x = 16 then x := 15; else x := x + case when random() < .5 then -1 else 1 end; end if;
    path := path || x;
  end loop;
  slot := x / 2;
  v := coalesce((s.board->'slots'->>slot)::int, 0);
  seq := coalesce((s.board->>'drops')::int, 0) + 1;
  update public.pm_pir_players set chips = chips - 1, stage_score = stage_score + v, acted_at = now(),
    drops = drops || jsonb_build_array(jsonb_build_object('pos', p_pos, 'path', to_jsonb(path), 'slot', slot, 'v', v, 'seq', seq))
   where show_id = p_show and profile_id = p_profile;
  update public.pm_pir_shows set board = board || jsonb_build_object('drops', seq, 'bets_open', false) where id = p_show;
  return jsonb_build_object('path', to_jsonb(path), 'slot', slot, 'value', v, 'seq', seq, 'chips', pl.chips - 1);
end $$;

-- ── Cliff Hangers ──
create or replace function public.pm_pir_cliff_guess(p_profile uuid, p_show uuid, p_arg text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; t text := regexp_replace(coalesce(p_arg, ''), '[^0-9-]', '', 'g');
begin
  select * into s from public.pm_pir_shows where id = p_show;
  if not coalesce((s.board->>'open')::boolean, false) or now() > s.closes_at + interval '2 seconds' then return jsonb_build_object('error', 'round_closed'); end if;
  if t !~ '^-?[0-9]{1,7}$' then return jsonb_build_object('error', 'bad_number'); end if;
  update public.pm_pir_players set guess = t::int, guess_at = now(), acted_at = now()
   where show_id = p_show and profile_id = p_profile and qualified and not out;
  if not found then return jsonb_build_object('error', 'fell'); end if;
  return jsonb_build_object('guess', t::int);
end $$;

create or replace function public.pm_admin_pir_cliff_ask(p_show uuid, p_seconds int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; r int; q jsonb;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'cliff' or s.phase <> 'stage' then raise exception 'Cliff Hangers is not running'; end if;
  if coalesce((s.board->>'open')::boolean, false) then raise exception 'a question is already open'; end if;
  r := coalesce((s.board->>'round')::int, 0);
  if r >= (s.board->>'rounds')::int then raise exception 'no more questions'; end if;
  select data->'qs'->r into q from public.pm_pir_secrets where show_id = p_show;
  update public.pm_pir_players set guess = null, guess_at = null where show_id = p_show and qualified;
  update public.pm_pir_shows set board = board || jsonb_build_object('open', true, 'round', r + 1, 'q', q->>'q', 'answer', null, 'bets_open', false),
    closes_at = now() + make_interval(secs => least(120, greatest(5, coalesce(p_seconds, 20))))
   where id = p_show;
  return jsonb_build_object('round', r + 1, 'q', q->>'q');
end $$;

-- reveal: everyone climbs by how far off they were (no guess = the full height). Past the top = fell off.
create or replace function public.pm_admin_pir_cliff_settle(p_show uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; r int; a int; lim int; alive int;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'cliff' or s.phase <> 'stage' or not coalesce((s.board->>'open')::boolean, false) then raise exception 'no question is open'; end if;
  r := (s.board->>'round')::int; lim := coalesce((s.board->>'limit')::int, 25);
  select (data->'qs'->(r - 1)->>'a')::int into a from public.pm_pir_secrets where show_id = p_show;
  -- (least() skips nulls, so no guess is handled explicitly)
  update public.pm_pir_players set stage_score = least(1000000, stage_score + case when guess is null then lim else least(abs(guess::bigint - a), 1000000)::int end),
    out = stage_score + case when guess is null then lim else least(abs(guess::bigint - a), 1000000)::int end > lim
   where show_id = p_show and qualified and not out;
  select count(*) into alive from public.pm_pir_players where show_id = p_show and qualified and not out;
  update public.pm_pir_shows set board = board || jsonb_build_object('open', false, 'answer', a), closes_at = null,
    phase = case when r >= (s.board->>'rounds')::int or alive = 0 then 'locked' else phase end
   where id = p_show;
  return jsonb_build_object('answer', a, 'alive', alive, 'last', r >= (s.board->>'rounds')::int or alive = 0);
end $$;

-- ── Wheel of Fortune ──
create or replace function public.pm_pir_wof_turn(p_b jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare k int;
begin
  select i % jsonb_array_length(p_b->'order') into k from jsonb_array_elements_text(p_b->'order') with ordinality t(v, i) where v = p_b->>'turn';
  return p_b || jsonb_build_object('turn', p_b->'order'->>coalesce(k, 0), 'sub', 'spin', 'value', null,
    'turn_until', now() + make_interval(secs => coalesce((p_b->>'turn_secs')::int, 25)));
end $$;

create or replace function public.pm_pir_wof_load(p_show uuid, p_idx int)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; pz jsonb; ord jsonb;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  select data->'puzzles'->p_idx into pz from public.pm_pir_secrets where show_id = p_show;
  if pz is null then raise exception 'no more puzzles'; end if;
  ord := s.board->'order';
  update public.pm_pir_players set round_score = 0 where show_id = p_show and qualified;
  update public.pm_pir_shows set board = board || jsonb_build_object('round', p_idx + 1, 'cat', pz->>'cat', 'mask', public.pm_pir_wof_mask(pz->>'text', ''),
      'used', '', 'solved', false, 'winner', null, 'sub', 'spin', 'value', null, 'wedge', null, 'turn', ord->>(p_idx % jsonb_array_length(ord)),
      'turn_until', now() + make_interval(secs => coalesce((s.board->>'turn_secs')::int, 25)),
      'ev', jsonb_build_object('seq', coalesce((s.board->'ev'->>'seq')::int, 0) + 1, 'kind', 'puzzle', 'text', 'PUZZLE ' || (p_idx + 1), 'who', null))
   where id = p_show;
end $$;

create or replace function public.pm_pir_wof_act(p_profile uuid, p_show uuid, p_action text, p_arg text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; b jsonb; txt text; used text; L text; n int; w int; val text; rs int; secs int;
  ev text; kind text := 'info'; nxt boolean := false; solved boolean := false; mask text; ph text;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  b := s.board; ph := s.phase;
  if coalesce((b->>'solved')::boolean, false) then return jsonb_build_object('error', 'round_over'); end if;
  if (b->>'turn') is distinct from p_profile::text then return jsonb_build_object('error', 'not_your_turn'); end if;
  select data->'puzzles'->((b->>'round')::int - 1)->>'text' into txt from public.pm_pir_secrets where show_id = p_show;
  used := coalesce(b->>'used', ''); secs := coalesce((b->>'turn_secs')::int, 25);
  select round_score into rs from public.pm_pir_players where show_id = p_show and profile_id = p_profile for update;
  L := upper(left(btrim(coalesce(p_arg, '')), 1));
  if p_action = 'spin' then
    if b->>'sub' <> 'spin' then return jsonb_build_object('error', 'call_letter'); end if;
    if translate(regexp_replace(txt, '[^B-DF-HJ-NP-TV-Z]', '', 'g'), used, '') = '' then return jsonb_build_object('error', 'no_consonants'); end if;
    w := floor(random() * 24)::int; val := (public.pm_pir_wof_wedges())[w + 1];
    b := b || jsonb_build_object('wedge', w, 'spin_seq', coalesce((b->>'spin_seq')::int, 0) + 1, 'bets_open', false);
    if val = 'BANKRUPT' then rs := 0; ev := 'BANKRUPT!'; kind := 'bad'; nxt := true;
    elsif val = 'LOSE' then ev := 'LOSE A TURN'; kind := 'bad'; nxt := true;
    else b := b || jsonb_build_object('sub', 'call', 'value', val::int, 'turn_until', now() + make_interval(secs => secs)); ev := '$' || val; kind := 'spin';
    end if;
  elsif p_action = 'letter' then
    if b->>'sub' <> 'call' then return jsonb_build_object('error', 'spin_first'); end if;
    if L !~ '^[A-Z]$' then return jsonb_build_object('error', 'bad_letter'); end if;
    if L in ('A','E','I','O','U') then return jsonb_build_object('error', 'buy_vowels'); end if;
    if position(L in used) > 0 then return jsonb_build_object('error', 'used_letter'); end if;
    n := length(txt) - length(replace(txt, L, '')); used := used || L;
    if n > 0 then
      rs := rs + (b->>'value')::int * n; ev := n || ' ' || L || case when n > 1 then '''S' else '' end; kind := 'good';
      b := b || jsonb_build_object('sub', 'spin', 'value', null, 'turn_until', now() + make_interval(secs => secs));
    else ev := 'NO ' || L; kind := 'bad'; nxt := true; end if;
  elsif p_action = 'buy' then
    if b->>'sub' <> 'spin' then return jsonb_build_object('error', 'call_letter'); end if;
    if L not in ('A','E','I','O','U') then return jsonb_build_object('error', 'not_vowel'); end if;
    if position(L in used) > 0 then return jsonb_build_object('error', 'used_letter'); end if;
    if rs < 250 then return jsonb_build_object('error', 'cant_afford'); end if;
    rs := rs - 250; n := length(txt) - length(replace(txt, L, '')); used := used || L;
    if n > 0 then ev := n || ' ' || L || case when n > 1 then '''S' else '' end; kind := 'good';
      b := b || jsonb_build_object('turn_until', now() + make_interval(secs => secs));
    else ev := 'NO ' || L; kind := 'bad'; nxt := true; end if;
  elsif p_action = 'solve' then
    if regexp_replace(upper(coalesce(p_arg, '')), '[^A-Z0-9]', '', 'g') = regexp_replace(txt, '[^A-Z0-9]', '', 'g') then solved := true;
    else ev := 'WRONG: ' || left(upper(btrim(coalesce(p_arg, ''))), 40); kind := 'bad'; nxt := true; end if;
  else return jsonb_build_object('error', 'bad_action');
  end if;
  mask := public.pm_pir_wof_mask(txt, used);
  if not solved and position('_' in mask) = 0 then solved := true; end if;   -- last letter just went up
  if solved then
    rs := greatest(rs, 1000);   -- the house minimum for solving
    update public.pm_pir_players set stage_score = stage_score + rs, round_score = rs, acted_at = now() where show_id = p_show and profile_id = p_profile;
    mask := txt; ev := 'SOLVED! +$' || rs; kind := 'solve';
    b := b || jsonb_build_object('solved', true, 'sub', null, 'value', null, 'turn_until', null, 'winner', p_profile);
    if (b->>'round')::int >= (b->>'rounds')::int then ph := 'locked'; end if;
  else
    update public.pm_pir_players set round_score = rs, acted_at = now() where show_id = p_show and profile_id = p_profile;
    if nxt then b := public.pm_pir_wof_turn(b); end if;
  end if;
  b := b || jsonb_build_object('used', used, 'mask', mask,
    'ev', jsonb_build_object('seq', coalesce((b->'ev'->>'seq')::int, 0) + 1, 'kind', kind, 'text', ev, 'who', p_profile));
  update public.pm_pir_shows set board = b, phase = ph where id = p_show;
  return jsonb_build_object('event', ev, 'kind', kind);
end $$;

create or replace function public.pm_pir_wof_pass(p_show uuid, p_why text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; b jsonb;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'wof' or s.phase <> 'stage' or coalesce((s.board->>'solved')::boolean, false) then return jsonb_build_object('error', 'round_closed'); end if;
  b := public.pm_pir_wof_turn(s.board);
  b := b || jsonb_build_object('ev', jsonb_build_object('seq', coalesce((s.board->'ev'->>'seq')::int, 0) + 1, 'kind', 'bad',
    'text', case when p_why = 'time' then 'TIME''S UP' else 'PASS' end, 'who', s.board->>'turn'));
  update public.pm_pir_shows set board = b where id = p_show;
  return jsonb_build_object('turn', b->>'turn');
end $$;

create or replace function public.pm_admin_pir_wof_next(p_show uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; r int;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'wof' or s.phase <> 'stage' then raise exception 'Wheel of Fortune is not running'; end if;
  if not coalesce((s.board->>'solved')::boolean, false) then raise exception 'solve this puzzle first'; end if;
  r := (s.board->>'round')::int;
  if r >= (s.board->>'rounds')::int then raise exception 'that was the last puzzle'; end if;
  perform public.pm_pir_wof_load(p_show, r);
  return jsonb_build_object('round', r + 1);
end $$;

-- ── Jeopardy ──
-- host uploads the board (built in the dashboard from Open Trivia DB and/or their own clues)
create or replace function public.pm_admin_pir_jboard(p_show uuid, p_cats jsonb, p_vals jsonb, p_cells jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; nc int; nr int; c int; r int; cell jsonb; used jsonb := '[]'::jsonb; col jsonb; cats jsonb := '[]'::jsonb; vals jsonb := '[]'::jsonb;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'jeopardy' or s.phase not in ('qualifier','closed','results') then raise exception 'set the board before Jeopardy starts'; end if;
  nc := jsonb_array_length(p_cats); nr := jsonb_array_length(p_vals);
  if nc not between 1 and 6 or nr not between 1 and 5 then raise exception 'the board needs 1-6 categories and 1-5 rows'; end if;
  for r in 0..nr - 1 loop
    if coalesce(p_vals->>r, '') !~ '^[0-9]{1,6}$' then raise exception 'row values must be numbers'; end if;
    vals := vals || to_jsonb((p_vals->>r)::int);
  end loop;
  for c in 0..nc - 1 loop
    cats := cats || to_jsonb(left(coalesce(p_cats->>c, ''), 40));
    col := '[]'::jsonb;
    for r in 0..nr - 1 loop
      cell := p_cells->c->r;
      if cell is null or coalesce(btrim(cell->>'q'), '') = '' or jsonb_typeof(cell->'choices') <> 'array' or jsonb_array_length(cell->'choices') <> 4
         or coalesce(cell->>'correct', '') !~ '^[0-3]$' then
        raise exception 'clue % in category % is incomplete', r + 1, c + 1;
      end if;
      col := col || 'false'::jsonb;
    end loop;
    used := used || jsonb_build_array(col);
  end loop;
  insert into public.pm_pir_secrets (show_id, data) values (p_show, jsonb_build_object('cells', p_cells))
  on conflict (show_id) do update set data = public.pm_pir_secrets.data || jsonb_build_object('cells', p_cells);
  update public.pm_pir_shows set board = board || jsonb_build_object('cats', cats, 'vals', vals, 'used', used) where id = p_show;
  return jsonb_build_object('cats', cats, 'vals', vals);
end $$;

-- pick a clue: the player in control (last right answer), or the host (p_profile null). arg = "column value" e.g. "2 300"
create or replace function public.pm_pir_jpick(p_profile uuid, p_show uuid, p_arg text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; b jsonb; parts text[]; c int; r int; v int; cell jsonb; nc int; nr int; i int;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'jeopardy' or s.phase <> 'stage' then return jsonb_build_object('error', 'round_closed'); end if;
  b := s.board;
  if jsonb_typeof(b->'cur') = 'object' and coalesce((b->'cur'->>'open')::boolean, false) then return jsonb_build_object('error', 'clue_open'); end if;
  if p_profile is not null and (b->>'control') is distinct from p_profile::text then return jsonb_build_object('error', 'not_your_pick'); end if;
  parts := array_remove(regexp_split_to_array(btrim(coalesce(p_arg, '')), '[^0-9]+'), '');
  if coalesce(array_length(parts, 1), 0) < 2 or length(parts[1]) > 2 or length(parts[2]) > 7 then return jsonb_build_object('error', 'bad_pick'); end if;
  nc := jsonb_array_length(b->'cats'); nr := jsonb_array_length(b->'vals');
  c := parts[1]::int - 1; v := parts[2]::int; r := null;
  for i in 0..nr - 1 loop if (b->'vals'->>i)::int = v then r := i; exit; end if; end loop;
  if r is null and v between 1 and nr then r := v - 1; end if;
  if c < 0 or c >= nc or r is null then return jsonb_build_object('error', 'bad_pick'); end if;
  if (b->'used'->c->>r)::boolean then return jsonb_build_object('error', 'used'); end if;
  select data->'cells'->c->r into cell from public.pm_pir_secrets where show_id = p_show;
  b := b || jsonb_build_object('cur', jsonb_build_object('c', c, 'r', r, 'q', cell->>'q', 'choices', cell->'choices', 'value', (b->'vals'->>r)::int,
         'open', true, 'correct', null, 'winner', null, 'cat', b->'cats'->>c),
       'seq', coalesce((b->>'seq')::int, 0) + 1, 'answered', '[]'::jsonb, 'wrong', '[]'::jsonb, 'bets_open', false);
  update public.pm_pir_shows set board = b, closes_at = now() + make_interval(secs => coalesce((b->>'secs')::int, 15)) where id = p_show;
  return jsonb_build_object('c', c, 'r', r);
end $$;

-- close the clue on the board: reveal the answer, mark it used, give control to the winner
create or replace function public.pm_pir_jend(p_show uuid, p_b jsonb, p_winner uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cur jsonb := p_b->'cur'; b jsonb; right_i int; left_n int;
begin
  select (data->'cells'->((cur->>'c')::int)->((cur->>'r')::int)->>'correct')::int into right_i from public.pm_pir_secrets where show_id = p_show;
  b := jsonb_set(p_b, array['used', cur->>'c', cur->>'r'], 'true'::jsonb);
  b := b || jsonb_build_object('cur', cur || jsonb_build_object('open', false, 'correct', right_i, 'winner', p_winner));
  if p_winner is not null then b := b || jsonb_build_object('control', p_winner); end if;
  select count(*) into left_n from jsonb_array_elements(b->'used') col, jsonb_array_elements(col) x where x = 'false'::jsonb;
  update public.pm_pir_shows set board = b, closes_at = null, phase = case when left_n = 0 then 'locked' else phase end where id = p_show;
  return b;
end $$;

-- answer A-D: first right answer takes the value and control; a wrong answer costs the value and locks you out of this clue
create or replace function public.pm_pir_janswer(p_profile uuid, p_show uuid, p_arg text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; b jsonb; cur jsonb; t text := upper(btrim(coalesce(p_arg, ''))); ch int; right_i int; v int; n_pl int;
begin
  select * into s from public.pm_pir_shows where id = p_show for update;
  b := s.board; cur := b->'cur';
  if jsonb_typeof(cur) <> 'object' or not coalesce((cur->>'open')::boolean, false) or now() > s.closes_at + interval '1 second' then
    return jsonb_build_object('error', 'round_closed');
  end if;
  ch := case when t ~ '^[A-D]$' then ascii(t) - 65 when t ~ '^[1-4]$' then t::int - 1 end;
  if ch is null then return jsonb_build_object('error', 'bad_choice'); end if;
  if (b->'answered') ? p_profile::text then return jsonb_build_object('error', 'already'); end if;
  select (data->'cells'->((cur->>'c')::int)->((cur->>'r')::int)->>'correct')::int into right_i from public.pm_pir_secrets where show_id = p_show;
  v := (cur->>'value')::int;
  b := jsonb_set(b, '{answered}', (b->'answered') || to_jsonb(p_profile::text));
  if ch = right_i then
    update public.pm_pir_players set stage_score = stage_score + v, acted_at = now() where show_id = p_show and profile_id = p_profile;
    perform public.pm_pir_jend(p_show, b, p_profile);
    return jsonb_build_object('result', 'right', 'value', v);
  end if;
  update public.pm_pir_players set stage_score = stage_score - v, acted_at = now() where show_id = p_show and profile_id = p_profile;
  b := jsonb_set(b, '{wrong}', (b->'wrong') || to_jsonb(p_profile::text));
  select count(*) into n_pl from public.pm_pir_players where show_id = p_show and qualified;
  if jsonb_array_length(b->'answered') >= n_pl then perform public.pm_pir_jend(p_show, b, null);
  else update public.pm_pir_shows set board = b where id = p_show; end if;
  return jsonb_build_object('result', 'wrong', 'value', v);
end $$;

create or replace function public.pm_admin_pir_jclose(p_show uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage <> 'jeopardy' or jsonb_typeof(s.board->'cur') <> 'object' or not coalesce((s.board->'cur'->>'open')::boolean, false) then
    return jsonb_build_object('error', 'no_clue');
  end if;
  return public.pm_pir_jend(p_show, s.board, null)->'cur';
end $$;

-- ── one entry point for every new-stage move (site, chat via the dashboard, or the host acting for someone) ──
create or replace function public.pm_pir_play_as(p_profile uuid, p_show uuid, p_action text, p_arg text, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; r text;
begin
  select * into s from public.pm_pir_shows where id = p_show;
  if not found or s.phase <> 'stage' then return jsonb_build_object('error', 'round_closed'); end if;
  if not exists (select 1 from public.pm_pir_players where show_id = p_show and profile_id = p_profile and qualified) then
    r := public.pm_pir_late_as(p_profile, p_show, p_via);
    if r is not null then return jsonb_build_object('error', case when r = 'round_closed' then 'not_finalist' else r end); end if;
  end if;
  if s.stage = 'plinko' and p_action = 'drop' then
    return public.pm_pir_drop(p_profile, p_show, nullif(left(regexp_replace(coalesce(p_arg, ''), '[^0-9]', '', 'g'), 2), '')::int);
  elsif s.stage = 'cliff' and p_action = 'guess' then return public.pm_pir_cliff_guess(p_profile, p_show, p_arg);
  elsif s.stage = 'wof' and p_action in ('spin','letter','buy','solve') then return public.pm_pir_wof_act(p_profile, p_show, p_action, p_arg);
  elsif s.stage = 'jeopardy' and p_action = 'pick' then return public.pm_pir_jpick(p_profile, p_show, p_arg);
  elsif s.stage = 'jeopardy' and p_action = 'answer' then return public.pm_pir_janswer(p_profile, p_show, p_arg);
  end if;
  return jsonb_build_object('error', 'bad_action');
end $$;

create or replace function public.pm_pir_play(p_show uuid, p_action text, p_arg text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pid uuid := public.pm_my_profile();
begin
  if pid is null then return jsonb_build_object('error', 'no_profile'); end if;
  return public.pm_pir_play_as(pid, p_show, p_action, p_arg, 'app');
end $$;

-- host acts: pick a Jeopardy clue, pass a Wheel of Fortune turn, or move for a player (p_profile null = whoever's turn it is)
create or replace function public.pm_admin_pir_play(p_show uuid, p_profile uuid, p_action text, p_arg text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; pid uuid := p_profile;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show;
  if not found then return jsonb_build_object('error', 'round_closed'); end if;
  if p_action = 'pick' then return public.pm_pir_jpick(null, p_show, p_arg); end if;
  if p_action in ('pass','timeout') then return public.pm_pir_wof_pass(p_show, case when p_action = 'timeout' then 'time' else 'pass' end); end if;
  if pid is null and s.stage = 'wof' then pid := (s.board->>'turn')::uuid; end if;
  if pid is null then return jsonb_build_object('error', 'no_player'); end if;
  return public.pm_pir_play_as(pid, p_show, p_action, p_arg, 'host');
end $$;

-- finish Plinko / Cliff Hangers / Wheel of Fortune / Jeopardy and pay
create or replace function public.pm_admin_pir_finish(p_show uuid, p_bonus int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.pm_pir_shows; best int; ws uuid[]; n int; each int; rem int; i int := 0; e record; amt int; bets jsonb; lbl text;
begin
  perform public.pm_require_admin();
  select * into s from public.pm_pir_shows where id = p_show for update;
  if not found or s.stage not in ('plinko','cliff','wof','jeopardy') or s.phase not in ('stage','locked') then raise exception 'that game is not running'; end if;
  update public.pm_pir_shows set phase = 'done', ended_at = now(), closes_at = null where id = p_show;
  lbl := case s.stage when 'plinko' then 'Plinko' when 'cliff' then 'Cliff Hangers' when 'wof' then 'Wheel of Fortune' else 'Jeopardy' end;
  if s.stage = 'plinko' then
    -- everyone keeps what their chips landed on
    for e in select profile_id, stage_score from public.pm_pir_players where show_id = p_show and qualified and stage_score > 0 loop
      insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (e.profile_id, e.stage_score, 'The Picks Are Right: Plinko', 'pir', 'pir');
      update public.pm_pir_players set payout = e.stage_score where show_id = p_show and profile_id = e.profile_id;
      perform public.pm_log(e.profile_id, 'pir_won', jsonb_build_object('payout', e.stage_score, 'stage', 'plinko'), s.session_id);
    end loop;
    select max(stage_score) into best from public.pm_pir_players where show_id = p_show and qualified;
    if best <= 0 then best := null; end if;
    select array_agg(profile_id) into ws from public.pm_pir_players where show_id = p_show and qualified and stage_score = best;
  else
    if s.stage = 'cliff' then
      select min(stage_score) into best from public.pm_pir_players where show_id = p_show and qualified and not out;
      select array_agg(profile_id) into ws from public.pm_pir_players where show_id = p_show and qualified and not out and stage_score = best;
    else
      select max(stage_score) into best from public.pm_pir_players where show_id = p_show and qualified;
      if best <= 0 then best := null; end if;
      select array_agg(profile_id) into ws from public.pm_pir_players where show_id = p_show and qualified and stage_score = best;
    end if;
    n := coalesce(array_length(ws, 1), 0);
    if n > 0 then
      each := s.prize / n; rem := s.prize % n;
      for e in select profile_id from public.pm_pir_players where show_id = p_show and profile_id = any(ws) order by rank loop
        amt := each + case when i < rem then 1 else 0 end + case when s.stage = 'cliff' and best = 0 then coalesce(p_bonus, 0) else 0 end;
        i := i + 1;
        if amt > 0 then
          insert into public.pm_ledger (profile_id, delta, reason, game, actor) values (e.profile_id, amt, 'The Picks Are Right: won ' || lbl, 'pir', 'pir');
        end if;
        update public.pm_pir_players set payout = amt where show_id = p_show and profile_id = e.profile_id;
        perform public.pm_log(e.profile_id, 'pir_won', jsonb_build_object('payout', amt, 'stage', s.stage, 'score', best), s.session_id);
      end loop;
    end if;
  end if;
  bets := public.pm_pir_pay_bets(p_show, coalesce(ws, array[]::uuid[]));
  return jsonb_build_object('best', best, 'winners', to_jsonb(coalesce(ws, array[]::uuid[])), 'bets', bets);
end $$;

-- ── 6. Row level security ───────────────────────────────────
alter table public.pm_profiles     enable row level security;
alter table public.pm_sessions     enable row level security;
alter table public.pm_participants enable row level security;
alter table public.pm_access       enable row level security;
alter table public.pm_questions    enable row level security;
alter table public.pm_rounds       enable row level security;
alter table public.pm_answers      enable row level security;
alter table public.pm_ledger       enable row level security;
alter table public.pm_events       enable row level security;
alter table public.pm_state        enable row level security;
alter table public.pm_bank         enable row level security;
alter table public.pm_blocklist    enable row level security;
alter table public.pm_trivia_games     enable row level security;
alter table public.pm_trivia_entries   enable row level security;
alter table public.pm_trivia_questions enable row level security;
alter table public.pm_trivia_answers   enable row level security;
alter table public.pm_shop_items       enable row level security;
alter table public.pm_inventory        enable row level security;
alter table public.pm_pir_shows        enable row level security;
alter table public.pm_pir_players      enable row level security;
alter table public.pm_pir_moves        enable row level security;
alter table public.pm_pir_bets         enable row level security;
alter table public.pm_pir_secrets      enable row level security;
alter table public.pm_pir_bank         enable row level security;

do $$
declare t text;
begin
  -- drop old policies so re-runs are clean
  for t in select format('drop policy if exists %I on %I.%I', policyname, schemaname, tablename)
             from pg_policies where schemaname = 'public' and tablename like 'pm\_%' loop
    execute t;
  end loop;
end $$;

-- public reads
create policy "pm read profiles"     on public.pm_profiles     for select using (true);
create policy "pm read sessions"     on public.pm_sessions     for select using (true);
create policy "pm read participants" on public.pm_participants for select using (true);
create policy "pm read rounds"       on public.pm_rounds       for select using (true);
create policy "pm read answers"      on public.pm_answers      for select using (true);
create policy "pm read state"        on public.pm_state        for select using (true);
-- own rows or host
create policy "pm read ledger"    on public.pm_ledger    for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm read events"    on public.pm_events    for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm read questions" on public.pm_questions for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm read access"    on public.pm_access    for select using (public.pm_is_admin());
-- host writes
create policy "pm host sessions"     on public.pm_sessions     for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm host participants" on public.pm_participants for delete to authenticated using (public.pm_is_admin());
create policy "pm host access"       on public.pm_access       for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm host questions"    on public.pm_questions    for update to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm host questions d"  on public.pm_questions    for delete to authenticated using (public.pm_is_admin());
create policy "pm host rounds"       on public.pm_rounds       for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm host answers d"    on public.pm_answers      for delete to authenticated using (public.pm_is_admin());
create policy "pm host state"        on public.pm_state        for update to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm read trivia games"     on public.pm_trivia_games     for select using (true);
create policy "pm read trivia entries"   on public.pm_trivia_entries   for select using (true);
create policy "pm read trivia questions" on public.pm_trivia_questions for select using (true);
create policy "pm read trivia answers"   on public.pm_trivia_answers   for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm read shop"             on public.pm_shop_items       for select using (active or public.pm_is_admin());
create policy "pm host shop"             on public.pm_shop_items       for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm read inventory"        on public.pm_inventory        for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm read pir shows"   on public.pm_pir_shows   for select using (true);
create policy "pm read pir players" on public.pm_pir_players for select using (true);
create policy "pm read pir moves"   on public.pm_pir_moves   for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm read pir bets"    on public.pm_pir_bets    for select using (public.pm_is_admin() or profile_id = public.pm_my_profile());
create policy "pm host pir secrets" on public.pm_pir_secrets for select to authenticated using (public.pm_is_admin());
create policy "pm host pir bank"    on public.pm_pir_bank    for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm host blocklist"    on public.pm_blocklist    for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());
create policy "pm host bank"         on public.pm_bank         for all to authenticated using (public.pm_is_admin()) with check (public.pm_is_admin());

-- ── 7. Grants ───────────────────────────────────────────────
grant select on public.pm_profiles, public.pm_sessions, public.pm_participants, public.pm_rounds,
                public.pm_answers, public.pm_state to anon, authenticated;
grant select on public.pm_ledger, public.pm_events, public.pm_questions, public.pm_access to authenticated;
grant insert, update, delete on public.pm_sessions, public.pm_access, public.pm_rounds to authenticated;
grant update, delete on public.pm_questions to authenticated;
grant delete on public.pm_participants, public.pm_answers to authenticated;
grant update on public.pm_state to authenticated;
grant select, insert, update, delete on public.pm_bank to authenticated;
grant select, insert, update, delete on public.pm_blocklist to authenticated;
grant select on public.pm_trivia_games, public.pm_trivia_entries, public.pm_trivia_questions, public.pm_shop_items to anon, authenticated;
grant select on public.pm_trivia_answers, public.pm_inventory to authenticated;
grant insert, update, delete on public.pm_shop_items to authenticated;
grant select on public.pm_pir_shows, public.pm_pir_players to anon, authenticated;
grant select on public.pm_pir_moves, public.pm_pir_bets to authenticated;
revoke all on public.pm_pir_secrets from anon, authenticated;
grant select on public.pm_pir_secrets to authenticated;
revoke all on public.pm_pir_bank from anon;
grant select, insert, update, delete on public.pm_pir_bank to authenticated;
grant usage on sequence public.pm_pir_bank_id_seq to authenticated;

-- internal helpers: nobody calls these directly
revoke execute on function public.pm_log(uuid, text, jsonb, uuid)          from public, anon, authenticated;
revoke execute on function public.pm_check(uuid, uuid, text)                from public, anon, authenticated;
revoke execute on function public.pm_enter(uuid, uuid, text, text)          from public, anon, authenticated;
revoke execute on function public.pm_answer_as(uuid, uuid, text, text)      from public, anon, authenticated;
revoke execute on function public.pm_question_as(uuid, text, text)          from public, anon, authenticated;
revoke execute on function public.pm_ledger_apply()                         from public, anon, authenticated;
revoke execute on function public.pm_filtered(text)                         from public, anon, authenticated;
revoke execute on function public.pm_trivia_enter(uuid, uuid, text)           from public, anon, authenticated;
revoke execute on function public.pm_trivia_answer_as(uuid, uuid, int, int)   from public, anon, authenticated;
revoke execute on function public.pm_access_log()                           from public, anon, authenticated;
-- callable by anyone signed in (each checks who you are)
grant execute on function public.pm_now()                    to anon, authenticated;
grant execute on function public.pm_is_admin()               to anon, authenticated;
grant execute on function public.pm_my_profile()             to authenticated;
grant execute on function public.pm_ensure_profile()         to authenticated;
grant execute on function public.pm_join(uuid)               to authenticated;
grant execute on function public.pm_submit_answer(uuid, text) to authenticated;
grant execute on function public.pm_submit_question(text)    to authenticated;
grant execute on function public.pm_send_picks(uuid, int, text) to authenticated;
revoke execute on function public.pm_send_picks(uuid, int, text) from public, anon;
grant execute on function public.pm_trivia_join(uuid)                 to authenticated;
grant execute on function public.pm_trivia_answer(uuid, int, int)     to authenticated;
grant execute on function public.pm_trivia_progress(uuid, int)        to anon, authenticated;
grant execute on function public.pm_shop_buy(text)                    to authenticated;
grant execute on function public.pm_shop_equip(text, text)            to authenticated;
revoke execute on function public.pm_trivia_join(uuid)                from public, anon;
revoke execute on function public.pm_trivia_answer(uuid, int, int)    from public, anon;
revoke execute on function public.pm_shop_buy(text)                   from public, anon;
revoke execute on function public.pm_shop_equip(text, text)           from public, anon;
grant execute on function public.pm_admin_trivia_create(uuid, int, int, int, boolean, text) to authenticated;
grant execute on function public.pm_admin_trivia_chat_join(uuid, text, text, text)        to authenticated;
grant execute on function public.pm_admin_trivia_chat_answer(uuid, int, text, int)        to authenticated;
grant execute on function public.pm_admin_trivia_ask(uuid, int, text, jsonb, int)         to authenticated;
grant execute on function public.pm_admin_trivia_close(uuid, int)                         to authenticated;
grant execute on function public.pm_admin_trivia_reveal(uuid, int, int)                   to authenticated;
grant execute on function public.pm_admin_trivia_finish(uuid)                             to authenticated;
grant execute on function public.pm_admin_trivia_cancel(uuid)                             to authenticated;
grant execute on function public.pm_admin_give_item(uuid, text)                           to authenticated;
revoke execute on function public.pm_admin_trivia_create(uuid, int, int, int, boolean, text) from public, anon;
revoke execute on function public.pm_admin_trivia_chat_join(uuid, text, text, text)        from public, anon;
revoke execute on function public.pm_admin_trivia_chat_answer(uuid, int, text, int)        from public, anon;
revoke execute on function public.pm_admin_trivia_ask(uuid, int, text, jsonb, int)         from public, anon;
revoke execute on function public.pm_admin_trivia_close(uuid, int)                         from public, anon;
revoke execute on function public.pm_admin_trivia_reveal(uuid, int, int)                   from public, anon;
revoke execute on function public.pm_admin_trivia_finish(uuid)                             from public, anon;
revoke execute on function public.pm_admin_trivia_cancel(uuid)                             from public, anon;
revoke execute on function public.pm_admin_give_item(uuid, text)                           from public, anon;
-- The Picks Are Right
revoke execute on function public.pm_pir_words(text, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_problem(uuid, uuid, int) from public, anon, authenticated;
revoke execute on function public.pm_pir_enter(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_open(uuid) from public, anon, authenticated;
revoke execute on function public.pm_pir_type_as(uuid, uuid, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_give_as(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_join_as(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_bid_as(uuid, uuid, int) from public, anon, authenticated;
revoke execute on function public.pm_pir_bet_as(uuid, uuid, uuid, int) from public, anon, authenticated;
revoke execute on function public.pm_pir_wheel_as(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_pay_bets(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.pm_pir_join(uuid) to authenticated;
revoke execute on function public.pm_pir_join(uuid) from public, anon;
grant execute on function public.pm_pir_type(uuid, text) to authenticated;
revoke execute on function public.pm_pir_type(uuid, text) from public, anon;
grant execute on function public.pm_pir_give(uuid, uuid) to authenticated;
revoke execute on function public.pm_pir_give(uuid, uuid) from public, anon;
grant execute on function public.pm_pir_math_next(uuid) to authenticated;
revoke execute on function public.pm_pir_math_next(uuid) from public, anon;
grant execute on function public.pm_pir_math_answer(uuid, int, int) to authenticated;
revoke execute on function public.pm_pir_math_answer(uuid, int, int) from public, anon;
grant execute on function public.pm_pir_lock(uuid) to authenticated;
revoke execute on function public.pm_pir_lock(uuid) from public, anon;
grant execute on function public.pm_pir_bid(uuid, int) to authenticated;
revoke execute on function public.pm_pir_bid(uuid, int) from public, anon;
grant execute on function public.pm_pir_bet(uuid, uuid, int) to authenticated;
revoke execute on function public.pm_pir_bet(uuid, uuid, int) from public, anon;
grant execute on function public.pm_pir_wheel(uuid, text) to authenticated;
revoke execute on function public.pm_pir_wheel(uuid, text) from public, anon;
grant execute on function public.pm_admin_pir_create(uuid, text, text, int, int, int, int, text, int) to authenticated;
revoke execute on function public.pm_admin_pir_create(uuid, text, text, int, int, int, int, text, int) from public, anon;
grant execute on function public.pm_admin_pir_timer(uuid, int) to authenticated;
revoke execute on function public.pm_admin_pir_timer(uuid, int) from public, anon;
grant execute on function public.pm_admin_pir_chat(uuid, text, text, text, text, text) to authenticated;
revoke execute on function public.pm_admin_pir_chat(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.pm_admin_pir_chat_bet(uuid, text, text, text, text, int) to authenticated;
revoke execute on function public.pm_admin_pir_chat_bet(uuid, text, text, text, text, int) from public, anon;
grant execute on function public.pm_admin_pir_close(uuid) to authenticated;
revoke execute on function public.pm_admin_pir_close(uuid) from public, anon;
grant execute on function public.pm_admin_pir_stage(uuid, text) to authenticated;
revoke execute on function public.pm_admin_pir_stage(uuid, text) from public, anon;
grant execute on function public.pm_admin_pir_lock(uuid) to authenticated;
revoke execute on function public.pm_admin_pir_lock(uuid) from public, anon;
grant execute on function public.pm_admin_pir_wheel(uuid, text) to authenticated;
revoke execute on function public.pm_admin_pir_wheel(uuid, text) from public, anon;
grant execute on function public.pm_admin_pir_reveal(uuid, int, int) to authenticated;
revoke execute on function public.pm_admin_pir_reveal(uuid, int, int) from public, anon;
grant execute on function public.pm_admin_pir_wheel_finish(uuid, int) to authenticated;
revoke execute on function public.pm_admin_pir_wheel_finish(uuid, int) from public, anon;
grant execute on function public.pm_admin_pir_cancel(uuid) to authenticated;
revoke execute on function public.pm_admin_pir_cancel(uuid) from public, anon;
grant execute on function public.pm_pir_progress(uuid) to anon, authenticated;
-- finals games
revoke execute on function public.pm_pir_late_as(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_drop(uuid, uuid, int) from public, anon, authenticated;
revoke execute on function public.pm_pir_cliff_guess(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_wof_turn(jsonb) from public, anon, authenticated;
revoke execute on function public.pm_pir_wof_load(uuid, int) from public, anon, authenticated;
revoke execute on function public.pm_pir_wof_act(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_wof_pass(uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_jpick(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_jend(uuid, jsonb, uuid) from public, anon, authenticated;
revoke execute on function public.pm_pir_janswer(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_play_as(uuid, uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.pm_pir_wof_mask(text, text) from public, anon, authenticated;
grant execute on function public.pm_pir_play(uuid, text, text) to authenticated;
revoke execute on function public.pm_pir_play(uuid, text, text) from public, anon;
grant execute on function public.pm_admin_pir_begin(uuid, text, jsonb) to authenticated;
revoke execute on function public.pm_admin_pir_begin(uuid, text, jsonb) from public, anon;
grant execute on function public.pm_admin_pir_cliff_ask(uuid, int) to authenticated;
revoke execute on function public.pm_admin_pir_cliff_ask(uuid, int) from public, anon;
grant execute on function public.pm_admin_pir_cliff_settle(uuid) to authenticated;
revoke execute on function public.pm_admin_pir_cliff_settle(uuid) from public, anon;
grant execute on function public.pm_admin_pir_wof_next(uuid) to authenticated;
revoke execute on function public.pm_admin_pir_wof_next(uuid) from public, anon;
grant execute on function public.pm_admin_pir_jboard(uuid, jsonb, jsonb, jsonb) to authenticated;
revoke execute on function public.pm_admin_pir_jboard(uuid, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.pm_admin_pir_jclose(uuid) to authenticated;
revoke execute on function public.pm_admin_pir_jclose(uuid) from public, anon;
grant execute on function public.pm_admin_pir_play(uuid, uuid, text, text) to authenticated;
revoke execute on function public.pm_admin_pir_play(uuid, uuid, text, text) from public, anon;
grant execute on function public.pm_admin_pir_finish(uuid, int) to authenticated;
revoke execute on function public.pm_admin_pir_finish(uuid, int) from public, anon;
grant execute on function public.pm_admin_chatter(text, text, text)                    to authenticated;
grant execute on function public.pm_admin_chat_answer(uuid, text, text, text, text)    to authenticated;
grant execute on function public.pm_admin_chat_question(text, text, text, text)        to authenticated;
grant execute on function public.pm_admin_adjust(uuid, int, text)                      to authenticated;
grant execute on function public.pm_admin_tag_answers(uuid, jsonb)                     to authenticated;
grant execute on function public.pm_admin_award_tile(uuid, text, int, text)            to authenticated;
revoke execute on function public.pm_admin_chatter(text, text, text)                   from public, anon;
revoke execute on function public.pm_admin_chat_answer(uuid, text, text, text, text)   from public, anon;
revoke execute on function public.pm_admin_chat_question(text, text, text, text)       from public, anon;
revoke execute on function public.pm_admin_adjust(uuid, int, text)                     from public, anon;
revoke execute on function public.pm_admin_tag_answers(uuid, jsonb)                    from public, anon;
revoke execute on function public.pm_admin_award_tile(uuid, text, int, text)           from public, anon;

-- ── 8. Realtime (pages also poll, so this is a speed-up) ───
do $$
begin
  alter publication supabase_realtime add table public.pm_state;
exception when duplicate_object then null; when undefined_object then null;
end $$;

-- ── 9. Survey question bank (151 starters; add more from the dashboard) ──
insert into public.pm_bank (text) values
  ('Name something you''d find in a streamer''s fridge at 3 AM.'),
  ('Name a reason you''d leave a Twitch stream.'),
  ('Name something people yell at their TV.'),
  ('Name a snack that hits different at 2 AM.'),
  ('Name something guitarists are weirdly protective of.'),
  ('Name an excuse for being late to work.'),
  ('Name something that ruins a camping trip.'),
  ('Name a word every gamer has typed in all caps.'),
  ('Name something you always forget to pack.'),
  ('Name a fast food item worth the drive.'),
  ('Name something you hide before guests come over.'),
  ('Name a video game everyone has played at least once.'),
  ('Name something that''s always in the junk drawer.'),
  ('Name something that got way too expensive.'),
  ('Name a sound that instantly wakes you up.'),
  ('Name a reason to call IT support.'),
  ('Name something people do instead of sleeping.'),
  ('Name an animal you do NOT want in your tent.'),
  ('Name a thing you say when you lose a game.'),
  ('Name something you''d bring to a desert island (not food).'),
  ('Name a pizza topping that starts arguments.'),
  ('Name a superpower that would be useless in real life.'),
  ('Name something you''d find under the couch cushions.'),
  ('Name the worst thing to hear from your dentist.'),
  ('Name a reason your Wi-Fi is slow.'),
  ('Name a job you''d be terrible at.'),
  ('Name something people lie about on dating apps.'),
  ('Name a drink that makes you feel like the main character.'),
  ('Name a chore everyone puts off.'),
  ('Name something a streamer says way too often.'),
  ('Name something you''d grab first in a fire.'),
  ('Name a breakfast food you could eat for dinner.'),
  ('Name a smell that takes you back to childhood.'),
  ('Name something you should never microwave.'),
  ('Name a cereal mascot.'),
  ('Name something people collect.'),
  ('Name a reason to cancel plans.'),
  ('Name a board game that ruins friendships.'),
  ('Name something you do the second you get home.'),
  ('Name an instrument people quit after one week.'),
  ('Name a band everyone has a hot take about.'),
  ('Name something you''d see at a music festival.'),
  ('Name a song you know every word to.'),
  ('Name the first thing you''d buy if you won the lottery.'),
  ('Name something that''s always sticky.'),
  ('Name a reason to get out of bed in the morning.'),
  ('Name something that''s better cold.'),
  ('Name something you''d find in a gamer''s room.'),
  ('Name a phrase your parents always said.'),
  ('Name a thing people forget to charge.'),
  ('Name a food that''s better the next day.'),
  ('Name something you''d never say on a first date.'),
  ('Name a place you''d hide during a zombie apocalypse.'),
  ('Name something that''s overrated.'),
  ('Name a famous duo.'),
  ('Name a holiday food.'),
  ('Name something you''d find at a gas station.'),
  ('Name a reason someone might be wearing sunglasses indoors.'),
  ('Name a thing that''s hard to do quietly.'),
  ('Name a vegetable kids hate.'),
  ('Name something you''d never lend to a friend.'),
  ('Name an app you''d delete if you had to pick one.'),
  ('Name a reason to call your mom.'),
  ('Name something that''s always lost in the house.'),
  ('Name a word you can''t spell without autocorrect.'),
  ('Name something people do in the car while stuck in traffic.'),
  ('Name a movie everyone quotes.'),
  ('Name a sport you''d be worst at.'),
  ('Name a costume that''s easy to throw together last minute.'),
  ('Name something you''d see in a haunted house.'),
  ('Name a sound a cat makes when it''s mad.'),
  ('Name a reason to stay up all night.'),
  ('Name a thing that''s annoying about online games.'),
  ('Name something you''d hate to step on barefoot.'),
  ('Name a drink at a coffee shop.'),
  ('Name something people buy at the grocery store and never use.'),
  ('Name a candy everyone fights over.'),
  ('Name something that has buttons.'),
  ('Name a karaoke song.'),
  ('Name something that comes in a pair.'),
  ('Name a thing that happens on a long road trip.'),
  ('Name something you''d find in a dentist''s waiting room.'),
  ('Name a way to fall asleep faster.'),
  ('Name a reason a stream might go offline.'),
  ('Name a pet name for a significant other.'),
  ('Name something that gets lost in the laundry.'),
  ('Name a fruit that''s a pain to eat.'),
  ('Name something with a lot of buttons that you never use.'),
  ('Name a reason to wear a hat.'),
  ('Name something people do at a wedding reception.'),
  ('Name a thing you''d see at a garage sale.'),
  ('Name a famous wizard.'),
  ('Name something you''d hear at a hockey game.'),
  ('Name a job that requires a uniform.'),
  ('Name something you''d put on a hot dog.'),
  ('Name a thing you''d do with a time machine.'),
  ('Name something you''d find in a toolbox.'),
  ('Name a thing that''s always in a hotel room.'),
  ('Name a reason you might get kicked out of a library.'),
  ('Name a thing everyone pretends to understand.'),
  ('Name a dance move.'),
  ('Name something you''d never want to run out of.'),
  ('Name something you see at the beach.'),
  ('Name a reason to buy a new phone.'),
  ('Name a food you can eat with your hands.'),
  ('Name something on your nightstand.'),
  ('Name a thing people do when nobody''s watching.'),
  ('Name a word that describes Mondays.'),
  ('Name a famous Mario character.'),
  ('Name a thing that makes a great gift.'),
  ('Name something people bring to a potluck.'),
  ('Name a thing you''d find in the woods.'),
  ('Name a rule you broke as a kid.'),
  ('Name something with wheels.'),
  ('Name an emoji people overuse.'),
  ('Name a thing you''d need on a camping trip.'),
  ('Name a reason someone might cry at a movie.'),
  ('Name a thing you''d find in an office.'),
  ('Name a classic road trip snack.'),
  ('Name a sound effect in a cartoon.'),
  ('Name a reason to go to the hospital at 2 AM.'),
  ('Name a thing people complain about at work.'),
  ('Name something that''s red.'),
  ('Name a sandwich.'),
  ('Name a fear people have.'),
  ('Name a famous painting.'),
  ('Name a thing that''s hard to find in the dark.'),
  ('Name something you use every day but never think about.'),
  ('Name a type of shoe.'),
  ('Name a pizza chain.'),
  ('Name a famous dog.'),
  ('Name a thing you''d say to a baby.'),
  ('Name a guilty pleasure TV show.'),
  ('Name something people forget at the airport.'),
  ('Name a reason to wake up early on a Saturday.'),
  ('Name an animal that would make a terrible pet.'),
  ('Name a thing you''d find in a magician''s hat.'),
  ('Name something that''s always too loud.'),
  ('Name a type of weather you hate.'),
  ('Name a thing that''s fun to pop.'),
  ('Name a soda flavor.'),
  ('Name something people do on their phone in the bathroom.'),
  ('Name a famous cartoon cat.'),
  ('Name a word you''d use to describe a great guitar solo.'),
  ('Name something you''d hear in a movie theater.'),
  ('Name a reason to go to the mall.'),
  ('Name something people put in their coffee.'),
  ('Name a gift you''d regift.'),
  ('Name a thing you can''t live without.'),
  ('Name a thing you''d never want to hear your pilot say.'),
  ('Name a game you''d play at a sleepover.')
on conflict (text) do nothing;

-- ── 10. Pick Shop starter items (edit/add more from the dashboard) ──
insert into public.pm_shop_items (id, kind, name, price, data, sort) values
  ('nc_lime','namecolor','Portal Lime',25,'{"color":"#b8ff2e"}'::jsonb,10),
  ('nc_cyan','namecolor','Chat Cyan',25,'{"color":"#34e2ff"}'::jsonb,11),
  ('nc_pink','namecolor','Bubblegum',25,'{"color":"#ff6ad5"}'::jsonb,12),
  ('nc_gold','namecolor','Gold Record',40,'{"color":"#ffcf4a"}'::jsonb,13),
  ('nc_ember','namecolor','Ember',40,'{"color":"#ff7a3d"}'::jsonb,14),
  ('nc_sunset','namecolor','Sunset Fade',75,'{"grad":["#ff6ad5","#ffbe3d"]}'::jsonb,20),
  ('nc_portal','namecolor','Portal Fade',75,'{"grad":["#b8ff2e","#34e2ff"]}'::jsonb,21),
  ('nc_nebula','namecolor','Nebula Fade',75,'{"grad":["#b691ff","#ff6ad5"]}'::jsonb,22),
  ('nc_prism','namecolor','Prism (animated)',200,'{"grad":["#ff3d5a","#ffbe3d","#b8ff2e","#34e2ff","#b691ff"],"anim":true}'::jsonb,30),
  ('bd_ghost','badge','Lurker',25,'{"icon":"👻","title":"Lurker"}'::jsonb,10),
  ('bd_pizza','badge','Snack Captain',30,'{"icon":"🍕","title":"Snack Captain"}'::jsonb,11),
  ('bd_riff','badge','Riff Lord',50,'{"icon":"🎸","title":"Riff Lord"}'::jsonb,12),
  ('bd_fire','badge','On Fire',50,'{"icon":"🔥","title":"On Fire"}'::jsonb,13),
  ('bd_rocket','badge','Space Cadet',50,'{"icon":"🚀","title":"Space Cadet"}'::jsonb,14),
  ('bd_skull','badge','Chaos Agent',60,'{"icon":"💀","title":"Chaos Agent"}'::jsonb,15),
  ('bd_brain','badge','Big Brain',75,'{"icon":"🧠","title":"Big Brain"}'::jsonb,16),
  ('bd_target','badge','Hivemind',75,'{"icon":"🎯","title":"Hivemind"}'::jsonb,17),
  ('bd_bolt','badge','Speed Demon',75,'{"icon":"⚡","title":"Speed Demon"}'::jsonb,18),
  ('bd_crown','badge','Pick Royalty',300,'{"icon":"👑","title":"Pick Royalty"}'::jsonb,30),
  ('fr_lime','frame','Portal Ring',60,'{"style":"lime"}'::jsonb,10),
  ('fr_neon','frame','Purple Neon',60,'{"style":"neon"}'::jsonb,11),
  ('fr_double','frame','Double Ring',90,'{"style":"double"}'::jsonb,12),
  ('fr_gold','frame','Gold Disc',120,'{"style":"gold"}'::jsonb,13),
  ('fr_pulse','frame','Pulse (animated)',150,'{"style":"pulse"}'::jsonb,20),
  ('fr_prism','frame','Prism Spin (animated)',250,'{"style":"prism"}'::jsonb,30),
  ('th_midnight','theme','Midnight',80,'{"style":"midnight"}'::jsonb,10),
  ('th_portal','theme','Portal',100,'{"style":"portal"}'::jsonb,11),
  ('th_nebula','theme','Nebula',100,'{"style":"nebula"}'::jsonb,12),
  ('th_terminal','theme','Terminal',120,'{"style":"terminal"}'::jsonb,13),
  ('th_synth','theme','Synthwave',150,'{"style":"synth"}'::jsonb,14),
  ('th_gold','theme','Gold Record',200,'{"style":"gold"}'::jsonb,20)
on conflict (id) do nothing;

-- ── 11. The Picks Are Right banks: Cliff Hangers questions + Wheel of Fortune puzzles (add more from the dashboard) ──
insert into public.pm_pir_bank (kind, text, answer) values
  ('cliff', 'How many keys are on a standard piano?', '88'),
  ('cliff', 'How many black keys are on a standard piano?', '36'),
  ('cliff', 'How many squares are on a chessboard?', '64'),
  ('cliff', 'How many cards are in a standard deck, not counting jokers?', '52'),
  ('cliff', 'How many teeth does an adult usually have, wisdom teeth included?', '32'),
  ('cliff', 'How many dominoes are in a double-six set?', '28'),
  ('cliff', 'How many spaces are on a Monopoly board?', '40'),
  ('cliff', 'How many properties can you buy in Monopoly (streets, railroads and utilities)?', '28'),
  ('cliff', 'How many tiles are in an English Scrabble set?', '100'),
  ('cliff', 'How many points is the Q worth in English Scrabble?', '10'),
  ('cliff', 'What''s the highest score you can get with a single dart?', '60'),
  ('cliff', 'What''s a perfect score in ten-pin bowling?', '300'),
  ('cliff', 'What''s the maximum break in snooker?', '147'),
  ('cliff', 'How many numbers are on a European roulette wheel, zero included?', '37'),
  ('cliff', 'How many minutes long is a regulation NBA game?', '48'),
  ('cliff', 'How many minutes long is each period of an NHL game?', '20'),
  ('cliff', 'How many players does each rugby union team have on the field?', '15'),
  ('cliff', 'How many yards are there between the goal lines on an American football field?', '100'),
  ('cliff', 'How many feet high is a regulation basketball hoop?', '10'),
  ('cliff', 'How many miles is a marathon (rounded down)?', '26'),
  ('cliff', 'How many holes are in a standard round of golf?', '18'),
  ('cliff', 'How many hearts does an octopus have?', '3'),
  ('cliff', 'How many legs does a lobster have?', '10'),
  ('cliff', 'How many hexagons are on a classic soccer ball?', '20'),
  ('cliff', 'How many faces does an icosahedron have?', '20'),
  ('cliff', 'How old must you be to become President of the United States?', '35'),
  ('cliff', 'How many stripes are on the United States flag?', '13'),
  ('cliff', 'How many members are in the US Senate?', '100'),
  ('cliff', 'How many US states border Canada?', '13'),
  ('cliff', 'How many countries are in Africa?', '54'),
  ('cliff', 'How many bones are in the human skull?', '22'),
  ('cliff', 'How many hours are in a week?', '168'),
  ('cliff', 'How many inches are in a yard?', '36'),
  ('cliff', 'How many ounces are in a pound?', '16'),
  ('cliff', 'How many cups are in a US gallon?', '16'),
  ('cliff', 'At what temperature does water freeze, in Fahrenheit?', '32'),
  ('cliff', 'At what temperature does water boil at sea level, in Fahrenheit?', '212'),
  ('cliff', 'How many dalmatians are in the title of the Disney classic?', '101'),
  ('cliff', 'How many letters are in "supercalifragilisticexpialidocious"?', '34'),
  ('cliff', 'How many lines are in a sonnet?', '14'),
  ('cliff', 'How many pieces does each player start with in chess?', '16'),
  ('cliff', 'How many dots are on a standard six-sided die, all faces added up?', '21'),
  ('cliff', 'How many colored stickers are on a standard 3x3 Rubik''s Cube?', '54'),
  ('cliff', 'How many strings does a concert pedal harp have?', '47'),
  ('cliff', 'How many levels can you play in the original Pac-Man before the glitched kill screen?', '255'),
  ('cliff', 'What year did the first iPhone come out?', '2007'),
  ('cliff', 'What year did Twitch launch?', '2011'),
  ('cliff', 'What year did the original Game Boy come out in Japan?', '1989'),
  ('cliff', 'What year was the Fender Stratocaster introduced?', '1954'),
  ('cliff', 'What year did people first land on the Moon?', '1969'),
  ('cliff', 'What year did YouTube launch?', '2005'),
  ('cliff', 'What year did Pac-Man hit arcades?', '1980'),
  ('cliff', 'What year did the Titanic sink?', '1912'),
  ('cliff', 'What year did MTV launch?', '1981'),
  ('cliff', 'What year did Super Mario Bros. come out in Japan?', '1985'),
  ('cliff', 'What year did the first PlayStation come out in Japan?', '1994'),
  ('cliff', 'What year did the Beatles first play The Ed Sullivan Show?', '1964')
on conflict (kind, text) do nothing;
insert into public.pm_pir_bank (kind, category, text) values
  ('wof', 'PHRASE', 'BREAK A LEG'),
  ('wof', 'PHRASE', 'ONCE IN A BLUE MOON'),
  ('wof', 'PHRASE', 'THE BALL IS IN YOUR COURT'),
  ('wof', 'PHRASE', 'HIT THE NAIL ON THE HEAD'),
  ('wof', 'PHRASE', 'BETTER LATE THAN NEVER'),
  ('wof', 'PHRASE', 'PIECE OF CAKE'),
  ('wof', 'PHRASE', 'CALL IT A DAY'),
  ('wof', 'PHRASE', 'SPILL THE BEANS'),
  ('wof', 'PHRASE', 'UNDER THE WEATHER'),
  ('wof', 'PHRASE', 'BITE THE BULLET'),
  ('wof', 'PHRASE', 'THE BEST OF BOTH WORLDS'),
  ('wof', 'PHRASE', 'ON CLOUD NINE'),
  ('wof', 'PHRASE', 'BACK TO SQUARE ONE'),
  ('wof', 'PHRASE', 'PRACTICE MAKES PERFECT'),
  ('wof', 'PHRASE', 'NO PAIN NO GAIN'),
  ('wof', 'WHAT ARE YOU DOING?', 'TUNING MY GUITAR'),
  ('wof', 'WHAT ARE YOU DOING?', 'RAIDING THE FRIDGE'),
  ('wof', 'WHAT ARE YOU DOING?', 'CHECKING THE CHAT'),
  ('wof', 'WHAT ARE YOU DOING?', 'SPEEDRUNNING A VIDEO GAME'),
  ('wof', 'WHAT ARE YOU DOING?', 'TAKING A POWER NAP'),
  ('wof', 'WHAT ARE YOU DOING?', 'BINGE WATCHING A NEW SHOW'),
  ('wof', 'WHAT ARE YOU DOING?', 'ORDERING TAKEOUT'),
  ('wof', 'WHAT ARE YOU DOING?', 'WAITING FOR THE BUS'),
  ('wof', 'THING', 'A HOT CUP OF COFFEE'),
  ('wof', 'THING', 'GAMING HEADSET'),
  ('wof', 'THING', 'MECHANICAL KEYBOARD'),
  ('wof', 'THING', 'GUITAR PICK'),
  ('wof', 'THING', 'REMOTE CONTROL'),
  ('wof', 'THING', 'ROLLER SKATES'),
  ('wof', 'THING', 'ELECTRIC GUITAR'),
  ('wof', 'THING', 'WIRELESS MICROPHONE'),
  ('wof', 'THING', 'COMFY RECLINER'),
  ('wof', 'FOOD & DRINK', 'PEPPERONI PIZZA'),
  ('wof', 'FOOD & DRINK', 'CHOCOLATE CHIP COOKIES'),
  ('wof', 'FOOD & DRINK', 'GRILLED CHEESE SANDWICH'),
  ('wof', 'FOOD & DRINK', 'BUTTERED POPCORN'),
  ('wof', 'FOOD & DRINK', 'ICED CARAMEL LATTE'),
  ('wof', 'FOOD & DRINK', 'SPICY CHICKEN WINGS'),
  ('wof', 'FOOD & DRINK', 'STRAWBERRY MILKSHAKE'),
  ('wof', 'FOOD & DRINK', 'FRENCH TOAST WITH SYRUP'),
  ('wof', 'PLACE', 'HAUNTED HOUSE'),
  ('wof', 'PLACE', 'MOVIE THEATER'),
  ('wof', 'PLACE', 'BOWLING ALLEY'),
  ('wof', 'PLACE', 'RECORDING STUDIO'),
  ('wof', 'PLACE', 'VIDEO ARCADE'),
  ('wof', 'PLACE', 'CAMPGROUND'),
  ('wof', 'PLACE', 'TOY STORE'),
  ('wof', 'PLACE', 'ROLLER RINK'),
  ('wof', 'ON THE MAP', 'GRAND CANYON'),
  ('wof', 'ON THE MAP', 'NIAGARA FALLS'),
  ('wof', 'ON THE MAP', 'MOUNT EVEREST'),
  ('wof', 'ON THE MAP', 'NEW YORK CITY'),
  ('wof', 'ON THE MAP', 'LAS VEGAS NEVADA'),
  ('wof', 'ON THE MAP', 'THE AMAZON RAINFOREST'),
  ('wof', 'ON THE MAP', 'ROCKY MOUNTAINS'),
  ('wof', 'EVENT', 'SURPRISE BIRTHDAY PARTY'),
  ('wof', 'EVENT', 'FIREWORKS SHOW'),
  ('wof', 'EVENT', 'MIDNIGHT MOVIE PREMIERE'),
  ('wof', 'EVENT', 'ROCK CONCERT'),
  ('wof', 'EVENT', 'TALENT SHOW'),
  ('wof', 'EVENT', 'GAME NIGHT WITH FRIENDS'),
  ('wof', 'OCCUPATION', 'ROCKET SCIENTIST'),
  ('wof', 'OCCUPATION', 'PIZZA DELIVERY DRIVER'),
  ('wof', 'OCCUPATION', 'MUSIC PRODUCER'),
  ('wof', 'OCCUPATION', 'VIDEO GAME DESIGNER'),
  ('wof', 'OCCUPATION', 'ZOOKEEPER'),
  ('wof', 'OCCUPATION', 'SOUND ENGINEER'),
  ('wof', 'LIVING THING', 'GIANT PANDA'),
  ('wof', 'LIVING THING', 'RED-EYED TREE FROG'),
  ('wof', 'LIVING THING', 'HUMPBACK WHALE'),
  ('wof', 'LIVING THING', 'GOLDEN RETRIEVER'),
  ('wof', 'LIVING THING', 'SUNFLOWER'),
  ('wof', 'LIVING THING', 'VENUS FLYTRAP'),
  ('wof', 'FUN & GAMES', 'HIDE AND SEEK'),
  ('wof', 'FUN & GAMES', 'MUSICAL CHAIRS'),
  ('wof', 'FUN & GAMES', 'THUMB WRESTLING'),
  ('wof', 'FUN & GAMES', 'ROCK PAPER SCISSORS'),
  ('wof', 'FUN & GAMES', 'PIN THE TAIL ON THE DONKEY'),
  ('wof', 'FUN & GAMES', 'KARAOKE NIGHT')
on conflict (kind, text) do nothing;
