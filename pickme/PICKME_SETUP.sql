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
    new.closes_at := now() + make_interval(secs => new.seconds);
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

-- null = may play; otherwise a reason code
create or replace function public.pm_check(p_profile uuid, p_session uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare s public.pm_sessions;
begin
  if exists (select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'block' and a.scope = 'global') then
    return 'blocked';
  end if;
  if p_session is null then return null; end if;
  select * into s from public.pm_sessions where id = p_session;
  if not found then return 'no_session'; end if;
  if s.status = 'ended' then return 'ended'; end if;
  if exists (select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'block'
             and ((a.scope = 'game' and a.scope_value = s.game) or (a.scope = 'session' and a.scope_value = s.id::text))) then
    return 'blocked';
  end if;
  if s.access = 'whitelist' and not exists (
       select 1 from public.pm_access a where a.profile_id = p_profile and a.kind = 'allow'
       and (a.scope = 'global' or (a.scope = 'game' and a.scope_value = s.game) or (a.scope = 'session' and a.scope_value = s.id::text))) then
    return 'not_whitelisted';
  end if;
  if s.status = 'closed' and not exists (
       select 1 from public.pm_participants p where p.session_id = s.id and p.profile_id = p_profile) then
    return 'closed';
  end if;
  return null;
end $$;

create or replace function public.pm_enter(p_profile uuid, p_session uuid, p_via text)
returns text language plpgsql security definer set search_path = '' as $$
declare r text; n int;
begin
  r := public.pm_check(p_profile, p_session);
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
  if not found or rd.status <> 'collecting' or now() > rd.closes_at + interval '2 seconds' then return 'round_closed'; end if;
  if ans = '' then return 'empty'; end if;
  r := public.pm_enter(p_profile, rd.session_id, p_source);
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

-- ── 7. Grants ───────────────────────────────────────────────
grant select on public.pm_profiles, public.pm_sessions, public.pm_participants, public.pm_rounds,
                public.pm_answers, public.pm_state to anon, authenticated;
grant select on public.pm_ledger, public.pm_events, public.pm_questions, public.pm_access to authenticated;
grant insert, update, delete on public.pm_sessions, public.pm_access, public.pm_rounds to authenticated;
grant update, delete on public.pm_questions to authenticated;
grant delete on public.pm_participants, public.pm_answers to authenticated;
grant update on public.pm_state to authenticated;

-- internal helpers: nobody calls these directly
revoke execute on function public.pm_log(uuid, text, jsonb, uuid)          from public, anon, authenticated;
revoke execute on function public.pm_check(uuid, uuid)                      from public, anon, authenticated;
revoke execute on function public.pm_enter(uuid, uuid, text)                from public, anon, authenticated;
revoke execute on function public.pm_answer_as(uuid, uuid, text, text)      from public, anon, authenticated;
revoke execute on function public.pm_question_as(uuid, text, text)          from public, anon, authenticated;
revoke execute on function public.pm_ledger_apply()                         from public, anon, authenticated;
revoke execute on function public.pm_access_log()                           from public, anon, authenticated;
-- callable by anyone signed in (each checks who you are)
grant execute on function public.pm_now()                    to anon, authenticated;
grant execute on function public.pm_is_admin()               to anon, authenticated;
grant execute on function public.pm_my_profile()             to authenticated;
grant execute on function public.pm_ensure_profile()         to authenticated;
grant execute on function public.pm_join(uuid)               to authenticated;
grant execute on function public.pm_submit_answer(uuid, text) to authenticated;
grant execute on function public.pm_submit_question(text)    to authenticated;
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
