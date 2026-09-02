# SC6000 Connect — Documentación técnica

Guía completa de cómo está construido el proyecto, por qué está construido así,
y cómo seguir desarrollándolo.

**DJ Saik** · @dj.saik · @entikrecords

---

## 1. Qué es esto

Una app de macOS que se conecta a reproductores de DJ por red y muestra su
estado en vivo. Habla **dos protocolos completamente distintos** que no
comparten absolutamente nada entre sí:

| Marca | Protocolo | Transporte | Qué da |
|---|---|---|---|
| Denon SC6000 / Engine OS | **StageLinq** | UDP 51337 + TCP | Título, artista, key, género, BPM, estado, loop, volumen, beat |
| Pioneer / AlphaTheta CDJ | **Pro DJ Link** | UDP 50000/50001/50002 | BPM, pitch, play/cue, master, sync, on-air, beat, posición |

La regla mental más importante del proyecto: **no son variantes del mismo
protocolo**. Son dos implementaciones independientes que solo se encuentran en
la capa de interfaz.

---

## 2. Estructura del código

```
Package.swift                      3 targets
Sources/
  StageLinqKit/                    ← toda la lógica de red, sin interfaz
    ByteIO.swift                     lectura/escritura binaria Big Endian
    Sockets.swift                    UDP, TCP cliente y TCP servidor
    Protocol.swift                   constantes StageLinq + descubrimiento
    StatePaths.swift                 las 47 rutas de estado por deck
    StateValue.swift                 JSON embebido de StateMap
    Models.swift                     DeckState, StageLinqDevice
    NetworkDevice.swift              conexión principal StageLinq
    ServiceConnection.swift          framing común de servicios
    StateMapService.swift            suscripción a estado
    BeatInfoService.swift            beat en vivo
    StageLinqManager.swift           orquestador Denon
    ProDJLink/                     ← protocolo Pioneer, independiente
      DJLinkProtocol.swift             paquetes y offsets
      NetworkInfo.swift                IP local de la interfaz
      ProDJLinkManager.swift           orquestador Pioneer
    Simulator/                     ← finge ser equipo, para probar sin hardware
      DenonSimulator.swift             lado servidor de StageLinq
      PioneerSimulator.swift           emisor de paquetes Pro DJ Link
  SC6000ConnectApp/                ← interfaz de la app principal
    SC6000ConnectApp.swift           punto de entrada
    ContentView.swift                ventana, modos, construcción de filas
    PlayerDeckRow.swift              fila estilo reproductor
    LogView.swift                    log de ambos protocolos
    Theme.swift                      paleta
  DJSimulatorApp/                  ← interfaz de la app simuladora
    DJSimulatorApp.swift
packaging/Info.plist               metadatos del bundle .app
.github/workflows/build.yml        CI: compila, empaqueta y publica el log
```

**Por qué esta separación:** `StageLinqKit` no importa SwiftUI. Toda la red es
código puro y probable por separado; la interfaz solo observa objetos. Eso
permite que la app simuladora reutilice exactamente el mismo código de bytes y
sockets que la app principal.

---

## 3. Decisiones de diseño y por qué

### 3.1 Sockets BSD en crudo, no Network.framework

`Sockets.swift` usa `socket()`, `bind()`, `recvfrom()`, `poll()` directamente.
Motivo: control exacto y predecible sobre broadcast UDP y sobre el framing
manual de TCP. Network.framework añade una capa asíncrona que complica el
control de tiempos y el descubrimiento por broadcast.

**Trampas que ya están resueltas ahí, no las reintroduzcas:**

- `Darwin.close(fd)` siempre cualificado. Si escribes `close(fd)` dentro de una
  clase que tiene un método `close()`, Swift resuelve al método y no compila.
  Lo mismo con `Darwin.accept` y `Darwin.send`.
- En un `init`, no uses propiedades de la clase dentro de un closure antes de
  haber inicializado todas: cuenta como capturar `self` y no compila. Usa una
  variable local y asigna las propiedades al final (ver `TCPListener.init`).
- `addr.sin_len` debe rellenarse en macOS (es un campo BSD que no existe en
  Linux).
- Todos los sockets de escucha llevan `SO_REUSEADDR` y `SO_REUSEPORT`: sin eso,
  la app y el simulador no pueden escuchar el mismo puerto a la vez en el mismo
  Mac.
