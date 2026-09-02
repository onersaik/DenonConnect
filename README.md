# SC6000 Connect

App nativa de macOS (ventana propia, sin terminal) que muestra en vivo el estado
de tus reproductores de DJ en red:

- **Denon SC6000 / Engine OS** por **StageLinq** — los 4 decks lógicos
  (Deck1‑A/B, Deck2‑A/B) con pista, artista, key, género, BPM, play/pausa, loop,
  key lock, volumen y **posición de beat en tiempo real**.
- **Pioneer / AlphaTheta CDJ‑3000** (y CDJ‑2000NXS2, XDJ, DJM) por
  **Pro DJ Link** — BPM real con el pitch aplicado, pitch %, play/cue/loop,
  master, sync, on‑air y beat dentro del compás.

Son dos protocolos completamente distintos e independientes; la app habla los
dos a la vez y los muestra en la misma ventana.

## Estado

✅ **Compila y empaqueta correctamente** en macOS (Swift 5.10, verificado en CI
sobre un Mac real: debug y release, sin warnings de código).

## Cómo conseguir la app lista para usar

Cada push al repositorio genera automáticamente la app ya empaquetada:

1. Entra en la pestaña **Actions** del repositorio.
2. Abre la ejecución más reciente (la de arriba, en verde).
3. Abajo del todo, en **Artifacts**, descarga **SC6000-Connect-app**.
4. Descomprime y arrastra `SC6000 Connect.app` a tu carpeta de Aplicaciones.

### Primera ejecución — dos avisos de macOS

**1. Gatekeeper.** La app no está firmada con una cuenta de desarrollador de
Apple, así que al abrirla por doble clic macOS dirá que no puede verificar al
desarrollador. Solución: **clic derecho sobre la app → Abrir → Abrir**. Solo la
primera vez. Si aún así se resiste:

```bash
xattr -dr com.apple.quarantine "/Applications/SC6000 Connect.app"
```

**2. Permiso de red local.** macOS pedirá permiso para "buscar dispositivos en
la red local". **Hay que aceptarlo**: sin él la app no ve ni los SC6000 ni los
CDJ. Si lo rechazaste por error, se reactiva en Ajustes del Sistema →
Privacidad y seguridad → Red local.

## Compilar desde el código

```bash
swift build -c release      # desde la terminal
```

O abre `Package.swift` con Xcode, elige el esquema **SC6000ConnectApp → My Mac**
y pulsa ▶️.

## Red

Tus reproductores y este Mac deben estar en el mismo segmento de red (mismo
switch o mismo WiFi) para que lleguen los paquetes de descubrimiento por
broadcast.

Puertos que usa la app:

| Puerto | Protocolo | Uso |
|---|---|---|
| 51337 UDP | StageLinq | descubrimiento de SC6000 |
| (dinámico) TCP | StageLinq | StateMap y BeatInfo |
| 50000 UDP | Pro DJ Link | presencia de CDJ + nuestro anuncio |
| 50002 UDP | Pro DJ Link | estado detallado de los CDJ |

Si tienes **rekordbox abierto** en el mismo Mac, ocupará los puertos de Pro DJ
Link y la app no verá los CDJ. Cierra rekordbox si quieres ver los CDJ aquí.

Para que los CDJ envíen estado detallado, la app se anuncia en la red como
reproductor virtual número **7** (fuera del rango 1–6 que usan los
reproductores reales, para no provocar conflictos de número de player).

## Qué muestra cada protocolo, y qué no

**SC6000 (StageLinq):** todo — título, artista, key, género, BPM, estado, loop,
key lock, volumen y beat. Las 47 rutas de estado por deck están suscritas.

**CDJ‑3000 (Pro DJ Link):** todo el estado de reproducción (BPM efectivo, pitch,
play/cue/loop, master, sync, on‑air, beat del compás, slot de origen) **pero no
el título ni el artista**. Eso es una limitación del protocolo: el CDJ solo
envía el ID de la pista en su base de datos, y obtener el nombre requiere
implementar además el cliente TCP de consultas a la base de datos del
reproductor (`dbserver`), que es un proyecto aparte considerablemente mayor.

## Sobre Resolume

Resolume no lee esta app: tiene su **propio** soporte nativo de entrada para
StageLinq y Pro DJ Link en sus preferencias. Ambos son clientes independientes
escuchando los mismos anuncios de red, así que conviven sin interferir. Si
Resolume no detecta los decks, revisa: misma red/switch, cortafuegos de macOS
sin bloquear los puertos de arriba, y reiniciar el descubrimiento en Resolume
después de encender los reproductores. Esta app te sirve en paralelo como panel
de diagnóstico para confirmar que la red va bien antes de depurar Resolume.

## Origen de los datos del protocolo

Nada de esto está adivinado. Los formatos binarios están verificados contra
implementaciones de referencia:

- StageLinq → [chrisle/StageLinq](https://github.com/chrisle/StageLinq)
- Pro DJ Link → [Deep Symmetry / dysentery](https://djl-analysis.deepsymmetry.org)
  y [flesniak/python-prodj-link](https://github.com/flesniak/python-prodj-link),
  dos fuentes independientes que coinciden entre sí en los offsets clave
  (BPM `0x92`, contador de beat `0xa0`, beat del compás `0xa6`, flags `0x89`).

## Estructura

```
Package.swift
Sources/
  StageLinqKit/            librería de protocolo (sin interfaz)
    ByteIO.swift             lectura/escritura binaria Big Endian
    Sockets.swift            sockets BSD (UDP/TCP)
    Protocol.swift           constantes StageLinq + descubrimiento
    StatePaths.swift         las 47 rutas de estado por deck
    StateValue.swift         JSON embebido de StateMap
    Models.swift             DeckState / StageLinqDevice
    NetworkDevice.swift      conexión principal StageLinq
    ServiceConnection.swift  framing común de servicios
    StateMapService.swift    suscripción a estado
    BeatInfoService.swift    beat en vivo
    StageLinqManager.swift   orquestador StageLinq
    ProDJLink/               ← soporte CDJ (protocolo independiente)
      DJLinkProtocol.swift     paquetes y offsets Pro DJ Link
      NetworkInfo.swift        IP local de la interfaz
      ProDJLinkManager.swift   descubrimiento, CDJ virtual y estado
  SC6000ConnectApp/        interfaz SwiftUI
    SC6000ConnectApp.swift   punto de entrada
    ContentView.swift        ventana principal
    DeckCardView.swift       tarjeta de deck (SC6000)
    CDJStripView.swift       franja de CDJ (Pro DJ Link)
    SidebarView.swift        lista de dispositivos
    LogView.swift            log de protocolo
    Theme.swift              paleta visual
packaging/Info.plist       metadatos del bundle .app
Resources/                 icono de la app
.github/workflows/         CI: compila y empaqueta la app en cada push
```
