-- GM Quality Holds v1.2
-- Corrección segura para el conflicto de columnas de las vistas.
-- No elimina tablas ni registros.

begin;

-- Asegura primero las columnas nuevas que usa la vista.
alter table if exists public.gm_holds
  add column if not exists pvi text;

alter table if exists public.gm_holds
  add column if not exists source_sheet text;

-- La vista de resumen depende de la vista activa; se elimina primero.
drop view if exists public.v_gm_hold_summary;
drop view if exists public.v_gm_active_holds;

-- No usar h.*: las columnas quedan estables aunque después se agreguen campos.
create view public.v_gm_active_holds as
select
  h.id,
  h.vin,
  h.hold_type,
  h.cause,
  h.held_at,
  h.location,
  h.responsible,
  h.status,
  h.days_hold_override,
  h.engine,
  h.transmission,
  h.sales_urgent,
  h.comments,
  h.source_submission_id,
  h.created_by,
  h.updated_by,
  h.created_at,
  h.updated_at,
  h.pvi,
  h.source_sheet,
  case
    when h.days_hold_override is not null then greatest(0, h.days_hold_override)
    when h.held_at is not null then greatest(0, current_date - h.held_at)
    else 0
  end::integer as age_days
from public.gm_holds h
where h.status = 'on_hold';

create view public.v_gm_hold_summary as
select
  hold_type,
  cause,
  count(*)::integer as units
from public.v_gm_active_holds
group by hold_type, cause
order by units desc;

-- Conserva el acceso de la aplicación autenticada.
grant select on public.v_gm_active_holds to authenticated;
grant select on public.v_gm_hold_summary to authenticated;

commit;
