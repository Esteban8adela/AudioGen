import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getPublicEnv } from "@/lib/env";

/**
 * Browser / client-side Supabase client (anon key + RLS).
 * Do not use for privileged writes (credits, books insert, transactions).
 */
export function createBrowserSupabaseClient(): SupabaseClient {
  const env = getPublicEnv();
  return createClient(
    env.NEXT_PUBLIC_SUPABASE_URL,
    env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    },
  );
}

/** Lazy singleton for client components. */
let browserClient: SupabaseClient | null = null;

export function getBrowserSupabaseClient(): SupabaseClient {
  if (!browserClient) {
    browserClient = createBrowserSupabaseClient();
  }
  return browserClient;
}
