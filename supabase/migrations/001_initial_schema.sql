-- =============================================================================
-- AudioGen — 001_initial_schema.sql
-- Production-grade schema: GDPR/CCPA-minded minimal PII, DMCA flags,
-- hash-based book dedup, ACID credit debit, and complete RLS.
--
-- Apply via: supabase db push | supabase migration up | SQL Editor paste
-- See supabase/README.md
-- =============================================================================

-- Required extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
CREATE TYPE public.user_plan AS ENUM ('free', 'pro', 'power');
CREATE TYPE public.book_status AS ENUM ('processing', 'ready', 'dmca_flagged');
CREATE TYPE public.transaction_type AS ENUM (
  'subscription',
  'credit_purchase',
  'book_generation'
);

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

-- App profile linked 1:1 to auth.users. Minimal PII (no email/name copy).
CREATE TABLE public.users (
  id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  stripe_customer_id TEXT UNIQUE,
  plan public.user_plan NOT NULL DEFAULT 'free',
  credits INTEGER NOT NULL DEFAULT 0 CHECK (credits >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.books (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  author TEXT,
  cover_url TEXT,
  -- SHA-256 (or similar) of normalized full text for deduplication / privacy
  text_hash TEXT NOT NULL,
  status public.book_status NOT NULL DEFAULT 'processing',
  is_dmca_takedown BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT books_text_hash_unique UNIQUE (text_hash)
);

CREATE TABLE public.chapters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id UUID NOT NULL REFERENCES public.books (id) ON DELETE CASCADE,
  chapter_number INTEGER NOT NULL CHECK (chapter_number >= 1),
  title TEXT NOT NULL,
  audio_url TEXT,
  duration_seconds INTEGER CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chapters_book_chapter_unique UNIQUE (book_id, chapter_number)
);

CREATE TABLE public.library (
  user_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  book_id UUID NOT NULL REFERENCES public.books (id) ON DELETE CASCADE,
  current_chapter_id UUID REFERENCES public.chapters (id) ON DELETE SET NULL,
  progress_seconds INTEGER NOT NULL DEFAULT 0 CHECK (progress_seconds >= 0),
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, book_id)
);

CREATE TABLE public.transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  type public.transaction_type NOT NULL,
  amount INTEGER NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Optional lightweight audit trail for generation jobs.
-- Primary queue remains Redis (Paso 6); this table is for observability only.
CREATE TABLE public.jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  book_id UUID REFERENCES public.books (id) ON DELETE SET NULL,
  job_type TEXT NOT NULL DEFAULT 'book_generation',
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  error_message TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
CREATE INDEX books_text_hash_idx ON public.books (text_hash);
CREATE INDEX books_status_idx ON public.books (status);
CREATE INDEX books_dmca_idx ON public.books (is_dmca_takedown)
  WHERE is_dmca_takedown = true;
CREATE INDEX library_user_id_idx ON public.library (user_id);
CREATE INDEX library_book_id_idx ON public.library (book_id);
CREATE INDEX chapters_book_id_idx ON public.chapters (book_id);
CREATE INDEX transactions_user_id_idx ON public.transactions (user_id);
CREATE INDEX transactions_created_at_idx ON public.transactions (created_at DESC);
CREATE INDEX jobs_user_id_idx ON public.jobs (user_id);
CREATE INDEX jobs_status_idx ON public.jobs (status);

-- -----------------------------------------------------------------------------
-- Helpers / triggers
-- -----------------------------------------------------------------------------

-- updated_at bump
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER jobs_set_updated_at
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Auto-create public.users row when auth.users is created
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_auth_user();

