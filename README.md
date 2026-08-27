# GM Quality Holds v1.4

## Qué cambió
- `OLD_GA26` se detecta por nombre/encabezados y se guarda como `old_orders`; nunca se convierte automáticamente en Q1.
- `1.-Holds Enero 2026.xlsx` se separa por hojas: Holds Q1, Holds 4P, motores/transmisiones, prioridad de ventas, antiguas, urgentes, eventos, Jazmin y Blenda.
- El dashboard muestra Holds aprobados, aging OLD_GA26, motores/transmisiones, ventas urgentes y tendencia.
- Se conservan login, magic link, roles, solicitudes de acceso, administración, edición propia, validación por VIN, proyectos, exportación y logos GM.

## Despliegue seguro
1. Ejecuta `supabase_migration_v1_4.sql` una sola vez en Supabase.
2. Reemplaza únicamente `index.html` en la raíz de GitHub.
3. Conserva `gm-symbol-white-dark-bg-web.png` y `General-Motors-GM-Logo.png` en la raíz.
4. Recarga GitHub Pages con `Ctrl + F5`.

## Prueba recomendada
1. Usa una cuenta GM con rol `admin` o `gm_validator`.
2. Carga primero una copia de prueba de `OLD_GA26`; verifica que el resumen diga `OLD_GA26`, no Q1.
3. Carga una copia del Excel de Holds; verifica hojas y filas reconocidas.
4. Revisa el expediente y aprueba.
5. Confirma que el dashboard cuente Holds y OLD_GA26 en indicadores distintos.

No subas `service_role`, contraseñas ni archivos con VINs reales a un repositorio público.
