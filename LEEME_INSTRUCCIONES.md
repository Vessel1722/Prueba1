# Vessel Games — Guía de despliegue (GitHub + Supabase)

Este paquete contiene tu sitio mejorado en **4 fases**. Sigue los pasos en orden.

## Archivos
- **`v1.html`** → tu sitio completo (súbelo a tu hosting / GitHub).
- **`supabase_setup_fase0.sql`** → script para tu base de datos (córrelo en Supabase).
- **`v1.backup-2026-07-23.html`** → respaldo del sitio ANTES de los cambios (no lo subas, es tu red de seguridad).

---

## PASO 1 — Base de datos (Supabase)
1. Entra a [supabase.com](https://supabase.com) → tu proyecto → **SQL Editor** → **New query**.
2. Abre `supabase_setup_fase0.sql`, copia **TODO** y pégalo. Dale **Run**.
   - Crea/ajusta tablas (`vg_users`, wallet, catálogo `products`), el trigger que crea el perfil al registrarse, la función `is_admin()` y la seguridad (RLS).
   - **No toca** tu sistema de pedidos/chat actual (para no romperlo).

## PASO 2 — Activar login por correo
1. **Authentication → Providers → Email** → asegúrate que esté **Enabled**.
2. Busca **"Confirm email"** y **desactívalo** (OFF) → **Save**.
   - Con esto el registro es directo. Si lo dejas ON, cada cliente tendrá que confirmar por correo antes de entrar.

## PASO 3 — Crear tu cuenta de administrador
1. Sube `v1.html` (Paso 4) y **regístrate** normal con tu correo de admin.
2. Vuelve al **SQL Editor** y corre esto (cambia el correo por el tuyo):
   ```sql
   update public.vg_users set is_admin = true
   where id = (select id from auth.users where email = 'TU-CORREO-ADMIN@ejemplo.com');
   ```
3. Ahora ese correo puede abrir el panel admin (botón ⚙ Admin). Sin `is_admin`, nadie entra.

## PASO 4 — Publicar el sitio
**Opción A — Subida manual:** reemplaza tu `v1.html` actual por el nuevo en tu hosting.

**Opción B — GitHub Pages:**
1. Crea un repositorio en GitHub.
2. **Renombra `v1.html` a `index.html`** y súbelo (o arrástralo en la web de GitHub → *Add file → Upload files*).
3. **Settings → Pages → Source: main / root → Save**. Tu sitio queda en `https://tu-usuario.github.io/tu-repo/`.
4. Para tu dominio `vesselgames.xyz`: en **Settings → Pages → Custom domain** pon el dominio y configura el DNS que te indique GitHub.

## PASO 5 — Migrar tu catálogo al panel (una sola vez)
1. Abre el panel **⚙ Admin** con tu cuenta de admin.
2. Toca **📦 Catálogo** → **"Migrar catálogo actual"**. Esto copia tus 53 productos a Supabase.
3. Desde ahí ya puedes **crear, editar y borrar** productos y se reflejan en la tienda.
   - Si NO migras, la tienda sigue usando el catálogo original (no pasa nada).

---

## Qué se arregló en cada fase
- **Fase 1 — Login:** reemplazado por **Supabase Auth (correo + contraseña)**. Se acabó el "no existe / ya existe" y ahora se puede entrar desde cualquier dispositivo. **Arreglado el logout en móvil** (botón "Salir" visible arriba).
- **Fase 2 — Admin seguro:** se quitó la contraseña que estaba **en texto plano en el HTML** y el PIN. Ahora el panel solo abre con una cuenta `is_admin` real.
- **Fase 3 — Catálogo:** ahora vive en Supabase con **alta/edición/borrado** desde el panel.
- **Fase 4 — Responsive:** tienda en **2 columnas en móvil**, botones más cómodos al tacto, sin scroll horizontal, y alineación pareja de tarjetas en escritorio.

## Checklist de prueba
- [ ] Registrarme con correo → entra directo al panel.
- [ ] Cerrar sesión con **"Salir"** (arriba) → sale bien.
- [ ] Entrar de nuevo con el mismo correo, **incluso desde otro dispositivo**.
- [ ] Abrir ⚙ Admin **sin** ser admin → lo bloquea.
- [ ] Marcar mi usuario como admin → ⚙ Admin abre.
- [ ] 📦 Catálogo → Migrar → editar un precio → verlo en la tienda.
- [ ] Ver la tienda en el celular → 2 columnas, todo proporcionado.

## Notas de seguridad (para después, opcional)
- Las tablas `orders` y comprobantes siguen con permisos abiertos (como estaban) para no romper el flujo de pedidos. Se pueden **endurecer** en una fase futura una vez que el login esté probado.
- El saldo de tokens todavía se actualiza desde el cliente; para blindarlo del todo conviene moverlo a funciones RPC en Supabase (fase futura).
