begin;

-- GM Quality Holds v1.3
-- Migración aditiva: no elimina tablas, filas ni vistas.
-- Ejecutar después del esquema base GM Quality Holds.

create extension if not exists pgcrypto;

-- Campos compatibles con las tablas base.
alter table if exists public.gm_user_profiles
  add column if not exists organization text,
  add column if not exists active boolean default true,
  add column if not exists role text default 'viewer';

alter table if exists public.gm_hold_submissions
  add column if not exists general_validation_status text default 'pending',
  add column if not exists submitted_at timestamptz,
  add column if not exists submitted_by uuid,
  add column if not exists reviewer_id uuid,
  add column if not exists reviewed_at timestamptz,
  add column if not exists published_at timestamptz,
  add column if not exists published_by uuid;

alter table if exists public.gm_hold_submission_rows
  add column if not exists id uuid default gen_random_uuid(),
  add column if not exists pvi text,
  add column if not exists source_sheet text,
  add column if not exists vin_decision text default 'pending',
  add column if not exists vin_decision_note text,
  add column if not exists vin_decision_by uuid,
  add column if not exists vin_decision_at timestamptz;

alter table if exists public.gm_holds
  add column if not exists pvi text,
  add column if not exists source_submission_id uuid,
  add column if not exists source_sheet text,
  add column if not exists created_by uuid,
  add column if not exists updated_by uuid;

create table if not exists public.gm_access_requests (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  full_name text not null,
  organization text,
  requested_role text not null default 'viewer',
  status text not null default 'pending',
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  assigned_role text,
  review_note text,
  claimed_at timestamptz
);

create index if not exists gm_access_requests_status_idx
  on public.gm_access_requests(status, requested_at desc);
create index if not exists gm_access_requests_email_idx
  on public.gm_access_requests(lower(email));
create index if not exists gm_submission_rows_vin_idx
  on public.gm_hold_submission_rows(vin);

-- Catálogo de roles y capacidades, visible para administración y documentación.
create table if not exists public.gm_role_permissions (
  role text primary key,
  can_dashboard boolean not null default false,
  can_upload boolean not null default false,
  can_edit_own_submission boolean not null default false,
  can_review boolean not null default false,
  can_edit_holds boolean not null default false,
  can_admin boolean not null default false
);

insert into public.gm_role_permissions(role, can_dashboard, can_upload, can_edit_own_submission, can_review, can_edit_holds, can_admin)
values
  ('viewer', true, false, false, false, false, false),
  ('rayder_uploader', false, true, true, false, false, false),
  ('gm_editor', true, true, true, true, true, false),
  ('gm_validator', true, true, true, true, false, false),
  ('admin', true, true, true, true, true, true)
on conflict (role) do update set
  can_dashboard = excluded.can_dashboard,
  can_upload = excluded.can_upload,
  can_edit_own_submission = excluded.can_edit_own_submission,
  can_review = excluded.can_review,
  can_edit_holds = excluded.can_edit_holds,
  can_admin = excluded.can_admin;

-- Funciones auxiliares para RLS y acciones administrativas.
create or replace function public.gm_current_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select role from public.gm_user_profiles where id = auth.uid() and active = true), 'anonymous');
$$;

