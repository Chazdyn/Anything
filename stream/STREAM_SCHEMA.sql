-- ════════════════════════════════════════════════════════════
--  CHAZDYN STREAM NETWORK — Supabase schema
--  Run this in Supabase → SQL Editor. Powers /stream/<channel>
--  and the per-creator Control panels.
-- ════════════════════════════════════════════════════════════

-- 1) CREATORS ----------------------------------------------------
create table if not exists public.creators (
  id               uuid primary key default gen_random_uuid(),
  slug             text unique not null,              -- url: /stream/<slug>
  display_name     text not null,
  twitch_channel   text not null,
  owner_discord_id text,                              -- who may edit (Control.<name>)
  accent           text default '#4dff1f',
  accent2          text default '#16e0ff',
  avatar_url       text,
  banner_url       text,
  poster_url       text,
  tagline          text,
  socials          jsonb default '{}'::jsonb,         -- {discord,tiktok,instagram,youtube}
  redeems          jsonb default '[]'::jsonb,         -- manual or synced rewards; Twitch sync uses {label,cost,icon,twitchRewardId,actionName,enabled,source}
  sb_ws_url        text,                              -- wss relay to Streamer.bot
  is_live          boolean default false,
  viewer_count     integer default 0,                 -- saved by Control.Dyn Helix /streams refresh
  live_started_at  timestamptz,
  live_checked_at  timestamptz,
  display_order    integer default 1000,              -- offline/main directory order; lower appears first
  live_priority    integer default 1000,              -- live order when sort mode = priority; lower appears first
  creative_mode    text default 'prefab',             -- off | prefab | custom_html
  creative_title   text,
  creative_subtitle text,
  creative_body    text,
  creative_links   jsonb default '[]'::jsonb,         -- [{label,url}]
  custom_html      text,                              -- rendered below stream in a sandboxed iframe
  page_on          boolean default true,              -- creator's on/off toggle
  listed           boolean default true,              -- show in /stream/ directory; direct page still works
  approved         boolean default false,             -- Chazdyn approves before it goes public
  created_at       timestamptz default now()
);

-- Safe if you already created the table before newer fields existed.
alter table public.creators add column if not exists listed boolean default true;
alter table public.creators add column if not exists sb_ws_url text;
alter table public.creators add column if not exists redeems jsonb default '[]'::jsonb;
alter table public.creators add column if not exists viewer_count integer default 0;
alter table public.creators add column if not exists live_started_at timestamptz;
alter table public.creators add column if not exists live_checked_at timestamptz;
alter table public.creators add column if not exists display_order integer default 1000;
alter table public.creators add column if not exists live_priority integer default 1000;
alter table public.creators add column if not exists creative_mode text default 'prefab';
alter table public.creators add column if not exists creative_title text;
alter table public.creators add column if not exists creative_subtitle text;
alter table public.creators add column if not exists creative_body text;
alter table public.creators add column if not exists creative_links jsonb default '[]'::jsonb;
alter table public.creators add column if not exists custom_html text;

-- 1b) PUBLIC STREAM DIRECTORY SETTINGS -------------------------
create table if not exists public.stream_settings (
  key        text primary key,
  value      jsonb default '{}'::jsonb,
  updated_at timestamptz default now()
);

insert into public.stream_settings (key, value)
values ('directory', '{"liveSortMode":"priority"}'::jsonb)
on conflict (key) do nothing;

-- 2) JOIN REQUESTS (self-register via Discord, Chazdyn approves) --
create table if not exists public.creator_requests (
  id               uuid primary key default gen_random_uuid(),
  discord_id       text not null,
  discord_name     text,
  requested_slug   text,
  twitch_channel   text,
  status           text default 'pending',            -- pending | approved | denied
  created_at       timestamptz default now()
);

-- ════════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
-- ════════════════════════════════════════════════════════════
alter table public.creators         enable row level security;
alter table public.creator_requests enable row level security;
alter table public.stream_settings  enable row level security;