-- Prevent clients from mutating billing / credit fields via direct UPDATE.
-- Service role and SECURITY DEFINER functions (current_user = owner) still can.
CREATE OR REPLACE FUNCTION public.protect_user_billing_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- PostgREST service_role requests
  IF coalesce(auth.jwt() ->> 'role', '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- SECURITY DEFINER RPCs run as function owner (postgres / supabase_admin)
  IF current_user IN ('postgres', 'supabase_admin', 'supabase_storage_admin') THEN
    RETURN NEW;
  END IF;

  IF NEW.credits IS DISTINCT FROM OLD.credits
     OR NEW.plan IS DISTINCT FROM OLD.plan
     OR NEW.stripe_customer_id IS DISTINCT FROM OLD.stripe_customer_id THEN
    RAISE EXCEPTION 'credits, plan, and stripe_customer_id are not client-updatable'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER users_protect_billing_fields
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_user_billing_fields();

-- Keep is_dmca_takedown and status in sync when either is set for DMCA
CREATE OR REPLACE FUNCTION public.sync_book_dmca_flags()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'dmca_flagged' THEN
    NEW.is_dmca_takedown := true;
  ELSIF NEW.is_dmca_takedown = true AND NEW.status IS DISTINCT FROM 'dmca_flagged' THEN
    NEW.status := 'dmca_flagged';
  ELSIF TG_OP = 'UPDATE'
        AND OLD.is_dmca_takedown = true
        AND NEW.is_dmca_takedown = false
        AND NEW.status = 'dmca_flagged' THEN
    -- Clearing DMCA requires an explicit non-dmca status from service role
    NEW.status := 'ready';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER books_sync_dmca_flags
  BEFORE INSERT OR UPDATE ON public.books
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_book_dmca_flags();

-- -----------------------------------------------------------------------------
-- ACID credit debit for book generation
-- Locks the user row FOR UPDATE, checks balance, decrements, inserts transaction.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.debit_credit_for_book_generation(
  p_user_id UUID,
  p_book_id UUID,
  p_amount INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_credits INTEGER;
  v_tx_id UUID;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'invalid_amount',
      'message', 'Amount must be a positive integer'
    );
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'forbidden',
      'message', 'Cannot debit another user'
    );
  END IF;

  SELECT credits
  INTO v_credits
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'user_not_found',
      'message', 'User profile does not exist'
    );
  END IF;

  IF v_credits < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'insufficient_credits',
      'message', 'Not enough credits',
      'credits', v_credits,
      'required', p_amount
    );
  END IF;

  IF p_book_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.books WHERE id = p_book_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'book_not_found',
      'message', 'Book does not exist'
    );
  END IF;

  UPDATE public.users
  SET credits = credits - p_amount
  WHERE id = p_user_id;

  INSERT INTO public.transactions (user_id, type, amount, metadata)
  VALUES (
    p_user_id,
    'book_generation',
    -p_amount,
    jsonb_build_object('book_id', p_book_id)
  )
  RETURNING id INTO v_tx_id;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'credits_remaining', v_credits - p_amount,
    'amount_debited', p_amount,
    'book_id', p_book_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.debit_credit_for_book_generation(UUID, UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.debit_credit_for_book_generation(UUID, UUID, INTEGER)
  TO authenticated, service_role;

-- Credit grant helper (service role / webhooks later). Not exposed to anon.
CREATE OR REPLACE FUNCTION public.credit_user_balance(
  p_user_id UUID,
  p_amount INTEGER,
  p_type public.transaction_type DEFAULT 'credit_purchase',
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_credits INTEGER;
  v_tx_id UUID;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_amount');
  END IF;

  UPDATE public.users
  SET credits = credits + p_amount
  WHERE id = p_user_id
  RETURNING credits INTO v_credits;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'user_not_found');
  END IF;

  INSERT INTO public.transactions (user_id, type, amount, metadata)
  VALUES (p_user_id, p_type, p_amount, COALESCE(p_metadata, '{}'::jsonb))
  RETURNING id INTO v_tx_id;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'credits', v_credits
  );
END;
$$;