- Los `recv` tienen timeout de 1 s para poder comprobar la cancelación entre
  intentos, en vez de quedarse bloqueados para siempre.

### 3.2 Nada de Swift Concurrency

No hay `async/await` ni actores. Todo el trabajo de red es bloqueante y corre en
`DispatchQueue` de fondo, y **cada** cambio de estado observable se despacha
explícitamente a `DispatchQueue.main`. Es más verboso, pero el modelo de hilos
queda explícito y no hay sorpresas de aislamiento de actores.

Patrón repetido en los dos managers:

```swift
private let netQueue = DispatchQueue(label: "…", attributes: .concurrent)   // trabajo de red
private let bookkeepingQueue = DispatchQueue(label: "…")                    // serie: protege los diccionarios
// …y toda mutación de @Published va dentro de DispatchQueue.main.async
```

### 3.3 El estado vive en objetos observables, no en copias

`DeckState` y `ProDJLinkDevice` son `ObservableObject`. La interfaz **no**
guarda copias: `ContentView` construye una lista de `DeckEntry` que guarda
referencias a esos objetos, y cada fila (`DenonDeckRow`, `PioneerDeckRow`) los
observa con `@ObservedObject`.

**Esto es crítico y fue un fallo real durante el desarrollo:** si la vista
principal construyera estructuras planas con los valores, SwiftUI solo se
refrescaría cuando cambiara la lista de dispositivos, no cuando cambiara el
estado de un deck, y la pantalla se quedaría congelada. Si añades una vista
nueva, observa el objeto, no copies sus valores.

---

## 4. Protocolo StageLinq (Denon)

### 4.1 Reglas generales

- **Todo Big Endian.**
- Las cadenas son *network strings*: `uint32` con la longitud **en bytes**,
  seguida del texto en **UTF-16 Big Endian**. Ojo: la longitud es en bytes, es
  decir el doble de caracteres. Está implementado en `ByteIO.swift`.

### 4.2 Descubrimiento (UDP 51337)

Paquete: `"airD"` + token de 16 bytes + netstr(source) + netstr(action) +
netstr(nombre) + netstr(versión) + **uint16** puerto.

El puerto es `uint16`, no `uint32`. Es un error fácil de cometer y rompe el
parseo entero.

La app se anuncia con el **token fijo de SoundSwitch**
`[82,253,252,7,33,130,101,79,22,63,95,15,154,98,29,114]` e identidad
`nowplaying` / `2.2.0` / `np2`. Ese token identifica a los clientes tipo "Now
Playing" y los SC6000 lo reconocen como legítimo. La app ignora los anuncios que
llevan ese mismo token, para no descubrirse a sí misma.

### 4.3 Conexión principal (TCP, puerto anunciado)

Mensajes **sin prefijo de longitud**: `uint32` id + 16 bytes de token + carga
según el id.

| id | Significado |
|---|---|
| `0x00` | Anuncio de servicio: netstr(nombre) + uint16(puerto) |
| `0x01` | Marca de tiempo (se descarta) |
| `0x02` | Permiso para pedir servicios |

Secuencia: el reproductor concede permiso (`0x02`) → la app envía su
`ServicesRequest` con el token → el reproductor anuncia `StateMap` y `BeatInfo`
con sus puertos.

**Detalle importante:** los servicios pueden llegar en mensajes separados, así
que el callback se llama cada vez que cambia la lista, y el manager lleva un
`Set<String>` de servicios ya conectados. Una versión anterior usaba un solo
booleano y se perdía BeatInfo si llegaba después.

### 4.4 Servicios (TCP)

A diferencia de la conexión principal, aquí **cada mensaje va precedido de un
`uint32` con su longitud**. `ServiceConnection` implementa ese framing, con
buffer acumulado para mensajes partidos entre paquetes TCP.

**StateMap** — suscripción: `"smaa"` + `uint32(0x000007d2)` + netstr(ruta) +
`int32(intervalo)`. Actualización recibida: `"smaa"` + `uint32(0x00000000)` +
netstr(ruta) + netstr(**JSON**). El valor viene como una cadena JSON embebida,
con campos opcionales: `{type, string, value, state, color}`. Por eso
`StateValue` los tiene todos opcionales.

**BeatInfo** — la suscripción son 8 bytes fijos `[0,0,0,4,0,0,0,0]` **sin**
prefijo de longitud (excepción del propio protocolo). La respuesta sí va
enmarcada: id(4) + reloj(uint64) + nº de decks(4) + por deck tres `float64`
(beat, beats totales, BPM) + opcionalmente un `float64` de muestras por deck.

