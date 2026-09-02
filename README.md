# SC6000 Connect — App nativa (SwiftUI)

App nativa de macOS (sin terminal, ventana propia con icono en el Dock) que
descubre tus Denon SC6000 en la red StageLinq, se conecta y muestra en vivo
los 4 decks lógicos (Deck1‑A/B, Deck2‑A/B): pista, artista, key, BPM, estado
de reproducción, loop, key lock, volumen y **posición de beat en tiempo real**
(servicio BeatInfo — el mismo dato que usan cosas como Resolume/ShowKontrol
para sincronizarse al ritmo).

## ⚠️ Léeme primero — estado honesto de este código

Este proyecto está **escrito pero no compilado**. En este entorno (sandbox
en la nube) no existe ningún compilador de Swift, así que no he podido
ejecutar `swift build` ni abrirlo en Xcode para confirmar que compila sin
errores. Repasé el código a mano con mucho cuidado (tipos, firmas, hilos,
sintaxis de SwiftUI) y corregí varios problemas que encontré así, pero es
posible que Xcode marque 1 o 2 errores menores al compilar por primera vez
(typos, algún paréntesis, alguna API que cambió de nombre entre versiones
de macOS/Swift).

**Si Xcode te muestra un error al compilar, cópiame el mensaje de error
completo (archivo + línea + texto) y lo arreglo en el momento.** Suelen ser
correcciones de 1 línea.

El protocolo en sí (StageLinq: descubrimiento UDP, StateMap, BeatInfo) está
verificado contra la implementación de referencia
[chrisle/StageLinq](https://github.com/chrisle/StageLinq) — esa parte no es
adivinada, es una traducción directa del comportamiento real del protocolo.
Lo no verificado es únicamente la compilación en Swift/SwiftUI.

## Qué incluye (alcance elegido)

- **Descubrimiento UDP** (puerto 51337) de dispositivos StageLinq.
- **StateMap completo**: las 47 rutas de estado por deck + rutas globales
  (master tempo, crossfader, canales, etc.), igual que la app de referencia.
- **BeatInfo en vivo**: posición de beat exacta por deck, usada para la
  barra de progreso y el pulso visual sincronizado.
- **NO incluye** exploración de librería / FileTransfer (decidiste dejarlo
  fuera del alcance).

## Cómo abrirlo y ejecutarlo

1. Abre **Xcode** (gratis, desde la App Store si no lo tienes).
2. `Archivo → Abrir…` y selecciona el archivo `Package.swift` de esta
   carpeta (Xcode lo abre como proyecto Swift Package automáticamente, no
   hace falta crear un `.xcodeproj`).
3. En la parte superior, elige el esquema **SC6000ConnectApp** → **My Mac**.
4. Pulsa ▶️ (Run). Se abrirá una ventana nativa (no una terminal) que empieza
   a escuchar en la red automáticamente.

No necesitas tocar nada más: no hay dependencias externas, todo el
protocolo está escrito desde cero sobre sockets BSD estándar de macOS.

## Icono de la app

En la carpeta `Resources/` incluyo el mismo icono original (no es el logo
real de Denon, es un diseño propio estilo plato/vinilo con acento naranja)
que usé para `ConnectApp.app`, en dos formatos:

- `icon_1024.png` — imagen base.
- `AppIcon.icns` — ya convertido a formato de icono de macOS.

Ejecutado directamente desde Xcode con `swift run`/▶️, macOS mostrará el
icono genérico de Swift en el Dock (SwiftPM puro no arrastra icono
automáticamente). Si quieres el icono naranja en el Dock:

1. En Xcode, ve al target **SC6000ConnectApp** → pestaña **General**.
2. En "App Icons and Launch Images", arrastra `icon_1024.png` al icono
   de 1024×1024 del **App Icon** set (Xcode genera el resto de tamaños
   solo). Si Xcode no te deja (por ser SPM puro), dímelo y te preparo una
   versión con `.xcassets` ya integrado en el paquete.

## Red

Tus SC6000 y este Mac deben estar en el mismo segmento de red (mismo
switch/VLAN, o mismo WiFi si conectas por WiFi) para que llegue el
broadcast UDP de descubrimiento.

## Sobre Resolume / "estilo ShowKontrol"

Resolume no lee esta app directamente — Resolume tiene su **propio**
soporte de entrada nativo para Denon StageLinq/Engine OS (en sus
preferencias de entrada), independiente de esta aplicación: ambos son
clientes StageLinq separados escuchando el mismo anuncio de red de tus
SC6000, así que no interfieren entre sí. Si Resolume no detecta los decks,
lo primero a revisar suele ser: (1) que Resolume y los SC6000 estén en la
misma red/switch, (2) que el firewall de macOS no esté bloqueando el
puerto UDP 51337, (3) reiniciar el descubrimiento en Resolume tras encender
los reproductores (a veces el orden de arranque importa). Esta app te sirve
en paralelo como panel de estado/diagnóstico "estilo ShowKontrol": ves en
vivo lo mismo que verían tus reproductores, útil para confirmar que la red
funciona antes de depurar Resolume.

## Estructura del proyecto

```
Package.swift
Sources/
  StageLinqKit/        ← librería: protocolo, sockets, modelos, servicios
    ByteIO.swift          lectura/escritura binaria Big Endian
    Sockets.swift         sockets BSD (UDP/TCP) crudos
    Protocol.swift        constantes del protocolo + framing de descubrimiento
    StatePaths.swift      las 47 rutas de estado por deck + rutas globales
    StateValue.swift      decodificación del JSON embebido de StateMap
    Models.swift          DeckState / StageLinqDevice (ObservableObject)
    NetworkDevice.swift    conexión TCP principal (anuncio de servicios)
    ServiceConnection.swift framing común de los servicios (StateMap/BeatInfo)
    StateMapService.swift  suscripción y parseo de StateMap
    BeatInfoService.swift  suscripción y parseo de BeatInfo
    StageLinqManager.swift orquestador: descubrimiento + conexiones + estado
  SC6000ConnectApp/    ← interfaz SwiftUI
    SC6000ConnectApp.swift punto de entrada
    ContentView.swift      ventana principal (sidebar + grid 2×2 + log)
    DeckCardView.swift     tarjeta de cada deck
    SidebarView.swift      lista de dispositivos
    LogView.swift          panel de log de protocolo
    Theme.swift             paleta de colores
Resources/
  icon_1024.png, AppIcon.icns
```
