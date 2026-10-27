-- ════════════════════════════════════════════════════════════
--  SECURITY FIX — stop trusting user_metadata in RLS policies
--  Run once in Supabase → SQL Editor. Safe to re-run.
--
--  Why: auth.jwt() -> 'user_metadata' comes from raw_user_meta_data,
--  which any signed-in user can rewrite with supabase.auth.updateUser().
--  A policy like  user_metadata ->> 'provider_id' = '<admin id>'
--  can therefore be satisfied by anyone who sets that field on themselves.
--
--  Fix: read the Discord ID from auth.identities, which only Supabase
--  writes (from Discord at sign-in). Every existing policy in the public
--  and storage schemas that checks user_metadata.provider_id is rebuilt
--  with the same name, roles and command — only that expression changes.
--  This includes SpaceDyn policies that aren't in this repo.
-- ════════════════════════════════════════════════════════════

create or replace function public.dyn_discord_id()
returns text
language sql stable security definer
set search_path = ''
as $$
  select i.provider_id
  from auth.identities i
  where i.user_id = auth.uid() and i.provider = 'discord'
  order by i.created_at
  limit 1;
$$;
grant execute on function public.dyn_discord_id() to anon, authenticated;

do $$
declare
  p     record;
  pat   text := '\(\(auth\.jwt\(\)\s*->\s*''user_metadata''(::text)?\)\s*->>\s*''provider_id''(::text)?\)';
  q     text;
  c     text;
  roles text;
  stmt  text;
begin
  for p in
    select * from pg_policies
    where schemaname in ('public', 'storage')
      and (coalesce(qual, '') ~ 'user_metadata' or coalesce(with_check, '') ~ 'user_metadata')
  loop
    q := regexp_replace(p.qual,       pat, 'public.dyn_discord_id()', 'g');
    c := regexp_replace(p.with_check, pat, 'public.dyn_discord_id()', 'g');

    if coalesce(q, '') ~ 'user_metadata' or coalesce(c, '') ~ 'user_metadata' then
      raise notice 'NOT CHANGED (uses another user_metadata field, review by hand): %.% "%"',
        p.schemaname, p.tablename, p.policyname;
      continue;
    end if;

    select string_agg(case when r = 'public' then 'public' else quote_ident(r) end, ', ')
      into roles from unnest(p.roles) as r;

    stmt := format('create policy %I on %I.%I as %s for %s to %s',
                   p.policyname, p.schemaname, p.tablename, p.permissive, p.cmd, roles);
    if q is not null then stmt := stmt || format(' using (%s)', q); end if;
    if c is not null then stmt := stmt || format(' with check (%s)', c); end if;

    execute format('drop policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    execute stmt;
    raise notice 'fixed: %.% "%"', p.schemaname, p.tablename, p.policyname;
  end loop;
end $$;

-- Anything listed here still trusts user_metadata and needs a manual look.
-- An empty result means every policy is fixed.
select schemaname, tablename, policyname, qual, with_check
from pg_policies
where schemaname in ('public', 'storage')
  and (coalesce(qual, '') ~ 'user_metadata' or coalesce(with_check, '') ~ 'user_metadata');