### 4.5 Rutas de estado

`StatePaths.swift` tiene las **47 rutas por deck** más ~34 globales, extraídas
del enum `StageLinqValue` de la librería de referencia. No están inventadas.

El mapeo ruta → campo está en `StageLinqManager.applyState`. Para mostrar un
dato nuevo que ya se suscribe pero no se pinta, solo hay que añadir un `case` a
ese `switch`. Nombres que confunden: la canción es `SongName`, no `TrackName`.

---

## 5. Protocolo Pro DJ Link (Pioneer)

### 5.1 Reglas generales

- Todo Big Endian, cabecera fija de 10 bytes:
  `51 73 70 74 31 57 6d 4a 4f 4c` (`"Qspt1WmJOL"`).
- El byte `0x0a` identifica el tipo de paquete.
- Todo es UDP y casi todo por broadcast. No hay conexión que mantener.

### 5.2 Los tres puertos

| Puerto | Qué lleva |
|---|---|
| 50000 | Presencia: quién hay en la red |
| 50001 | Beats (`0x28`) y posición absoluta (`0x0b`, solo CDJ-3000) |
| 50002 | Estado detallado (`0x0a`), ~5 veces por segundo |

### 5.3 El CDJ virtual es obligatorio

**Sin anunciarse, los CDJ no envían estado detallado a nadie.** La app emite un
paquete de presencia cada 1,5 s haciéndose pasar por un reproductor, con número
**7** (fuera del rango 1–6 que usan los equipos reales, para no provocar
conflictos de número de player). Solo entonces empiezan a llegar paquetes al
puerto 50002.

### 5.4 Offsets del paquete de estado (0x0a en el puerto 50002)

Verificados contra dos fuentes independientes que coinciden:

| Offset | Campo |
|---|---|
| `0x0b`–`0x1e` | Modelo (20 bytes, ASCII con relleno de ceros) |
| `0x21` | Número de reproductor |
| `0x29` | Slot de origen (0 vacío, 2 SD, 3 USB, 4 rekordbox, 6 cloud, 9 Beatport) |
| `0x2a` | Tipo de pista (0 ninguna, 1 rekordbox, 2 sin analizar, 5 CD) |
| `0x2c`–`0x2f` | ID de pista en la base de datos |
| `0x7b` | Modo de reproducción (3 play, 4 loop, 5 pausa, 6 cue…) |
| `0x7c`–`0x7f` | Firmware (ASCII) |
| `0x89` | **Flags**: bit 6 play, bit 5 master, bit 4 sync, bit 3 on-air |
| `0x92`–`0x93` | BPM ×100 (`0xffff` = sin pista analizada) |
| `0x98`–`0x9b` | Pitch efectivo (`0x100000` = 0%, `0x200000` = +100%) |
| `0xa0`–`0xa3` | Contador de beat absoluto |
| `0xa6` | Beat dentro del compás (1–4) |

BPM realmente sonando = `BPM × pitch`, que es lo que muestra la app.

### 5.5 Paquetes del puerto 50001

**Beat (`0x28`, 96 bytes):** llega **justo en el golpe**, así que es la señal de
sincronía más precisa del protocolo, mucho mejor que el estado (200 ms). Beat
del compás en `0x5c`, BPM en `0x5a`, pitch en `0x54`.

**Posición absoluta (`0x0b`, 60 bytes):** **solo la emiten los CDJ-3000**. Es la
**única** fuente de tiempo transcurrido y duración de pista en Pro DJ Link.
Duración en segundos en `0x24`, posición en milisegundos en `0x28`, BPM ×10 en
`0x38`. Si la app no muestra tiempo en un CDJ, es que ese modelo no emite este
paquete, no que esté fallando.

---

## 6. El simulador

Dos clases en `Sources/StageLinqKit/Simulator/`:

- **`DenonSimulator`** — implementa el lado **servidor** de StageLinq completo:
  se anuncia por UDP, escucha en TCP 51338 (principal), 51339 (StateMap) y
  51340 (BeatInfo), concede el permiso, anuncia los servicios y emite estado y
  beats de dos decks con una pista ficticia avanzando.
- **`PioneerSimulator`** — emite por broadcast presencia, estado, beats y
  posición absoluta como un CDJ-3000 (player 2).

