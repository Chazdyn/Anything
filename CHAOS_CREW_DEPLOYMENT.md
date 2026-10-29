# Chaos Crew — private deployment staging

This is an **unpublished staging scaffold** on `feature/chaos-crew-private`. It is not a finished V9 integration and must not be merged into the live deployment until the access controls below are in place.

## Existing project

- Website repository: `Chazdyn/Anything`
- Planned entry: `https://chazdyn.com/_private/chaos/`
- Existing website homepage is unchanged.
- The standalone V9 Node project is **not compatible with a static Cloudflare Pages deployment without a backend adaptation**.

## Required before deployment

1. Identify the exact Cloudflare Pages/Workers project and its build output/root directory. Confirm the branch is not automatically deployed publicly.
2. Create a Cloudflare Access **self-hosted application** for the private path (and all private API paths). Add an **Allow** policy for only the owner's verified identity. Do not use an email-domain wildcard or rely on an obscure URL.
3. Confirm the Access policy applies to both page and API requests, including scheduled-trigger administrative endpoints. Ensure direct Worker origins cannot bypass the gate.
4. Inspect the actual existing Twitch/Discord OAuth and Supabase configuration. The root `index.html` has no Supabase or auth implementation, so it may live elsewhere.
5. Adapt V9 server endpoints for Workers, use Supabase with RLS and server-side credentials, and add authorization checks to **every** data and AI endpoint. Never expose a service-role key or OpenAI key to browser JS.
6. Use Cloudflare cron triggers for background decisions, with per-day AI budget, rate limiting, audit logs, and safe no-op when credentials are missing.
7. Verify on iPhone, including signed-out denial, unauthorized account denial, and protected API denial.

## Current branch contents

`_private/chaos/index.html` is a mobile-friendly **setup placeholder**, not a functioning AI app. It is deliberately free of credentials and data.

## Cost

Cloudflare and Supabase have free tiers with limits. OpenAI API usage is separately billed. Do not enable unattended generation without an explicit spending cap.

## Rollout

Keep changes on the feature branch; test a protected preview first. Only merge after Access and backend security tests pass.
