-- GM Quality Holds v1.2 - setup completo
-- Ejecutar este archivo completo en Supabase SQL Editor.
-- Incluye esquema base + campos operativos v1.2. Es idempotente.

-- GM Quality Holds · Rayder → GM validation gate
-- Ejecutar completo en Supabase > SQL Editor.
-- Nunca uses service_role key en index.html ni en GitHub.

create extension if not exists pgcrypto;

create table if not exists public.gm_user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique,
  full_name text,
  organization text not null default 'GM',
  role text not null default 'viewer' check (role in ('rayder_uploader','gm_editor','gm_validator','admin','viewer')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.gm_set_updated_at()
returns trigger language plpgsql security definer set search_path = public as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists gm_user_profiles_updated_at on public.gm_user_profiles;
create trigger gm_user_profiles_updated_at before update on public.gm_user_profiles
for each row execute function public.gm_set_updated_at();

create or replace function public.gm_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.gm_user_profiles (id,email,full_name,organization)
  values (new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',''),coalesce(new.raw_user_meta_data->>'organization','GM'))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists gm_on_auth_user_created on auth.users;
create trigger gm_on_auth_user_created after insert on auth.users
for each row execute function public.gm_handle_new_user();

create or replace function public.gm_has_role(p_role text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.gm_user_profiles
    where id = auth.uid() and active = true and (role = p_role or role = 'admin')
  );
$$;

create or replace function public.gm_is_gm_user()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.gm_user_profiles
    where id = auth.uid() and active = true
      and role in ('gm_editor','gm_validator','admin','viewer')
  );
$$;

create or replace function public.gm_can_upload_hold_file()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.gm_user_profiles
    where id = auth.uid() and active = true
      and role in ('rayder_uploader','gm_editor','admin')
  );
$$;

