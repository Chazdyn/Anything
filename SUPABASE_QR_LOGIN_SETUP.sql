-- Control.Dyn QR handoff login support
-- Run once in Supabase SQL Editor.
-- This lets the public computer create a short-lived QR login request,
-- then lets only Chazdyn's authenticated Discord account approve it from a phone.

create table if not exists public.control_dyn_qr_logins (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  status text not null default 'pending' check (status in ('pending','approved','consumed','expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  approved_by text,
  approved_name text,
  approved_at timestamptz,
  consumed_at timestamptz
);

alter table public.control_dyn_qr_logins enable row level security;

-- Public computers may create pending QR requests. The code is random and short-lived.
drop policy if exists "qr insert pending requests" on public.control_dyn_qr_logins;
create policy "qr insert pending requests"
on public.control_dyn_qr_logins
for insert
to anon, authenticated
with check (
  status = 'pending'
  and expires_at <= now() + interval '10 minutes'
  and expires_at > now()
);

-- Public computers may poll QR requests by random code.
drop policy if exists "qr select requests" on public.control_dyn_qr_logins;
create policy "qr select requests"
on public.control_dyn_qr_logins
for select
to anon, authenticated
using (expires_at > now() - interval '1 hour');

-- Only the allowlisted Discord account can approve a QR request.
-- Admin Discord ID: 562352729482067968
drop policy if exists "qr approve by admin discord" on public.control_dyn_qr_logins;
create policy "qr approve by admin discord"
on public.control_dyn_qr_logins
for update
to authenticated
using (
  status = 'pending'
  and expires_at > now()
  and coalesce(auth.jwt() -> 'user_metadata' ->> 'provider_id', '') = '562352729482067968'
)
with check (
  status in ('approved','consumed')
  and approved_by = '562352729482067968'
);

-- Allow the desktop to mark an approved QR login as consumed after it unlocks.
drop policy if exists "qr consume approved requests" on public.control_dyn_qr_logins;
create policy "qr consume approved requests"
on public.control_dyn_qr_logins
for update
to anon, authenticated
using (status = 'approved' and expires_at > now())
with check (status = 'consumed');

create index if not exists control_dyn_qr_logins_code_idx on public.control_dyn_qr_logins(code);
create index if not exists control_dyn_qr_logins_expires_idx on public.control_dyn_qr_logins(expires_at);
