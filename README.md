# STAGE CONNECT — Web y gestor de licencias

Dos sitios, un solo proceso Node. Nginx enruta por dominio.

| Dominio | Que es |
|---|---|
| `stageconnect.entikmedia.com` | Web publica de producto |
| `app.entikmedia.com` | Gestor de licencias, privado y sin indexar |

## Subir al servidor

Desde tu Mac, un solo comando:

```bash
bash subir.sh root@dl120
```

Copia todo, instala dependencias, arranca el servicio, configura nginx
(apartando cualquier otro sitio que reclame esos dominios) y saca el
certificado con certbot. La primera vez pide la contrasena del panel.

Para actualizar mas adelante, el mismo comando.

## Estructura

```
server.js              Express: rutas y cabeceras de seguridad
lib/keygen.js          Generacion y validacion de claves
lib/security.js        Sesiones, bcrypt, bloqueo por fuerza bruta, auditoria
db/database.js         SQLite (WAL) y sentencias preparadas
routes/api.js          API que consume la app: activar, verificar, liberar
routes/auth.js         Login del panel
routes/admin.js        API del panel: keygen, licencias, solicitudes
public/index.html      Web publica
admin/index.html       Panel de gestion
nginx/                 Configuraciones de los dos dominios
scripts/deploy.sh      Despliegue en el servidor
scripts/generar-claves.sh  Crea el .env con secretos aleatorios
subir.sh               Sube y despliega desde tu Mac
```

## Formato de las claves

```
SCL-XXXX-XXXX-XXXXC    Vitalicia
SCM-XXXX-XXXX-XXXXC    Mensual
SCT-XXXX-XXXX-XXXXC    Prueba
```

Doce caracteres aleatorios del alfabeto `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
(sin I, O, 0 ni 1, para que nadie confunda un caracter al teclear).

El ultimo caracter es un digito de control HMAC-SHA256 derivado con
`LICENSE_SECRET`. Sirve para descartar erratas antes de consultar la base de
datos, y para que la app rechace codigos inventados sin conexion.

**`LICENSE_SECRET` no se puede cambiar despues de emitir licencias.** Si cambia,
el checksum de todas las claves ya entregadas deja de validar. Guarda una copia
en sitio seguro.

## Codigo de desbloqueo de emergencia

`KEEPTHEFAITH`

Va compilado en la aplicacion. Desbloquea todas las funciones sin contactar con
el servidor y sin caducidad. Existe para que un directo no dependa nunca de que
haya red o de que el servidor este en pie.

No aparece en la web ni en el panel. Se entrega verbalmente o por correo cuando
hay una incidencia.

Para cambiarlo: `Sources/SC6000ConnectApp/LicenseStore.swift`, constante
`masterCode`. Hay que recompilar la app.

## API que consume la aplicacion

| Ruta | Que hace |
|---|---|
| `POST /api/activate` | Canjea la clave y vincula el equipo |
| `POST /api/verify` | Latido: confirma que la licencia sigue viva |
| `POST /api/release` | Libera el equipo para usar la clave en otro |
| `GET /api/health` | Comprobacion de servicio |

El equipo se identifica por el `IOPlatformUUID` del Mac, que se guarda en la
base de datos como HMAC, nunca en claro.

La aplicacion **no bloquea nunca por falta de red**. Solo se desactiva ante una
negativa explicita del servidor (licencia revocada o caducada). Sin conexion,
timeout o error 5xx: sigue funcionando.

## Panel de gestion

- **Resumen** — activas, sin usar, equipos vinculados, solicitudes pendientes
- **Generar claves** — lote de hasta 500, con cliente, equipos y caducidad
- **Licencias** — buscar, editar, revocar, renovar, ver y liberar equipos
- **Solicitudes** — peticiones de la web; genera la clave desde la ficha
- **Actividad** — cada intento de activacion con resultado e IP
- **Registro** — auditoria de todo lo hecho en el panel
- **Sesiones** — accesos abiertos, revocables uno a uno o todos

### Seguridad del panel

- Contrasena con bcrypt (coste 12), nunca en texto plano
- Sesion JWT con el hash guardado en base de datos: revocable al instante
- Bloqueo de IP tras 5 intentos fallidos, 15 minutos
- Limite de peticiones en nginx: 5/min en login, 30/min en el resto
- Cookie httpOnly, secure y sameSite strict
- `noindex` en cabeceras y robots.txt
- Toda accion queda en la tabla de auditoria con IP y fecha
- Lista blanca de IP disponible en `nginx/app.entikmedia.com.conf`

## Variables de entorno

| Variable | Para que |
|---|---|
| `LICENSE_SECRET` | Firma del checksum de las claves. No cambiar. |
| `JWT_SECRET` | Firma de las sesiones del panel |
| `ADMIN_PASSWORD_HASH` | Hash bcrypt de la contrasena del panel |
| `SESSION_DAYS` | Duracion de la sesion (7 por defecto) |
| `MAX_LOGIN_FAILS` | Intentos antes de bloquear la IP (5) |
| `LOCKOUT_MINUTES` | Duracion del bloqueo (15) |
| `DB_PATH` | Ruta de la base SQLite |

`bash scripts/generar-claves.sh` las genera todas.

## Mantenimiento

```bash
pm2 logs stageconnect-web        # ver logs
pm2 restart stageconnect-web     # reiniciar
pm2 status                       # estado

# Copia de seguridad de la base de datos
sqlite3 /var/lib/stageconnect/stageconnect.db ".backup '/root/copia-$(date +%F).db'"
```

La base se limpia sola cada hora: caduca licencias vencidas, purga sesiones
antiguas e intentos de login de mas de un dia.

---

entikrecords.com