create or replace function public.gm_has_any_role(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.gm_current_role() = any(p_roles);
$$;

create or replace function public.gm_request_access(
  p_email text,
  p_full_name text,
  p_organization text default null,
  p_requested_role text default 'viewer'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_role text := case when p_requested_role in ('viewer','rayder_uploader') then p_requested_role else 'viewer' end;
begin
  if nullif(trim(p_email), '') is null or nullif(trim(p_full_name), '') is null then
    raise exception 'Correo y nombre son obligatorios';
  end if;
  insert into public.gm_access_requests(email, full_name, organization, requested_role)
  values (lower(trim(p_email)), trim(p_full_name), nullif(trim(p_organization), ''), v_role)
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function public.gm_request_access(text,text,text,text) to anon, authenticated;

create or replace function public.gm_claim_approved_access(p_full_name text default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.email(), ''));
  v_user_id uuid := auth.uid();
  v_request public.gm_access_requests%rowtype;
  v_name text;
begin
  if v_user_id is null or v_email = '' then
    return false;
  end if;
  select * into v_request
  from public.gm_access_requests
  where lower(email) = v_email and status = 'approved'
  order by requested_at desc
  limit 1;
  if not found then
    return false;
  end if;
  v_name := coalesce(nullif(trim(p_full_name), ''), v_request.full_name, v_email);
  insert into public.gm_user_profiles(id, email, full_name, organization, role, active)
  values (v_user_id, v_email, v_name, v_request.organization, coalesce(v_request.assigned_role, v_request.requested_role, 'viewer'), true)
  on conflict (id) do update set
    email = excluded.email,
    full_name = excluded.full_name,
    organization = excluded.organization,
    role = excluded.role,
    active = true;
  update public.gm_access_requests
  set claimed_at = now()
  where id = v_request.id;
  return true;
end;
$$;

grant execute on function public.gm_claim_approved_access(text) to authenticated;

create or replace function public.gm_admin_set_user_role(p_user_id uuid, p_role text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gm_has_any_role(array['admin']) then raise exception 'Solo admin puede asignar roles'; end if;
  if p_role not in ('viewer','rayder_uploader','gm_editor','gm_validator','admin') then raise exception 'Rol no permitido'; end if;
  update public.gm_user_profiles set role = p_role, active = true where id = p_user_id;
  if not found then raise exception 'Usuario no encontrado'; end if;
  return true;
end;
$$;

grant execute on function public.gm_admin_set_user_role(uuid,text) to authenticated;

create or replace function public.gm_admin_set_user_active(p_user_id uuid, p_active boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gm_has_any_role(array['admin']) then raise exception 'Solo admin puede activar usuarios'; end if;
  update public.gm_user_profiles set active = p_active where id = p_user_id;
  if not found then raise exception 'Usuario no encontrado'; end if;
  return true;
end;
$$;

grant execute on function public.gm_admin_set_user_active(uuid,boolean) to authenticated;

create or replace function public.gm_admin_review_access_request(
  p_request_id uuid,
  p_decision text,
  p_role text default 'viewer',
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.gm_access_requests%rowtype;
  v_auth_id uuid;
  v_role text := case when p_role in ('viewer','rayder_uploader','gm_editor','gm_validator','admin') then p_role else 'viewer' end;
begin
  if not public.gm_has_any_role(array['admin']) then raise exception 'Solo admin puede resolver solicitudes'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Decisión no permitida'; end if;
  select * into v_request from public.gm_access_requests where id = p_request_id for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  update public.gm_access_requests
  set status = p_decision,
      assigned_role = case when p_decision = 'approved' then v_role else null end,
      review_note = p_note,
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = p_request_id;
  if p_decision = 'approved' then
    select id into v_auth_id from auth.users where lower(email) = lower(v_request.email) limit 1;
    if v_auth_id is not null then
      insert into public.gm_user_profiles(id, email, full_name, organization, role, active)
      values(v_auth_id, lower(v_request.email), v_request.full_name, v_request.organization, v_role, true)
      on conflict (id) do update set
        email = excluded.email,
        full_name = excluded.full_name,
        organization = excluded.organization,
        role = excluded.role,
        active = true;
    end if;
  end if;
  return true;
end;
$$;

grant execute on function public.gm_admin_review_access_request(uuid,text,text,text) to authenticated;

create or replace function public.gm_review_submission_row(
  p_row_id bigint,
  p_decision text,
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'No tienes permiso para validar VINs'; end if;
  if p_decision not in ('pending','approved','exception','rejected') then raise exception 'Decisión VIN no permitida'; end if;
  update public.gm_hold_submission_rows
  set vin_decision = p_decision,
      vin_decision_note = p_note,
      vin_decision_by = auth.uid(),
      vin_decision_at = now()
  where id = p_row_id;
  if not found then raise exception 'Fila de expediente no encontrada'; end if;
  return true;
end;
$$;

grant execute on function public.gm_review_submission_row(bigint,text,text) to authenticated;

-- La base v1.2 ya tiene estas funciones con retorno jsonb.
-- Se eliminan solo las funciones (no tablas ni datos) para permitir recrearlas.
drop function if exists public.gm_approve_hold_submission(uuid, text);
drop function if exists public.gm_observe_hold_submission(uuid, text);
drop function if exists public.gm_reject_hold_submission(uuid, text);

-- Publicación general: solo GM; filas con error requieren excepción aprobada.
create or replace function public.gm_approve_hold_submission(p_submission_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'Solo GM puede aprobar expedientes'; end if;
  if not exists (select 1 from public.gm_hold_submissions where id = p_submission_id and status in ('pending_review','observed')) then raise exception 'El expediente no está disponible para aprobación'; end if;
  if exists (select 1 from public.gm_hold_submission_rows where submission_id = p_submission_id and coalesce(array_length(validation_errors,1),0) > 0 and coalesce(vin_decision,'pending') not in ('approved','exception')) then
    raise exception 'Existen filas con error sin excepción aprobada';
  end if;
  insert into public.gm_holds(vin,pvi,hold_type,cause,held_at,location,responsible,status,days_hold_override,engine,transmission,sales_urgent,comments,source_submission_id,source_sheet,created_by,updated_by)
  select r.vin,r.pvi,r.hold_type,r.cause,r.held_at,r.location,r.responsible,'on_hold',r.days_hold_override,r.engine,r.transmission,r.sales_urgent,r.comments,r.submission_id,r.source_sheet,auth.uid(),auth.uid()
  from public.gm_hold_submission_rows r
  where r.submission_id = p_submission_id
    and coalesce(r.vin_decision,'pending') <> 'rejected'
    and not exists (select 1 from public.gm_holds h where h.vin = r.vin and h.status = 'on_hold');
  update public.gm_hold_submissions
  set status = 'approved', general_validation_status = 'approved', review_comment = p_note,
      reviewer_id = auth.uid(), reviewed_at = now(), published_at = now(), published_by = auth.uid()
  where id = p_submission_id;
  return jsonb_build_object('submission_id',p_submission_id,'status','approved');
end;
$$;

grant execute on function public.gm_approve_hold_submission(uuid,text) to authenticated;

create or replace function public.gm_observe_hold_submission(p_submission_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'Solo GM puede observar expedientes'; end if;
  update public.gm_hold_submissions
  set status='observed', general_validation_status='observed', review_comment=p_note, reviewer_id=auth.uid(), reviewed_at=now()
  where id=p_submission_id and status in ('pending_review','observed');
  if not found then raise exception 'El expediente no está disponible'; end if;
  return jsonb_build_object('submission_id',p_submission_id,'status','observed');
end;
$$;

grant execute on function public.gm_observe_hold_submission(uuid,text) to authenticated;

create or replace function public.gm_reject_hold_submission(p_submission_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gm_has_any_role(array['gm_editor','gm_validator','admin']) then raise exception 'Solo GM puede rechazar expedientes'; end if;
  update public.gm_hold_submissions
  set status='rejected', general_validation_status='rejected', review_comment=p_note, reviewer_id=auth.uid(), reviewed_at=now()
  where id=p_submission_id and status in ('pending_review','observed');
  if not found then raise exception 'El expediente no está disponible'; end if;
  return jsonb_build_object('submission_id',p_submission_id,'status','rejected');
end;
$$;

grant execute on function public.gm_reject_hold_submission(uuid,text) to authenticated;

-- RLS: las políticas nuevas son complementarias a las existentes.
alter table if exists public.gm_access_requests enable row level security;
alter table if exists public.gm_hold_submissions enable row level security;
alter table if exists public.gm_hold_submission_rows enable row level security;
alter table if exists public.gm_holds enable row level security;
alter table if exists public.gm_user_profiles enable row level security;
alter table if exists public.gm_role_permissions enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_access_requests' and policyname='gm_access_requests_public_insert') then
    create policy gm_access_requests_public_insert on public.gm_access_requests for insert to anon, authenticated with check (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_access_requests' and policyname='gm_access_requests_admin_select') then
    create policy gm_access_requests_admin_select on public.gm_access_requests for select to authenticated using (public.gm_has_any_role(array['admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_access_requests' and policyname='gm_access_requests_admin_update') then
    create policy gm_access_requests_admin_update on public.gm_access_requests for update to authenticated using (public.gm_has_any_role(array['admin'])) with check (public.gm_has_any_role(array['admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submissions' and policyname='gm_submissions_dual_upload') then
    create policy gm_submissions_dual_upload on public.gm_hold_submissions for insert to authenticated with check (uploaded_by = auth.uid() and public.gm_has_any_role(array['rayder_uploader','gm_editor','gm_validator','admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submissions' and policyname='gm_submissions_scope_select') then
    create policy gm_submissions_scope_select on public.gm_hold_submissions for select to authenticated using (uploaded_by = auth.uid() or public.gm_has_any_role(array['gm_editor','gm_validator','admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submissions' and policyname='gm_submissions_owner_edit') then
    create policy gm_submissions_owner_edit on public.gm_hold_submissions for update to authenticated using (uploaded_by = auth.uid() and status in ('pending_review','observed','rejected')) with check (uploaded_by = auth.uid() and status in ('pending_review','observed','rejected'));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submission_rows' and policyname='gm_submission_rows_owner_insert') then
    create policy gm_submission_rows_owner_insert on public.gm_hold_submission_rows for insert to authenticated with check (exists (select 1 from public.gm_hold_submissions s where s.id = submission_id and s.uploaded_by = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submission_rows' and policyname='gm_submission_rows_scope_select') then
    create policy gm_submission_rows_scope_select on public.gm_hold_submission_rows for select to authenticated using (exists (select 1 from public.gm_hold_submissions s where s.id = submission_id and (s.uploaded_by = auth.uid() or public.gm_has_any_role(array['gm_editor','gm_validator','admin']))));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submission_rows' and policyname='gm_submission_rows_owner_edit') then
    create policy gm_submission_rows_owner_edit on public.gm_hold_submission_rows for update to authenticated using (exists (select 1 from public.gm_hold_submissions s where s.id = submission_id and s.uploaded_by = auth.uid() and s.status in ('pending_review','observed','rejected'))) with check (exists (select 1 from public.gm_hold_submissions s where s.id = submission_id and s.uploaded_by = auth.uid() and s.status in ('pending_review','observed','rejected')));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_hold_submission_rows' and policyname='gm_submission_rows_gm_review') then
    create policy gm_submission_rows_gm_review on public.gm_hold_submission_rows for update to authenticated using (public.gm_has_any_role(array['gm_editor','gm_validator','admin'])) with check (public.gm_has_any_role(array['gm_editor','gm_validator','admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_holds' and policyname='gm_holds_gm_select') then
    create policy gm_holds_gm_select on public.gm_holds for select to authenticated using (public.gm_has_any_role(array['gm_editor','gm_validator','admin','viewer']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_holds' and policyname='gm_holds_gm_write') then
    create policy gm_holds_gm_write on public.gm_holds for all to authenticated using (public.gm_has_any_role(array['gm_editor','admin'])) with check (public.gm_has_any_role(array['gm_editor','admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='gm_role_permissions' and policyname='gm_role_permissions_authenticated_read') then
    create policy gm_role_permissions_authenticated_read on public.gm_role_permissions for select to authenticated using (true);
  end if;
end $$;

-- El bucket existente debe ser privado; el frontend solo sube mediante sesión autenticada.
insert into storage.buckets(id, name, public)
values ('hold-submissions-private','hold-submissions-private',false)
on conflict (id) do update set public = false;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='gm_hold_files_insert') then
    create policy gm_hold_files_insert on storage.objects for insert to authenticated
      with check (bucket_id='hold-submissions-private' and (storage.foldername(name))[1] = auth.uid()::text and public.gm_has_any_role(array['rayder_uploader','gm_editor','gm_validator','admin']));
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='gm_hold_files_select') then
    create policy gm_hold_files_select on storage.objects for select to authenticated
      using (bucket_id='hold-submissions-private' and ((storage.foldername(name))[1] = auth.uid()::text or public.gm_has_any_role(array['gm_editor','gm_validator','admin'])));
  end if;
end $$;

select 'GM Quality Holds v1.3 migration complete' as result;

commit;
