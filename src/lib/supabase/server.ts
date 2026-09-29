import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getEnv } from "@/lib/env";

/**
 * Server-side Supabase clients.
 *
 * - `createAnonServerClient`: user-scoped operations under RLS (anon key).
 * - `createServiceRoleClient`: privileged API paths (upload/generation).
 *   Use ONLY in Route Handlers / server code. Never import into client bundles.
 *
 * Auth session cookie wiring lands in Paso 2; stubs are ready for env-typed use.
 */

export function createAnonServerClient(): SupabaseClient {
  const env = getEnv();
  return createClient(
    env.NEXT_PUBLIC_SUPABASE_URL,
    env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    },
  );
}

/**
 * Service-role client bypasses RLS. Prefer SECURITY DEFINER RPCs when possible;
 * reserve this for controlled Route Handler paths (book insert, generation kickoff).
 */
export function createServiceRoleClient(): SupabaseClient {
  const env = getEnv();
  return createClient(
    env.NEXT_PUBLIC_SUPABASE_URL,
    env.SUPABASE_SERVICE_ROLE_KEY,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    },
  );
}
