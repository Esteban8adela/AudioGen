import { z } from "zod";

/**
 * Server-side environment schema.
 * Validated lazily on first `getEnv()` call so `next build` can succeed
 * without secrets present in CI; runtime server code fails fast if misconfigured.
 */
const serverEnvSchema = z.object({
  NODE_ENV: z
    .enum(["development", "test", "production"])
    .default("development"),
  NEXT_PUBLIC_APP_URL: z.string().url().optional(),

  NEXT_PUBLIC_SUPABASE_URL: z.string().url(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().min(1),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),

  REDIS_URL: z.string().url().optional(),

  R2_ACCOUNT_ID: z.string().min(1).optional(),
  R2_ACCESS_KEY_ID: z.string().min(1).optional(),
  R2_SECRET_ACCESS_KEY: z.string().min(1).optional(),
  R2_BUCKET_NAME: z.string().min(1).optional(),
  R2_PUBLIC_BASE_URL: z.string().url().optional(),

  STRIPE_SECRET_KEY: z.string().min(1).optional(),
  STRIPE_WEBHOOK_SECRET: z.string().min(1).optional(),
  NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY: z.string().min(1).optional(),
  STRIPE_PRICE_PRO: z.string().min(1).optional(),
  STRIPE_PRICE_POWER: z.string().min(1).optional(),
  STRIPE_PRICE_CREDITS: z.string().min(1).optional(),

  LOG_LEVEL: z
    .enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
    .default("info"),
});

export type ServerEnv = z.infer<typeof serverEnvSchema>;

/**
 * Public (browser-safe) env subset. Only NEXT_PUBLIC_* keys.
 */
const publicEnvSchema = z.object({
  NEXT_PUBLIC_APP_URL: z.string().url().optional(),
  NEXT_PUBLIC_SUPABASE_URL: z.string().url(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().min(1),
  NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY: z.string().min(1).optional(),
});

export type PublicEnv = z.infer<typeof publicEnvSchema>;

let cachedServerEnv: ServerEnv | null = null;
let cachedPublicEnv: PublicEnv | null = null;

function readProcessEnv(): Record<string, string | undefined> {
  return {
    NODE_ENV: process.env.NODE_ENV,
    NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    REDIS_URL: process.env.REDIS_URL,
    R2_ACCOUNT_ID: process.env.R2_ACCOUNT_ID,
    R2_ACCESS_KEY_ID: process.env.R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY: process.env.R2_SECRET_ACCESS_KEY,
    R2_BUCKET_NAME: process.env.R2_BUCKET_NAME,
    R2_PUBLIC_BASE_URL: process.env.R2_PUBLIC_BASE_URL,
    STRIPE_SECRET_KEY: process.env.STRIPE_SECRET_KEY,
    STRIPE_WEBHOOK_SECRET: process.env.STRIPE_WEBHOOK_SECRET,
    NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY:
      process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY,
    STRIPE_PRICE_PRO: process.env.STRIPE_PRICE_PRO,
    STRIPE_PRICE_POWER: process.env.STRIPE_PRICE_POWER,
    STRIPE_PRICE_CREDITS: process.env.STRIPE_PRICE_CREDITS,
    LOG_LEVEL: process.env.LOG_LEVEL,
  };
}

/**
 * Validates and returns server env. Call from Route Handlers / server libs only.
 * Throws ZodError on invalid/missing required vars (fail-fast).
 */
export function getEnv(): ServerEnv {
  if (cachedServerEnv) {
    return cachedServerEnv;
  }

  const parsed = serverEnvSchema.safeParse(readProcessEnv());
  if (!parsed.success) {
    const details = parsed.error.issues
      .map((issue) => `${issue.path.join(".")}: ${issue.message}`)
      .join("; ");
    throw new Error(`Invalid environment configuration: ${details}`);
  }

  cachedServerEnv = parsed.data;
  return cachedServerEnv;
}

/**
 * Browser-safe env. Safe to call from client components after build-time
 * NEXT_PUBLIC_* inlining; still validates shape when values are present.
 */
export function getPublicEnv(): PublicEnv {
  if (cachedPublicEnv) {
    return cachedPublicEnv;
  }

  const parsed = publicEnvSchema.safeParse({
    NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY:
      process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY,
  });

  if (!parsed.success) {
    const details = parsed.error.issues
      .map((issue) => `${issue.path.join(".")}: ${issue.message}`)
      .join("; ");
    throw new Error(`Invalid public environment configuration: ${details}`);
  }

  cachedPublicEnv = parsed.data;
  return cachedPublicEnv;
}

/** Test helper — clears cached env (do not use in production paths). */
export function resetEnvCache(): void {
  cachedServerEnv = null;
  cachedPublicEnv = null;
}
