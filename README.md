# AudioGen

Privacy-first SaaS that turns books into audiobooks. Next.js App Router + Supabase
(Auth, Postgres, RLS) + Redis job queue + Cloudflare R2 + Stripe (later pasos).

## Stack (Paso 1)

- **Next.js 15** (App Router, TypeScript strict, Tailwind CSS)
- **Supabase** — schema, RLS, credit RPCs (`supabase/migrations/`)
- **Zod** — env validation (`src/lib/env.ts`)
- **Pino** — structured logging (`src/lib/logger.ts`)

Pasos 2–6 (auth UI, upload API, player, Stripe, Python worker) are **not**
implemented yet.

## Getting started

```bash
cp .env.example .env.local
# Fill Supabase URL + anon + service role keys (and others as needed)

npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Environment

See `.env.example`. Required for server Supabase clients:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

`getEnv()` validates on first server use (fail-fast) and does not block `next build`
when secrets are absent in CI.

## Apply SQL migrations

See [`supabase/README.md`](supabase/README.md). Short version:

```bash
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

Or paste `supabase/migrations/001_initial_schema.sql` into the Supabase SQL Editor.

## Layout

```
src/app/           # App Router pages / route handlers
src/components/    # UI (later)
src/lib/           # env, logger, supabase clients
supabase/migrations/
worker/            # Python worker placeholder (Paso 6)
```

## Security foundations (Paso 1)

- Secrets only via `.env` / `.env.local` (gitignored); `.env.example` has placeholders
- RLS on all public tables; credits/plan protected from client updates
- `debit_credit_for_book_generation` — row lock + ACID debit + transaction row
- Books: `text_hash` unique dedup; `is_dmca_takedown` + `status = dmca_flagged`
- Catalog excludes DMCA / non-ready titles
- Minimal PII on `public.users` (profile id only; email stays in `auth.users`)

## Scripts

| Command        | Description              |
| -------------- | ------------------------ |
| `npm run dev`  | Dev server (Turbopack)   |
| `npm run build`| Production build         |
| `npm run start`| Start production server  |
| `npm run lint` | ESLint                   |
