-- GM Quality Holds v1.4 · fuentes OLD_GA26 + reportes de junta
-- Ejecutar una sola vez después del esquema base y v1.3 fixed.
-- No elimina tablas ni registros. Recrea únicamente RPC con firmas compatibles.
begin;
create extension if not exists pgcrypto;

alter table if exists public.gm_hold_submissions
  add column if not exists source_kind text not null default 'holds_report',
  add column if not exists source_summary jsonb not null default '{}'::jsonb;
alter table if exists public.gm_hold_submission_rows
  add column if not exists pvi text,
  add column if not exists source_sheet text,
  add column if not exists vin_decision text not null default 'pending',
  add column if not exists vin_decision_note text,
  add column if not exists vin_decision_by uuid,
  add column if not exists vin_decision_at timestamptz;
alter table if exists public.gm_holds
  add column if not exists pvi text,
  add column if not exists source_submission_id uuid,
  add column if not exists source_sheet text;

-- El Excel real usa HQ5-HQ8, PS1 y BH1; ampliamos el catálogo permitido sin tocar filas.
do $$
declare v_constraint text;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid='public.gm_holds'::regclass
      and contype='c'
      and pg_get_constraintdef(oid) ilike '%hold_type%'
  loop
    execute format('alter table public.gm_holds drop constraint %I', v_constraint);
  end loop;
end $$;
alter table public.gm_holds
  add constraint gm_holds_hold_type_check
  check (hold_type in ('Q1','4P','HQ1','HQ2','HQ3','HQ4','HQ5','HQ6','HQ7','HQ8','SH1','LD','PS','PS1','BH1','OTHER'));

create table if not exists public.gm_report_rows (
  id bigint generated always as identity primary key,
  submission_id uuid not null references public.gm_hold_submissions(id) on delete cascade,
  row_number integer not null,
  source_sheet text not null,
  report_type text not null,
  vin text,
  pvi text,
  days_old numeric,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(submission_id, source_sheet, row_number)
);
create index if not exists gm_report_rows_submission_idx on public.gm_report_rows(submission_id);
create index if not exists gm_report_rows_type_idx on public.gm_report_rows(report_type);
create index if not exists gm_report_rows_vin_idx on public.gm_report_rows(vin);

-- GM validador también puede cargar; Rayder solo ve sus propios expedientes.
create or replace function public.gm_can_upload_hold_file()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.gm_user_profiles where id=auth.uid() and active=true and role in ('rayder_uploader','gm_editor','gm_validator','admin'));
$$;
grant execute on function public.gm_can_upload_hold_file() to authenticated;

-- Compatibilidad con cualquier firma anterior de validación por VIN.
drop function if exists public.gm_review_submission_row(bigint,text,text);
drop function if exists public.gm_review_submission_row(uuid,text,text);
create function public.gm_review_submission_row(p_row_id bigint,p_decision text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'No tienes permiso para validar VINs'; end if;
  if p_decision not in ('pending','approved','exception','rejected') then raise exception 'Decisión VIN no permitida'; end if;
  update public.gm_hold_submission_rows set vin_decision=p_decision,vin_decision_note=p_note,vin_decision_by=auth.uid(),vin_decision_at=now() where id=p_row_id;
  if not found then raise exception 'Fila de expediente no encontrada'; end if;
  return jsonb_build_object('ok',true,'row_id',p_row_id,'decision',p_decision);
end; $$;
grant execute on function public.gm_review_submission_row(bigint,text,text) to authenticated;

-- RPC de publicación: se recrean para evitar conflictos de tipo de retorno previos.
drop function if exists public.gm_approve_hold_submission(uuid,text);
drop function if exists public.gm_observe_hold_submission(uuid,text);
drop function if exists public.gm_reject_hold_submission(uuid,text);
create function public.gm_approve_hold_submission(p_submission_id uuid,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'Solo GM puede aprobar expedientes'; end if;
  if not exists(select 1 from public.gm_hold_submissions where id=p_submission_id and status in ('pending_review','observed')) then raise exception 'El expediente no está disponible para aprobación'; end if;
  if exists(select 1 from public.gm_hold_submission_rows where submission_id=p_submission_id and coalesce(array_length(validation_errors,1),0)>0 and coalesce(vin_decision,'pending') not in ('approved','exception')) then raise exception 'Existen filas con error sin excepción aprobada'; end if;
  insert into public.gm_holds(vin,pvi,hold_type,cause,held_at,location,responsible,status,days_hold_override,engine,transmission,sales_urgent,comments,source_submission_id,source_sheet,created_by,updated_by)
  select r.vin,r.pvi,r.hold_type,r.cause,r.held_at,r.location,r.responsible,'on_hold',r.days_hold_override,r.engine,r.transmission,r.sales_urgent,r.comments,r.submission_id,r.source_sheet,auth.uid(),auth.uid() from public.gm_hold_submission_rows r where r.submission_id=p_submission_id and coalesce(r.vin_decision,'pending')<>'rejected' and not exists(select 1 from public.gm_holds h where h.vin=r.vin and h.status='on_hold');
  update public.gm_hold_submissions set status='approved',review_comment=p_note,reviewed_by=auth.uid(),reviewed_at=now() where id=p_submission_id;
  return jsonb_build_object('ok',true,'submission_id',p_submission_id,'status','approved');
end; $$;
grant execute on function public.gm_approve_hold_submission(uuid,text) to authenticated;
create function public.gm_observe_hold_submission(p_submission_id uuid,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'Solo GM puede observar expedientes'; end if;
  update public.gm_hold_submissions set status='observed',review_comment=p_note,reviewed_by=auth.uid(),reviewed_at=now() where id=p_submission_id and status in ('pending_review','observed');
  if not found then raise exception 'El expediente no está disponible'; end if;
  return jsonb_build_object('ok',true,'submission_id',p_submission_id,'status','observed');
end; $$;
grant execute on function public.gm_observe_hold_submission(uuid,text) to authenticated;
create function public.gm_reject_hold_submission(p_submission_id uuid,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'Solo GM puede rechazar expedientes'; end if;
  update public.gm_hold_submissions set status='rejected',review_comment=p_note,reviewed_by=auth.uid(),reviewed_at=now() where id=p_submission_id and status in ('pending_review','observed');
  if not found then raise exception 'El expediente no está disponible'; end if;
  return jsonb_build_object('ok',true,'submission_id',p_submission_id,'status','rejected');
end; $$;
grant execute on function public.gm_reject_hold_submission(uuid,text) to authenticated;

alter table public.gm_report_rows enable row level security;
do $$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='gm_report_rows' and policyname='gm_report_rows_insert_owner') then
    create policy gm_report_rows_insert_owner on public.gm_report_rows for insert to authenticated with check (exists(select 1 from public.gm_hold_submissions s where s.id=submission_id and s.uploaded_by=auth.uid() and public.gm_can_upload_hold_file()));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='gm_report_rows' and policyname='gm_report_rows_select_gm_approved') then
    create policy gm_report_rows_select_gm_approved on public.gm_report_rows for select to authenticated using (exists(select 1 from public.gm_hold_submissions s where s.id=submission_id and s.status='approved') and public.gm_has_any_role(array['gm_editor','gm_validator','admin','viewer']));
  end if;
end $$;
notify pgrst,'reload schema';
commit;
