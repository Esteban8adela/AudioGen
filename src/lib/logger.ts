import pino from "pino";

/**
 * Structured logger (Pino). Prefer this over console.log/console.error.
 * Level comes from LOG_LEVEL when available; defaults to "info".
 */
function resolveLogLevel(): pino.LevelWithSilent {
  const level = process.env.LOG_LEVEL;
  const allowed = new Set([
    "fatal",
    "error",
    "warn",
    "info",
    "debug",
    "trace",
    "silent",
  ]);
  if (level && allowed.has(level)) {
    return level as pino.LevelWithSilent;
  }
  return process.env.NODE_ENV === "production" ? "info" : "debug";
}

export const logger = pino({
  level: resolveLogLevel(),
  base: {
    service: "audiogen",
  },
  redact: {
    paths: [
      "req.headers.authorization",
      "password",
      "token",
      "secret",
      "stripe_customer_id",
      "SUPABASE_SERVICE_ROLE_KEY",
      "STRIPE_SECRET_KEY",
      "R2_SECRET_ACCESS_KEY",
    ],
    remove: true,
  },
  ...(process.env.NODE_ENV !== "production"
    ? {
        transport: {
          target: "pino-pretty",
          options: {
            colorize: true,
            translateTime: "SYS:standard",
          },
        },
      }
    : {}),
});

export type Logger = typeof logger;
