# GM Quality Holds · Rayder → GM

MVP estático para GitHub Pages con Supabase. Reemplaza el `index.html` genérico de Vinculación Cultural por un portal de calidad enfocado en unidades Hold.

## Flujo operativo

1. Rayder inicia sesión con rol `rayder_uploader`.
2. Rayder sube un XLSX/XLS/CSV con el estándar `HOLD_STD_V1`.
3. Supabase guarda el archivo en un bucket privado y registra sus filas normalizadas.
4. Personal GM con rol `gm_validator` revisa el expediente.
5. GM puede observar, rechazar o aprobar.
6. Solo `approve_hold_submission()` publica las filas en `public.gm_holds`.
7. GM consulta el dashboard, edita holds con rol `gm_editor` y administra catálogos/usuarios con `admin`.

## Archivos

- `index.html`: frontend autocontenido; no depende de `./js/*.js` del proyecto anterior.
- `supabase_schema.sql`: tablas, RLS, Storage privado, auditoría y funciones de aprobación.

## Columnas del archivo estándar

Obligatorias: `VIN`, `hold_type`, `cause`.

Opcionales: `held_at`, `location`, `responsible`, `status`, `days_hold_override`, `engine`, `transmission`, `sales_urgent`, `comments`.

El lector acepta hojas cuyo nombre contenga `Holds Q1` o `Holds 4P`; si no encuentra esos nombres, inspecciona las hojas que tengan una fila de encabezados con `VIN` o `hold_type`.

## Configuración de Supabase

1. Crea un proyecto en Supabase.
2. Ejecuta todo `supabase_schema.sql` en SQL Editor.
3. En Authentication > Users crea o invita a los usuarios.
4. Asigna roles ejecutando los ejemplos del final del SQL.
5. En Authentication > URL Configuration agrega la URL local y la de GitHub Pages como Site URL/Redirect URL.
6. Abre la aplicación, entra a Configuración y captura Project URL + anon key.

La anon key puede estar en un frontend estático. La `service_role key` nunca debe aparecer en HTML, JavaScript, GitHub ni en el navegador.

## Prueba local

```bash
python3 -m http.server 8000
```

Abre `http://localhost:8000/index.html`.

## Publicar en GitHub Pages

### Crear repositorio desde GitHub

1. En GitHub pulsa **New repository**.
2. Nombre sugerido: `gm-quality-holds-rayder`.
3. Si contendrá datos reales, usa un repositorio privado o valida con Seguridad/IT antes de usar GitHub Pages público.
4. Sube `index.html` y `supabase_schema.sql`.
5. Ve a **Settings > Pages**.
6. Selecciona **Deploy from a branch**, rama `main`, carpeta `/root` y guarda.
7. Copia la URL generada y agrégala en Supabase Auth URL Configuration.

### Publicar por terminal

```bash
git init
git add index.html supabase_schema.sql README.md
git commit -m "Add Rayder to GM quality holds validation portal"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/gm-quality-holds-rayder.git
git push -u origin main
```

## Consideraciones de seguridad

- Rayder no consulta `public.gm_holds`; solo ve sus propios expedientes.
- GM consulta archivos y holds conforme a sus roles.
- El archivo original queda en Storage privado.
- La aprobación se ejecuta en una función `security definer`, no en una edición libre desde el navegador.
- Los VIN, comentarios y archivos de calidad pueden ser información sensible de operación. No los incluyas en un repositorio público.
- Para producción conviene agregar antivirus, límite de filas, versionado del estándar y una política de retención de archivos.


## Aislamiento respecto a tu proyecto anterior

El SQL usa objetos con prefijo `gm_` (`gm_holds`, `gm_hold_submissions`, `gm_user_profiles`, etc.) para no interferir con las tablas `v2.*` ni con otros objetos de tu aplicación existente.
