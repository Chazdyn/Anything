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