**Limitación que hay que tener siempre presente:** el simulador está escrito con
la misma interpretación del protocolo que el cliente. Que se entiendan demuestra
que la cadena completa funciona (descubrimiento, conexión, framing, UTF-16,
JSON, refresco de la interfaz), pero **no** demuestra fidelidad al equipo real.
Sirve para *separar* fallos: si el simulador va y el equipo no, el fallo está en
la interpretación del protocolo; si no va ni el simulador, está en la app.

---

## 7. Interfaz

- **Modos** (`AppMode`): Auto, Denon, Pioneer, Dual. Auto mira lo que hay
  realmente en la red y elige; con las dos marcas presentes pasa a Dual.
- **`DeckDisplay`** normaliza un deck venga del protocolo que venga, para que la
  misma fila sirva para Denon y Pioneer y el modo Dual pueda apilar los que haya
  sin límite de 2.
- **`DeckDisplayBuilder`** traduce cada modelo a `DeckDisplay`. Ahí está el
  criterio de qué decks se muestran: los que tienen pista cargada y, si no hay
  ninguno, los dos primeros del equipo.
- Los campos que un protocolo no puede dar son **opcionales** (`elapsed`,
  `progress`, `pitchPercent`), y la vista pinta `--:--` en vez de inventarlos.
  Mantén ese criterio: preferimos un hueco honesto a un dato falso.

---

## 7 bis. Salidas hacia otras aplicaciones

En `Sources/StageLinqKit/Output/`. La app toma 20 veces por segundo una
`SyncSnapshot` del deck que manda (el marcado master; si no hay, el primero que
suene) y la reparte a las salidas activas. `OutputController` (en el target de
la app) es quien orquesta.

### Resolume por OSC

**Por qué no se puede "conectar como si fuéramos la mesa":** Resolume no acepta
que un tercero se le presente como reproductor. Su soporte de StageLinq y Pro DJ
Link es interno y escucha directamente a los equipos, sin API de entrada para
otras apps. Lo que **sí** expone oficialmente para control externo es OSC, así
que esa es la vía correcta y soportada.

`OSCClient` implementa OSC 1.0 sobre UDP (dirección + etiquetas de tipo, ambas
terminadas en cero y rellenadas a múltiplo de 4, argumentos en Big Endian).
`ResolumeBridge` envía:

- Tempo: `/composition/tempocontroller/tempo` como float, solo cuando cambia.
- O bien un tap por beat en `/composition/tempocontroller/tempotap`.
- Resync de fase en el primer tiempo del compás.

Las direcciones y el modo son **configurables a propósito**: las rutas OSC y el
criterio de valores (absoluto contra normalizado 0–1) cambian entre versiones de
Resolume. Si el tempo no entra por valor, el modo tap funciona en cualquier
versión porque no depende del rango.

### SMPTE LTC por audio

`LTCGenerator` genera timecode SMPTE como señal de audio con `AVAudioSourceNode`:

- 80 bits por frame, codificación **bifase-mark**: transición al principio de
  cada bit y otra a mitad si el bit es 1.
- Palabra de sincronismo en los bits 64–79: `0011111111111101`.
- Horas, minutos, segundos y frames en BCD, con el bit menos significativo
  primero dentro de cada campo.

El generador corre libre a su frame rate y solo se reposiciona (`seek`) si se
desvía más de 0,15 s de la posición real del deck; así el timecode sale continuo
en lugar de a saltos. Sale por el dispositivo de salida por defecto del Mac: para
llevarlo a otra app hace falta un cable de audio virtual (BlackHole, Loopback).

**Pendiente natural aquí:** selector de dispositivo de salida (enumerar por
CoreAudio y fijar `deviceID` en el `auAudioUnit` del `outputNode`), para no
depender de cambiar la salida por defecto del sistema. Y MIDI clock por CoreMIDI
como tercera salida, que Resolume también acepta para tempo.

## 8. Flujo de desarrollo

Yo no puedo compilar Swift en mi entorno, así que el circuito es este y funciona
bien:

1. Se editan los archivos y se copian a `~/DENON CONNECT/sc6000swift`.
2. `swift build -c release` en el Mac da el error en segundos (vía más rápida).
3. Alternativa: `git push` → GitHub Actions compila en un Mac real y **publica
   el log en `ci/build-log.txt` dentro del propio repositorio**, porque los logs
   de Actions están detrás de login y no se pueden leer de otro modo.