-- Keep this file re-runnable while you are iterating.
drop policy if exists "public reads live creators" on public.creators;
drop policy if exists "owner reads own row" on public.creators;
drop policy if exists "owner updates own row" on public.creators;
drop policy if exists "admin reads all creators" on public.creators;
drop policy if exists "admin inserts creators" on public.creators;
drop policy if exists "admin updates creators" on public.creators;
drop policy if exists "admin deletes creators" on public.creators;
drop policy if exists "signed-in can request" on public.creator_requests;
drop policy if exists "admin reads creator requests" on public.creator_requests;
drop policy if exists "admin updates creator requests" on public.creator_requests;
drop policy if exists "public reads stream settings" on public.stream_settings;
drop policy if exists "admin reads stream settings" on public.stream_settings;
drop policy if exists "admin inserts stream settings" on public.stream_settings;
drop policy if exists "admin updates stream settings" on public.stream_settings;
drop policy if exists "admin deletes stream settings" on public.stream_settings;

-- Public can READ creator pages that are approved AND turned on.
-- `listed = false` only hides a creator from the directory. Direct links
-- such as /stream/shyshack still resolve while page_on remains true.
create policy "public reads live creators"
  on public.creators for select
  using ( approved = true and page_on = true );

-- A creator can read/update ONLY their own row.
-- (Map Discord login → owner_discord_id. With Supabase Discord OAuth,
--  the Discord user id is in auth.jwt() -> 'user_metadata' -> 'provider_id'.)
create policy "owner reads own row"
  on public.creators for select
  using ( owner_discord_id = (auth.jwt() -> 'user_metadata' ->> 'provider_id') );

create policy "owner updates own row"
  on public.creators for update
  using ( owner_discord_id = (auth.jwt() -> 'user_metadata' ->> 'provider_id') )
  with check ( owner_discord_id = (auth.jwt() -> 'user_metadata' ->> 'provider_id') );

-- Chazdyn's Control.Dyn admin panel uses the public anon key plus Discord
-- OAuth. These policies let only the allowlisted Discord account manage
-- all stream creator rows from Control.Dyn without exposing a service key.
create policy "admin reads all creators"
  on public.creators for select
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin inserts creators"
  on public.creators for insert
  with check ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin updates creators"
  on public.creators for update
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' )
  with check ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin deletes creators"
  on public.creators for delete
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

-- Anyone signed in can file a join request; nobody else can read them.
create policy "signed-in can request"
  on public.creator_requests for insert
  with check ( auth.role() = 'authenticated' );

create policy "admin reads creator requests"
  on public.creator_requests for select
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin updates creator requests"
  on public.creator_requests for update
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' )
  with check ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

-- Public stream directory settings are safe to read. Only Chazdyn can edit.
create policy "public reads stream settings"
  on public.stream_settings for select
  using ( true );

create policy "admin reads stream settings"
  on public.stream_settings for select
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin inserts stream settings"
  on public.stream_settings for insert
  with check ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin updates stream settings"
  on public.stream_settings for update
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' )
  with check ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

create policy "admin deletes stream settings"
  on public.stream_settings for delete
  using ( (auth.jwt() -> 'user_metadata' ->> 'provider_id') = '562352729482067968' );

-- NOTE: Do NOT expose the service-role key in the website. Control.Dyn uses
-- the public anon key and the admin Discord policy above.

-- ════════════════════════════════════════════════════════════
--  SEED — your own row (edit values, then run)
-- ════════════════════════════════════════════════════════════
insert into public.creators
  (slug, display_name, twitch_channel, owner_discord_id, accent, accent2,
   avatar_url, banner_url, poster_url, tagline, socials, redeems, sb_ws_url,
   display_order, live_priority, viewer_count, creative_mode, creative_title, creative_body,
   approved, listed, page_on, is_live)
values
  ('chazdyn','Chazdyn','chazdyn','YOUR_DISCORD_ID','#4dff1f','#16e0ff',
   '/assets/chazdyn-default-avatar.png','/assets/Chazdyn-Banner-cropped-original-20260506193644.jpg',
   '/assets/chazdyn-latenight-set.png','Lifelong musician building a late night worth staying up for.',
   '{"discord":"https://discord.gg/","tiktok":"https://tiktok.com/@chazdyn"}',
   '[{"icon":"🎵","label":"Song Request","cost":500,"actionName":"Song Request","enabled":true,"source":"manual"},
     {"icon":"💡","label":"Lights: Portal","cost":1000,"actionName":"Portal Lights","enabled":true,"source":"manual"}]',
   'wss://streamerbot.chazdyn.com/',
   1, 1, 0, 'prefab', 'The Chazdyn Show', 'Streams, live guitar, creator chaos, and whatever beautiful mess happens next.',
   true, true, true, false)
on conflict (slug) do nothing;
