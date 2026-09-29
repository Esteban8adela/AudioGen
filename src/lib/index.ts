/**
 * Shared library barrel — keep side-effect free.
 * Import specific modules (`@/lib/env`, `@/lib/logger`, etc.) instead of this
 * file from hot paths to avoid pulling server-only deps into the client.
 */
export {};
