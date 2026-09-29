# AudioGen Python Worker (Paso 6)

Placeholder for the Redis-backed worker that will:

- Consume book-generation jobs from Redis
- Extract / normalize text, chunk chapters
- Call TTS / audio pipeline
- Upload audio to R2 and update `chapters` / `books` via Supabase service role

**Do not implement the worker in Paso 1.** This directory exists only to reserve
layout for the monorepo-ish structure.