4. El CI también empaqueta la `.app` y la sube como artefacto descargable.

**Cuidado con las fechas de los archivos:** si se copian con `unzip`, conservan
la fecha del zip y Swift puede creer que no hay cambios y no recompilar (se ve
porque el build tarda 0,1 s). Solución: `find Sources -name "*.swift" -exec touch {} +`.

### Montar la `.app` a mano

```bash
cd ~/"DENON CONNECT/sc6000swift"
swift build -c release
APP=~/"DENON CONNECT/SC6000 Connect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SC6000ConnectApp "$APP/Contents/MacOS/SC6000Connect"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/SC6000Connect"
```

`CFBundleExecutable` del Info.plist debe coincidir con el nombre del binario
dentro de `Contents/MacOS/`.

---

## 9. Qué falta y cómo abordarlo

### 9.1 Formas de onda, cues, y título/artista en los CDJ

**Ningún protocolo emite la forma de onda por la red.** Lo que muestran ShowKontrol
o un CDJ sale de la **base de datos del reproductor**, y hay que pedirla aparte.
Son dos proyectos distintos, uno por marca:

**Pioneer — cliente `dbserver` (TCP):**
1. Preguntar al puerto 12523 del reproductor en qué puerto escucha el dbserver.
2. Abrir TCP a ese puerto y hacer el saludo inicial.
3. Consultas útiles: `GetTrackInfo` (título y artista reales),
   `GetWaveformPreview`, `GetWaveformDetailed`, `GetWaveformHD` (solo CDJ-3000),
   `GetCueAndLoops`.
4. Se usa el ID de pista (`0x2c`) y el slot (`0x29`) del paquete de estado que la
   app ya recibe: los datos de entrada ya los tenemos.

Restricción a tener en cuenta: **el número de reproductor virtual debe ser 6 o
menor** para que los CDJ respondan a estas consultas. La app usa el 7 justamente
para no chocar, así que habría que gestionar ese conflicto (usar un número libre
del 1 al 6 cuando haya hueco).

Las pistas de streaming (slot 6 o 9) responden a `GetTrackInfo` y a las de
forma de onda, pero **no** a `GetBeatGrid` ni a `GetCueAndLoops`: hay que
tratarlas aparte para no quedarse esperando una respuesta que no llega.

**Denon — servicio `FileTransfer` (StageLinq):**
1. Conectar al servicio `FileTransfer` que ya aparece en el anuncio de servicios.
2. Descargar la base de datos de Engine y los ficheros de análisis.
3. Parsear ahí forma de onda y cues.

### 9.2 Otras ideas naturales

- **Barra de fase/compás** más completa (compases de 4, 8, 16, 32) usando el
  contador de beat que ya llega.
- **Salida OSC o MIDI clock** para sincronizar visuales o luces.
- **Historial de pistas** con marca de tiempo, exportable.
- **Firma y notarización** de la app con cuenta de desarrollador de Apple, para
  quitar el aviso de Gatekeeper al distribuirla.

---

## 10. Problemas típicos en un bolo

| Síntoma | Causa habitual |
|---|---|
| No aparece nada | Permiso de **red local** de macOS denegado |
| No aparecen los CDJ | **rekordbox abierto**: ocupa los puertos de Pro DJ Link |
| No aparece nada, con permiso dado | Equipos y Mac en redes/switches distintos |
| CDJ sin tiempo transcurrido | Modelo que no emite posición absoluta (no es CDJ-3000) |
| CDJ sin título ni artista | Es normal: requiere el cliente `dbserver` (§9.1) |
| Aparece y desaparece | Dos equipos con el mismo número de player |

El botón de terminal de la app abre el **log de los dos protocolos**: dice si el
problema es de descubrimiento, de conexión o de permisos.

---

## 11. Origen de los datos del protocolo

Nada está adivinado. Las estructuras binarias están verificadas contra:

- **StageLinq** → [chrisle/StageLinq](https://github.com/chrisle/StageLinq)
- **Pro DJ Link** → [Deep Symmetry / dysentery](https://djl-analysis.deepsymmetry.org)
  y [flesniak/python-prodj-link](https://github.com/flesniak/python-prodj-link),
  dos fuentes independientes que coinciden en los offsets clave.

Si vas a tocar el parseo de un paquete, contrasta siempre contra esas fuentes
antes de cambiar un offset. Un byte mal leído no da error: da un dato plausible
pero equivocado, que es mucho peor.
