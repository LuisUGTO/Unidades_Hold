-- GM Quality Holds v1.2: compatibility and operational fields
-- Run only after the original GM gm_* schema exists. This migration is additive.
alter table if exists public.gm_holds add column if not exists pvi text;
alter table if exists public.gm_holds add column if not exists source_sheet text;
alter table if exists public.gm_hold_submission_rows add column if not exists sheet_name text;
alter table if exists public.gm_hold_submission_rows add column if not exists pvi text;
create index if not exists gm_holds_type_status_idx on public.gm_holds(hold_type,status);
create index if not exists gm_holds_held_at_idx on public.gm_holds(held_at);
create index if not exists gm_submission_rows_submission_idx on public.gm_hold_submission_rows(submission_id);