REVOKE ALL ON FUNCTION public.credit_user_balance(UUID, INTEGER, public.transaction_type, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_user_balance(UUID, INTEGER, public.transaction_type, JSONB)
  TO service_role;

-- -----------------------------------------------------------------------------
-- Public catalog: ready books that are not DMCA-flagged
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.catalog_books
WITH (security_invoker = true)
AS
SELECT
  b.id,
  b.title,
  b.author,
  b.cover_url,
  b.status,
  b.created_at
FROM public.books b
WHERE b.status = 'ready'
  AND b.is_dmca_takedown = false
  AND b.status IS DISTINCT FROM 'dmca_flagged';

GRANT SELECT ON public.catalog_books TO anon, authenticated;

-- Helper: can the current user access a book (catalog or own library)?
CREATE OR REPLACE FUNCTION public.user_can_access_book(p_book_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.books b
    WHERE b.id = p_book_id
      AND (
        (
          b.status = 'ready'
          AND b.is_dmca_takedown = false
          AND b.status IS DISTINCT FROM 'dmca_flagged'
        )
        OR EXISTS (
          SELECT 1
          FROM public.library l
          WHERE l.book_id = b.id
            AND l.user_id = auth.uid()
        )
      )
  );
$$;

GRANT EXECUTE ON FUNCTION public.user_can_access_book(UUID) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.books ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chapters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;

-- Note: service_role bypasses RLS (used carefully from Next.js Route Handlers).
-- Do not FORCE RLS — SECURITY DEFINER credit RPCs must update users/transactions.

-- users: read/update own row only (billing fields blocked by trigger)
CREATE POLICY users_select_own
  ON public.users
  FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

CREATE POLICY users_update_own
  ON public.users
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- No INSERT/DELETE for authenticated — created by trigger / service role only

-- books: catalog-visible ready+non-dmca; library owners can see their books (incl. processing)
CREATE POLICY books_select_catalog
  ON public.books
  FOR SELECT
  TO authenticated
  USING (
    (
      status = 'ready'
      AND is_dmca_takedown = false
      AND status IS DISTINCT FROM 'dmca_flagged'
    )
    OR EXISTS (
      SELECT 1
      FROM public.library l
      WHERE l.book_id = books.id
        AND l.user_id = auth.uid()
    )
  );

-- Anonymous may only see public catalog rows
CREATE POLICY books_select_catalog_anon
  ON public.books
  FOR SELECT
  TO anon
  USING (
    status = 'ready'
    AND is_dmca_takedown = false
    AND status IS DISTINCT FROM 'dmca_flagged'
  );

-- Inserts/updates/deletes via service role (bypasses RLS) from Next.js Route Handlers.
-- No client INSERT policy on books by design.

-- chapters: readable if parent book is accessible under the same rules
CREATE POLICY chapters_select_if_book_accessible
  ON public.chapters
  FOR SELECT
  TO authenticated
  USING (public.user_can_access_book(book_id));

CREATE POLICY chapters_select_if_book_accessible_anon
  ON public.chapters
  FOR SELECT
  TO anon
  USING (public.user_can_access_book(book_id));

-- library: full CRUD on own rows only
CREATE POLICY library_select_own
  ON public.library
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY library_insert_own
  ON public.library
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY library_update_own
  ON public.library
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY library_delete_own
  ON public.library
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- transactions: SELECT own only; inserts via service role / SECURITY DEFINER only
CREATE POLICY transactions_select_own
  ON public.transactions
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- jobs: users can see their own job audit rows; writes via service role
CREATE POLICY jobs_select_own
  ON public.jobs
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Grants (table-level); RLS still applies
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT ON public.books TO anon, authenticated;
GRANT SELECT ON public.chapters TO anon, authenticated;

GRANT SELECT, UPDATE ON public.users TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.library TO authenticated;
GRANT SELECT ON public.transactions TO authenticated;
GRANT SELECT ON public.jobs TO authenticated;

-- service_role has full access by default in Supabase (bypasses RLS).
-- Documented: Next.js Route Handlers must use the service role carefully for
-- upload/generation paths (insert books/chapters, enqueue jobs, grant credits).

COMMENT ON FUNCTION public.debit_credit_for_book_generation IS
  'ACID credit debit for book generation. Locks user row, checks balance, writes transaction.';
COMMENT ON VIEW public.catalog_books IS
  'Public catalog excluding DMCA-flagged / non-ready books.';
COMMENT ON TABLE public.jobs IS
  'Optional audit trail; primary job queue is Redis (worker Paso 6).';
