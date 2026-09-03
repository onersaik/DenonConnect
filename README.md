# STAGE CONNECT

**STAGE CONNECT · ENTIK MEDIA**

## Qué es

STAGE CONNECT es una utilidad de sincronización y timecode para cabina de DJ.
Corre en macOS y habla dos protocolos de red completamente independientes:
**Denon StageLinq** (reproductores SC6000 / Engine OS) y **Pioneer / AlphaTheta
Pro DJ Link** (CDJ). Muestra en vivo título, artista, BPM, key, estado de
reproducción, beat y quién es el master de cada plato, y saca esa información
como LTC/MTC/OSC, un panel web local y overlays para OBS. La app viene
acompañada de **STAGE CONNECT para iPad**, una app-monitor complementaria que
recibe ese mismo estado en tiempo real para verlo desde cabina o desde el
público.

## Compilar

Todo se compila desde la raíz del repo con Swift Package Manager. No hace
falta abrir Xcode a mano para los pasos normales.

- **`build_all.sh`** — build completo: compila el `.app` de macOS (release),
  genera el `.pkg` de instalación, el `.dmg` y, si Xcode está totalmente
  configurado en el Mac (con firma de desarrollador), también el `.ipa` de
  iPad. Admite `--sin-ipa` para saltarse ese último paso y compilar más
  rápido.

  ```bash
  bash build_all.sh
  bash build_all.sh --sin-ipa
  ```

- **`build_ipa.sh`** — compila y firma solo el `.ipa` de iPad desde el Mac
  local, detectando automáticamente el Team ID de Apple Developer instalado
  en el llavero.

  ```bash
  bash build_ipa.sh
  ```

### IPA firmado en la nube (sin depender del Xcode local)

El workflow de GitHub Actions **`.github/workflows/build-ipa.yml`** archiva y
firma el `.ipa` de iPad en un runner macOS de GitHub, para los casos en que el
Xcode local no tiene capacidad completa de archivado para iOS. Necesita 5
secrets configurados en el repo (`Settings → Secrets and variables →
Actions`):

- `IOS_DIST_SIGNING_CERT_P12_BASE64`
- `IOS_DIST_SIGNING_CERT_PASSWORD`
- `IOS_PROVISION_PROFILE_BASE64`
- `KEYCHAIN_PASSWORD`
- `APPLE_TEAM_ID`

El propio archivo del workflow documenta, en sus comentarios iniciales, cómo
generar cada uno de estos secrets paso a paso desde el Mac.

## Licencias

El modelo de licencia se resuelve contra un servidor de activación, con
funcionamiento sin red una vez validada la clave la primera vez:

- **Mensual** — 1 dispositivo vinculado.
- **Vitalicia** — 2 dispositivos vinculados.

El cliente puede liberar un dispositivo por su cuenta desde un portal de
autoservicio, para poder mover la licencia a otro equipo sin tener que
escribir a soporte. La lógica de activación, verificación de licencia y
liberación de dispositivo vive en `Sources/SC6000ConnectApp/LicenseStore.swift`.

## Idiomas soportados

La app tiene selector de idioma en tiempo de ejecución con 11 idiomas
completos:

Español, English, Français, Italiano, 中文 (chino), 日本語 (japonés), ภาษาไทย
(tailandés), Deutsch, Català, Galego y Euskera.

## Dónde quedan los entregables

`build_all.sh` deja todo lo compilado listo para entregar en:

```
~/Desktop/STAGE CONNECT/
```

incluyendo `STAGE CONNECT.app`, el `.pkg` de instalación, el `.dmg` y, cuando
corresponde, el `.ipa` de iPad.