create table if not exists public.gm_hold_catalog (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  hold_type text not null,
  condition text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists gm_hold_catalog_updated_at on public.gm_hold_catalog;
create trigger gm_hold_catalog_updated_at before update on public.gm_hold_catalog
for each row execute function public.gm_set_updated_at();

create table if not exists public.gm_hold_submissions (
  id uuid primary key default gen_random_uuid(),
  file_name text not null,
  storage_path text not null unique,
  source_org text not null default 'Rayder',
  uploaded_by uuid not null references public.gm_user_profiles(id),
  status text not null default 'pending_review' check (status in ('pending_review','observed','approved','rejected','failed')),
  standard_version text not null default 'HOLD_STD_V1',
  row_count integer not null default 0 check (row_count >= 0),
  invalid_count integer not null default 0 check (invalid_count >= 0),
  review_comment text,
  reviewed_by uuid references public.gm_user_profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists gm_hold_submissions_updated_at on public.gm_hold_submissions;
create trigger gm_hold_submissions_updated_at before update on public.gm_hold_submissions
for each row execute function public.gm_set_updated_at();

create table if not exists public.gm_hold_submission_rows (
  id bigint generated always as identity primary key,
  submission_id uuid not null references public.gm_hold_submissions(id) on delete cascade,
  row_number integer not null,
  vin text not null,
  hold_type text not null,
  cause text not null,
  held_at date,
  location text,
  responsible text,
  status text not null default 'on_hold' check (status in ('on_hold','repaired','released','cancelled')),
  days_hold_override integer check (days_hold_override is null or days_hold_override >= 0),
  engine text,
  transmission text,
  sales_urgent boolean not null default false,
  comments text,
  validation_errors text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (submission_id,row_number)
);

create index if not exists hold_submission_rows_submission_idx on public.gm_hold_submission_rows(submission_id);
create index if not exists hold_submissions_status_idx on public.gm_hold_submissions(status);

create table if not exists public.gm_holds (
  id uuid primary key default gen_random_uuid(),
  vin text not null,
  hold_type text not null check (hold_type in ('Q1','4P','HQ1','HQ2','HQ3','HQ4','SH1','LD','PS','OTHER')),
  cause text not null,
  held_at date,
  location text,
  responsible text,
  status text not null default 'on_hold' check (status in ('on_hold','repaired','released','cancelled')),
  days_hold_override integer check (days_hold_override is null or days_hold_override >= 0),
  engine text,
  transmission text,
  sales_urgent boolean not null default false,
  comments text,
  source_submission_id uuid references public.gm_hold_submissions(id),
  created_by uuid references public.gm_user_profiles(id),
  updated_by uuid references public.gm_user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (vin,hold_type,cause)
);

create index if not exists holds_status_idx on public.gm_holds(status);
create index if not exists holds_type_idx on public.gm_holds(hold_type);
create index if not exists holds_held_at_idx on public.gm_holds(held_at);

drop trigger if exists gm_holds_updated_at on public.gm_holds;
create trigger gm_holds_updated_at before update on public.gm_holds
for each row execute function public.gm_set_updated_at();

create table if not exists public.gm_hold_history (
  id bigint generated always as identity primary key,
  hold_id uuid references public.gm_holds(id) on delete set null,
  submission_id uuid references public.gm_hold_submissions(id) on delete set null,
  action text not null,
  changed_by uuid references public.gm_user_profiles(id),
  changed_at timestamptz not null default now(),
  before_row jsonb,
  after_row jsonb,
  note text
);

create or replace function public.gm_audit_hold_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.gm_hold_history(hold_id,action,changed_by,after_row)
    values (new.id,'insert',auth.uid(),to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into public.gm_hold_history(hold_id,action,changed_by,before_row,after_row)
    values (new.id,'update',auth.uid(),to_jsonb(old),to_jsonb(new));
    return new;
  else
    insert into public.gm_hold_history(hold_id,action,changed_by,before_row)
    values (old.id,'delete',auth.uid(),to_jsonb(old));
    return old;
  end if;
end; $$;

drop trigger if exists gm_holds_audit on public.gm_holds;
create trigger gm_holds_audit after insert or update or delete on public.gm_holds
for each row execute function public.gm_audit_hold_changes();

create or replace function public.gm_approve_hold_submission(p_submission_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s public.gm_hold_submissions%rowtype;
  invalid_rows integer;
  imported_rows integer;
begin
  if not public.gm_has_role('gm_validator') then raise exception 'NOT_AUTHORIZED_FOR_APPROVAL'; end if;
  select * into s from public.gm_hold_submissions where id = p_submission_id for update;
  if not found then raise exception 'SUBMISSION_NOT_FOUND'; end if;
  if s.status not in ('pending_review','observed') then raise exception 'SUBMISSION_NOT_REVIEWABLE'; end if;

  select count(*) into invalid_rows
  from public.gm_hold_submission_rows
  where submission_id = p_submission_id and cardinality(validation_errors) > 0;
  if invalid_rows > 0 then raise exception 'SUBMISSION_HAS_INVALID_ROWS:%', invalid_rows; end if;

  insert into public.gm_holds (
    vin,hold_type,cause,held_at,location,responsible,status,days_hold_override,
    engine,transmission,sales_urgent,comments,source_submission_id,created_by,updated_by
  )
  select vin,hold_type,cause,held_at,location,responsible,status,days_hold_override,
         engine,transmission,sales_urgent,comments,p_submission_id,auth.uid(),auth.uid()
  from public.gm_hold_submission_rows
  where submission_id = p_submission_id
  on conflict (vin,hold_type,cause) do update set
    held_at = excluded.held_at,
    location = excluded.location,
    responsible = excluded.responsible,
    status = excluded.status,
    days_hold_override = excluded.days_hold_override,
    engine = excluded.engine,
    transmission = excluded.transmission,
    sales_urgent = excluded.sales_urgent,
    comments = excluded.comments,
    source_submission_id = excluded.source_submission_id,
    updated_by = auth.uid(),
    updated_at = now();

  get diagnostics imported_rows = row_count;
  update public.gm_hold_submissions
  set status = 'approved', review_comment = p_note, reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_submission_id;

  insert into public.gm_hold_history(submission_id,action,changed_by,after_row,note)
  values (p_submission_id,'submission_approved',auth.uid(),jsonb_build_object('rows_imported',imported_rows),p_note);

  return jsonb_build_object('submission_id',p_submission_id,'status','approved','rows_imported',imported_rows);
end; $$;

create or replace function public.gm_observe_hold_submission(p_submission_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.gm_has_role('gm_validator') then raise exception 'NOT_AUTHORIZED_FOR_REVIEW'; end if;
  update public.gm_hold_submissions
  set status = 'observed', review_comment = nullif(trim(p_note),''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_submission_id and status in ('pending_review','observed');
  if not found then raise exception 'SUBMISSION_NOT_REVIEWABLE'; end if;
  insert into public.gm_hold_history(submission_id,action,changed_by,note)
  values (p_submission_id,'submission_observed',auth.uid(),p_note);
  return jsonb_build_object('submission_id',p_submission_id,'status','observed');
end; $$;

create or replace function public.gm_reject_hold_submission(p_submission_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.gm_has_role('gm_validator') then raise exception 'NOT_AUTHORIZED_FOR_REVIEW'; end if;
  update public.gm_hold_submissions
  set status = 'rejected', review_comment = nullif(trim(p_note),''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_submission_id and status in ('pending_review','observed');
  if not found then raise exception 'SUBMISSION_NOT_REVIEWABLE'; end if;
  insert into public.gm_hold_history(submission_id,action,changed_by,note)
  values (p_submission_id,'submission_rejected',auth.uid(),p_note);
  return jsonb_build_object('submission_id',p_submission_id,'status','rejected');
end; $$;

create or replace view public.v_gm_active_holds as
select h.*, greatest(0, coalesce(current_date - h.held_at, h.days_hold_override, 0))::integer as age_days
from public.gm_holds h where h.status = 'on_hold';

create or replace view public.v_gm_hold_summary as
select hold_type,cause,count(*)::integer as units
from public.v_gm_active_holds group by hold_type,cause order by units desc;

-- Bucket privado para archivos originales. El nombre se usa también en index.html.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('hold-submissions-private','hold-submissions-private',false,52428800,
  array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-excel','text/csv'])
on conflict (id) do update set public=false,file_size_limit=52428800;

alter table public.gm_user_profiles enable row level security;
alter table public.gm_hold_catalog enable row level security;
alter table public.gm_hold_submissions enable row level security;
alter table public.gm_hold_submission_rows enable row level security;
alter table public.gm_holds enable row level security;
alter table public.gm_hold_history enable row level security;

drop policy if exists gm_profiles_select_self_or_gm on public.gm_user_profiles;
create policy gm_profiles_select_self_or_gm on public.gm_user_profiles for select to authenticated
using (id = auth.uid() or public.gm_has_role('gm_editor') or public.gm_has_role('gm_validator'));
drop policy if exists gm_profiles_update_admin on public.gm_user_profiles;
create policy gm_profiles_update_admin on public.gm_user_profiles for update to authenticated
using (public.gm_has_role('admin')) with check (public.gm_has_role('admin'));

drop policy if exists gm_catalog_select_authenticated on public.gm_hold_catalog;
create policy gm_catalog_select_authenticated on public.gm_hold_catalog for select to authenticated using (auth.uid() is not null);
drop policy if exists gm_catalog_insert_admin on public.gm_hold_catalog;
create policy gm_catalog_insert_admin on public.gm_hold_catalog for insert to authenticated with check (public.gm_has_role('admin'));
drop policy if exists gm_catalog_update_admin on public.gm_hold_catalog;
create policy gm_catalog_update_admin on public.gm_hold_catalog for update to authenticated using (public.gm_has_role('admin')) with check (public.gm_has_role('admin'));

drop policy if exists gm_submissions_select_owner_or_gm on public.gm_hold_submissions;
create policy gm_submissions_select_owner_or_gm on public.gm_hold_submissions for select to authenticated
using (uploaded_by = auth.uid() or public.gm_has_role('gm_validator'));
drop policy if exists gm_submissions_insert_uploader on public.gm_hold_submissions;
create policy gm_submissions_insert_uploader on public.gm_hold_submissions for insert to authenticated
with check (uploaded_by = auth.uid() and public.gm_can_upload_hold_file() and status = 'pending_review' and reviewed_by is null);
-- Las transiciones de revisión ocurren exclusivamente mediante funciones security definer.
drop policy if exists gm_submissions_update_owner_pending on public.gm_hold_submissions;

drop policy if exists gm_submission_rows_select_owner_or_gm on public.gm_hold_submission_rows;
create policy gm_submission_rows_select_owner_or_gm on public.gm_hold_submission_rows for select to authenticated
using (exists (select 1 from public.gm_hold_submissions s where s.id = submission_id and (s.uploaded_by = auth.uid() or public.gm_is_gm_user())));
drop policy if exists gm_submission_rows_insert_owner on public.gm_hold_submission_rows;
create policy gm_submission_rows_insert_owner on public.gm_hold_submission_rows for insert to authenticated
with check (exists (select 1 from public.gm_hold_submissions s where s.id = submission_id and s.uploaded_by = auth.uid() and s.status in ('pending_review','observed') and public.gm_can_upload_hold_file()));

drop policy if exists gm_holds_select_gm on public.gm_holds;
create policy gm_holds_select_gm on public.gm_holds for select to authenticated using (public.gm_is_gm_user());
drop policy if exists gm_holds_insert_gm_editor on public.gm_holds;
create policy gm_holds_insert_gm_editor on public.gm_holds for insert to authenticated with check (public.gm_has_role('gm_editor'));
drop policy if exists gm_holds_update_gm_editor on public.gm_holds;
create policy gm_holds_update_gm_editor on public.gm_holds for update to authenticated using (public.gm_has_role('gm_editor')) with check (public.gm_has_role('gm_editor'));
drop policy if exists gm_holds_delete_admin on public.gm_holds;
create policy gm_holds_delete_admin on public.gm_holds for delete to authenticated using (public.gm_has_role('admin'));

drop policy if exists gm_history_select_gm on public.gm_hold_history;
create policy gm_history_select_gm on public.gm_hold_history for select to authenticated using (public.gm_is_gm_user());

drop policy if exists gm_storage_insert_own_submission on storage.objects;
create policy gm_storage_insert_own_submission on storage.objects for insert to authenticated
with check (bucket_id = 'hold-submissions-private' and name like auth.uid()::text || '/%');
drop policy if exists gm_storage_select_submission_owner_or_gm on storage.objects;
create policy gm_storage_select_submission_owner_or_gm on storage.objects for select to authenticated
using (bucket_id = 'hold-submissions-private' and (name like auth.uid()::text || '/%' or public.gm_has_role('gm_validator')));
drop policy if exists gm_storage_delete_own_submission on storage.objects;
create policy gm_storage_delete_own_submission on storage.objects for delete to authenticated
using (bucket_id = 'hold-submissions-private' and name like auth.uid()::text || '/%');

insert into public.gm_hold_catalog(code,name,hold_type,condition) values
('QH1','Defectos de calidad','Q1','Quality hold'),
('HQ2','Puntos sueltos caja','Q1','Pendiente revisión'),
('HQ3','Brazo de control y maza','Q1','Pendiente reparación'),
('HQ4','Birlos / tuercas ATS','Q1','Pendiente revisión'),
('4P','Return to Plant','4P','Pendiente reparación'),
('SH1','Campaña / proveedor','SH1','Pendiente seguimiento'),
('LD','Daño de logística','LD','Logística / calidad'),
('PS1','Faltante de parte','PS','En proceso')
on conflict (code) do update set name=excluded.name,hold_type=excluded.hold_type,condition=excluded.condition,active=true;

-- Después de crear usuarios en Authentication > Users, asigna roles:
-- update public.gm_user_profiles set role='admin', organization='GM' where email='tu-correo@gm.com';
-- update public.gm_user_profiles set role='gm_validator', organization='GM' where email='validador@gm.com';
-- update public.gm_user_profiles set role='rayder_uploader', organization='Rayder' where email='usuario@rayder.com';


-- GM Quality Holds v1.2: compatibility and operational fields
-- Run only after the original GM gm_* schema exists. This migration is additive.
alter table if exists public.gm_holds add column if not exists pvi text;
alter table if exists public.gm_holds add column if not exists source_sheet text;
alter table if exists public.gm_hold_submission_rows add column if not exists sheet_name text;
alter table if exists public.gm_hold_submission_rows add column if not exists pvi text;
create index if not exists gm_holds_type_status_idx on public.gm_holds(hold_type,status);
create index if not exists gm_holds_held_at_idx on public.gm_holds(held_at);
create index if not exists gm_submission_rows_submission_idx on public.gm_hold_submission_rows(submission_id);
