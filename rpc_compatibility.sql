-- Compatibilidad para el index.html actual.
-- No elimina tablas ni registros. Solo crea alias para las funciones GM existentes.
begin;

drop function if exists public.approve_hold_submission(uuid, text);
drop function if exists public.observe_hold_submission(uuid, text);
drop function if exists public.reject_hold_submission(uuid, text);

create or replace function public.approve_hold_submission(
  p_submission_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.gm_approve_hold_submission(p_submission_id, p_note);
end;
$$;

create or replace function public.observe_hold_submission(
  p_submission_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.gm_observe_hold_submission(p_submission_id, p_note);
end;
$$;

create or replace function public.reject_hold_submission(
  p_submission_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.gm_reject_hold_submission(p_submission_id, p_note);
end;
$$;

grant execute on function public.approve_hold_submission(uuid, text) to authenticated;
grant execute on function public.observe_hold_submission(uuid, text) to authenticated;
grant execute on function public.reject_hold_submission(uuid, text) to authenticated;

notify pgrst, 'reload schema';
commit;
