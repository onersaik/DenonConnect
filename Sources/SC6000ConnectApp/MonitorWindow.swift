// MonitorWindow.swift
// Segunda ventana: overlay cabina / Resolume. Vistas TC · CDJ · Overview · Master · Todos.

import SwiftUI
import AppKit
import StageLinqKit

struct MonitorWindowView: View {
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager
    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var testLink: TestLinkReceiver
    @EnvironmentObject var testPlayback: TestLinkPlayback
    @EnvironmentObject var software: SoftwareDJManager
    @EnvironmentObject var labels: DeckLabelStore
    @EnvironmentObject var mapping: MappingController
    @EnvironmentObject var artwork: ArtworkFetcher
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var tracklist: TracklistStore
    @EnvironmentObject var localization: LocalizationStore

    @AppStorage("sc.monitor.layout") private var layoutRaw = MonitorLayout.soloTC.rawValue
    @AppStorage("sc.monitor.size") private var sizeRaw = MonitorSizePreset.cabina.rawValue
    @AppStorage("sc.monitor.opacity") private var opacity = 1.0
    @AppStorage("sc.monitor.onTop") private var alwaysOnTop = true
    @AppStorage("sc.monitor.showBPM") private var showBPM = true
    @AppStorage("sc.monitor.showWaveform") private var showWaveform = true
    @AppStorage("sc.monitor.showArtwork") private var showArtwork = true
    @AppStorage("sc.monitor.showArtist") private var showArtist = true
    @AppStorage("sc.monitor.showPlay") private var showPlay = true
    @AppStorage("sc.monitor.sizeTick") private var sizeTick = 0

    @State private var clockNow = Date()
    @State private var isFullscreen = false
    @State private var chromeVisible = true
    @State private var hideChromeWork: DispatchWorkItem?

    private var layout: MonitorLayout { MonitorLayout.resolved(layoutRaw) }
    private var sizePreset: MonitorSizePreset { MonitorSizePreset(rawValue: sizeRaw) ?? .cabina }
    private var presentation: Bool { isFullscreen || layout.isPresentation }
    private var showChrome: Bool { chromeVisible && (!isFullscreen || chromeVisible) }
    private var forceBlack: Bool { isFullscreen || layout == .soloTC }
    /// Día/noche unificado con ThemeStore (misma paleta que la app principal).
    private var dayMode: Bool { !theme.isDark && !forceBlack }
    private var palette: MonitorPalette {
        MonitorPalette.resolve(day: dayMode)
    }

    var body: some View {
        ZStack {
            (forceBlack ? Color.black : palette.background).ignoresSafeArea()
            VStack(spacing: 0) {
                if showChrome {
                    monitorChrome
                    optionsBar
                }
                contentBody
                if showChrome { footerBar }
            }
        }
        .frame(minWidth: 960, minHeight: 540)
        .preferredColorScheme(dayMode ? .light : .dark)
        .environment(\.waveformWindowSeconds, mapping.monitorWaveformWindowSeconds)
        .background(MonitorWindowChrome(
            dayMode: dayMode,
            opacity: opacity,
            alwaysOnTop: alwaysOnTop,
            sizeToken: "\(sizeRaw).\(sizeTick)",
            targetSize: sizePreset.size,
            wantsFullscreen: isFullscreen,
            chromeHidden: !showChrome
        ))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { clockNow = $0 }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            // 30 fps: DeckDisplayBuilder interpola playhead; el monitor debe redibujar.
            syncTracklistPlayhead()
            clockNow = Date()
        }
        .onAppear {
            requestMasterArtwork()
            if isFullscreen { scheduleHideChrome() }
        }
        .onChange(of: masterLine?.display.title ?? "") { _ in requestMasterArtwork() }
        .onChange(of: masterLine?.display.artist ?? "") { _ in requestMasterArtwork() }
        .onChange(of: isFullscreen) { on in
            chromeVisible = true
            if on { scheduleHideChrome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scMonitorToggleFullscreen)) { _ in
            toggleFullscreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scMonitorEscape)) { _ in
            handleEscape()
        }
        .onContinuousHover { phase in
            if case .active = phase { revealChrome() }
        }
        .onTapGesture(count: 2) { toggleFullscreen() }
    }

    // MARK: - Chrome

    private var monitorChrome: some View {
        HStack(spacing: 8) {
            Text(localization.t("monitor.title"))
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundColor(palette.textTertiary)
                .id(localization.language)

            HStack(spacing: 1) {
                ForEach(MonitorLayout.allCases) { mode in
                    chromeTab(localization.t(mode.locKey), on: layout == mode, help: mode.help) {
                        layoutRaw = mode.rawValue
                    }
                }
            }
            .id(localization.language)
            chromeIcon(
                systemName: isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                on: isFullscreen,
                help: "Pantalla completa. Tecla F. Escape para salir. Doble clic tambien."
            ) {
                toggleFullscreen()
            }

            Spacer(minLength: 8)

            chromeTab(localization.t("monitor.day"), on: !theme.isDark, help: "Paleta clara (tema app). Persistida.") {
                if theme.isDark { theme.isDark = false }
            }
            chromeTab(localization.t("monitor.night"), on: theme.isDark, help: "Paleta de cabina (tema app). Persistida.") {
                if !theme.isDark { theme.isDark = true }
            }

            HStack(spacing: 1) {
                ForEach(MonitorSizePreset.allCases) { preset in
                    chromeTab(localization.t(preset.locKey), on: sizePreset == preset, help: preset.help) {
                        sizeRaw = preset.rawValue
                        sizeTick += 1
                    }
                }
            }
            .id(localization.language)

            chromeTab(localization.t("monitor.on.top"), on: alwaysOnTop, help: "Siempre encima (overlay sobre Resolume).") {
                alwaysOnTop.toggle()
            }

            chromeTab(localization.t("monitor.auto"), on: outputs.ltcAutoFollow, help: "Fuente TC: MASTER automático (LTC / On Air / el que suena).") {
                outputs.setAutoFollow(true)
            }
            chromeTab(localization.t("monitor.pin"), on: !outputs.ltcAutoFollow, help: "Fuente TC: fila anclada. No sigue al fader.") {
                outputs.setAutoFollow(false)
            }

            Text(Self.clockText(clockNow))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 8) {
            Text(localization.t("monitor.options"))
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundColor(palette.textTertiary)
                .id(localization.language)

            optionToggle(localization.t("monitor.opt.bpm"), $showBPM)
            optionToggle(localization.t("monitor.opt.wave"), $showWaveform)
            optionToggle(localization.t("monitor.opt.art"), $showArtwork)
            optionToggle(localization.t("monitor.opt.artist"), $showArtist)
            optionToggle(localization.t("deck.play"), $showPlay)

            Spacer(minLength: 8)

            Text(localization.t("monitor.opacity"))
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundColor(palette.textTertiary)
            Slider(value: $opacity, in: 0.40...1.0)
                .frame(width: 88)
            Text("\(Int((opacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textSecondary)
                .frame(width: 36, alignment: .trailing)

            if layout == .cdj || layout == .overview {
                Text(localization.t("header.zoom"))
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(palette.textTertiary)
                Button {
                    mapping.monitorWaveformWindowSeconds = WaveformZoom.zoomOut(mapping.monitorWaveformWindowSeconds)
                } label: {
                    Text("-").font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.text)
                        .frame(width: 20, height: 20)
                        .background(palette.controlFill)
                }
                .buttonStyle(.plain)
                .help("Mas contexto (ventana mas larga). Atajo: - con esta ventana al frente.")
                Text(WaveformZoom.label(mapping.monitorWaveformWindowSeconds))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.text)
                    .frame(width: 32)
                Button {
                    mapping.monitorWaveformWindowSeconds = WaveformZoom.zoomIn(mapping.monitorWaveformWindowSeconds)
                } label: {
                    Text("+").font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.text)
                        .frame(width: 20, height: 20)
                        .background(palette.controlFill)
                }
                .buttonStyle(.plain)
                .help("Mas detalle (ventana mas corta). Atajo: + con esta ventana al frente.")
            }

            Text(outputs.ltcFrameRate.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(outputs.ltcAnyEnabled ? palette.ledGreen : palette.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(palette.strip)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
        .id(localization.language)
    }

    private func chromeTab(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundColor(on ? palette.controlOnText : palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Rectangle().fill(on ? palette.controlOn : palette.controlFill))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chromeIcon(systemName: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(on ? palette.controlOnText : palette.textSecondary)
                .frame(width: 28, height: 22)
                .background(Rectangle().fill(on ? palette.controlOn : palette.controlFill))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(on ? "Salir de pantalla completa" : "Pantalla completa")
    }

    private func optionToggle(_ title: String, _ bound: Binding<Bool>) -> some View {
        Button { bound.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.4)
                .foregroundColor(bound.wrappedValue ? palette.ledGreen : palette.textTertiary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Rectangle().fill(bound.wrappedValue ? palette.ledGreen.opacity(0.14) : palette.controlFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cuerpos

    @ViewBuilder
    private var contentBody: some View {
        switch layout {
        case .soloTC:
            tcOnlyBody
        case .datos:
            decksBody
        case .cdj:
            cdjBody
        case .overview:
            overviewBody
        case .tracklist:
            TracklistMonitorBody(palette: palette, dayMode: dayMode)
        }
    }

    private var tcOnlyBody: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            VStack(spacing: 0) {
                Text(displayedTC)
                    .font(.system(size: max(80, side * 0.28), weight: .bold, design: .monospaced))
                    .foregroundColor(tcColor)
                    .minimumScaleFactor(0.15)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { outputs.copyTimecode(displayedTC) }
                    .help("Clic: copiar TC")
                if !showChrome {
                    Text(masterLine.map { "MASTER  \($0.tag)  \($0.display.sourceBrand)" } ?? localization.t("monitor.noMaster"))
                        .font(.system(size: 18, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(palette.ledOrange.opacity(0.85))
                        .padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cdjBody: some View {
        VStack(spacing: 0) {
            masterIdentity(compact: false)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            hugeTC
                .padding(.horizontal, 16)
            masterStatusLine
                .padding(.bottom, 8)
            if showWaveform, let master = masterLine {
                monitorWaveform(master, mode: .scrolling, height: 168)
                    .padding(.horizontal, 12)
            }
            if lines.count > 1 {
                Divider().background(palette.divider)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            monitorRow(line, compact: false)
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var overviewBody: some View {
        VStack(spacing: 0) {
            masterIdentity(compact: true)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            HStack(alignment: .lastTextBaseline) {
                Text(displayedTC)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(tcColor)
                Spacer()
                masterStatusLine
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            if showWaveform, let master = masterLine {
                monitorWaveform(master, mode: .scrolling, height: 92)
                    .padding(.horizontal, 12)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        VStack(spacing: 0) {
                            monitorRow(line, compact: true)
                            if showWaveform {
                                monitorWaveform(line, mode: .overview, height: 44)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private var decksBody: some View {
        VStack(spacing: 0) {
            masterIdentity(compact: true)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            HStack {
                Text(displayedTC)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(tcColor)
                Spacer()
                masterStatusLine
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        monitorRow(line, compact: false)
                    }
                }
            }
        }
    }

    // MARK: - MASTER

    /// El que manda de verdad: LTC seguido si el Master de casa está ON;
    /// si no, hotDeck (isMaster / On Air / playing). LOCK o SMPTE de fila no mienten.
    private var masterLine: MonitorLine? {
        if outputs.ltcEnabled, let followed = outputs.ltcFollowedDeckID {
            if let found = lines.first(where: { OutputController.sameDeckID($0.display.id, followed) }) {
                return found
            }
        }
        if let hot = outputs.hotDeckID,
           let found = lines.first(where: { OutputController.sameDeckID($0.display.id, hot) }) {
            return found
        }
        if let found = lines.first(where: { outputs.isMasterFocus($0.display.id) }) {
            return found
        }
        return lines.first(where: { $0.display.isPlaying }) ?? lines.first
    }

    private func masterIdentity(compact: Bool) -> some View {
        let line = masterLine
        let tag = line?.tag ?? "—"
        let brand = line?.display.sourceBrand ?? "—"
        let title = line.map { $0.display.title.isEmpty ? localization.t("deck.notLoaded") : $0.display.title } ?? localization.t("monitor.noMaster")
        let artist = line?.display.artist ?? ""
        let playing = line?.display.isPlaying == true
        let loaded = line?.display.loaded == true
        let playLabel = playing ? localization.t("deck.play") : (loaded ? localization.t("deck.pause") : localization.t("deck.stop"))
        let playColor = playing ? palette.ledGreen : (loaded ? palette.ledYellow : palette.textTertiary)
        let bpm = line?.display.bpm ?? 0

        return HStack(alignment: .center, spacing: compact ? 12 : 18) {
            if showArtwork, let img = resolvedArtwork(line), let cg = ArtworkPixels.cgImage(img) {
                Image(decorative: cg, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: compact ? 44 : 72, height: compact ? 44 : 72)
                    .clipped()
                    .overlay(Rectangle().stroke(palette.divider, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text("MASTER")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(palette.ledOrange)
                Text(tag)
                    .font(.system(size: compact ? 28 : 42, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                HStack(spacing: 8) {
                    Text(brand)
                        .font(.system(size: compact ? 11 : 13, weight: .bold))
                        .foregroundColor(palette.ledOrange)
                    if let label = line?.display.label, !label.isEmpty {
                        Text(label)
                            .font(.system(size: compact ? 10 : 11))
                            .foregroundColor(palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Text(title)
                    .font(.system(size: compact ? 14 : 18, weight: .semibold))
                    .foregroundColor(loaded ? palette.ledGreen : palette.textTertiary)
                    .lineLimit(1)
                if showArtist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: compact ? 11 : 13))
                        .foregroundColor(palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                if showPlay {
                    Text(playLabel)
                        .font(.system(size: compact ? 16 : 22, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(playColor)
                }
                if showBPM {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(bpm > 0 ? String(format: "%.2f", bpm) : "---.--")
                            .font(.system(size: compact ? 28 : 40, weight: .bold, design: .monospaced))
                            .foregroundColor(bpm > 0 ? palette.ledGreen : palette.ledDim)
                        Text("BPM")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(palette.textTertiary)
                    }
                }
            }
        }
    }

    private var hugeTC: some View {
        Text(displayedTC)
            .font(.system(size: layout == .soloTC ? 120 : 72, weight: .bold, design: .monospaced))
            .foregroundColor(tcColor)
            .minimumScaleFactor(0.2)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { outputs.copyTimecode(displayedTC) }
            .help("Clic: copiar TC")
    }

    private var masterStatusLine: some View {
        HStack(spacing: 10) {
            Text(tcCaption)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.textSecondary)
            if !outputs.ltcEnabled {
                Text("LTC OFF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(palette.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.controlFill)
            }
            if let master = masterLine {
                if !master.display.isPlaying {
                    Text(master.display.loaded ? "MASTER \(localization.t("deck.pause"))" : "MASTER \(localization.t("deck.stop"))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(palette.ledYellow)
                }
                if outputs.isDeckLocked(master.display.id) {
                    Text("LOCK")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(palette.ledYellow)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var tcColor: Color {
        if outputs.ltcEnabled { return palette.ledGreen }
        if let id = masterLine?.display.id, outputs.isRowLTCLit(id) { return palette.ledGreen }
        return palette.ledDim
    }

    private var tcCaption: String {
        if outputs.ltcEnabled {
            return outputs.ltcAutoFollow
                ? "MASTER AUTO · LTC / On Air / el que suena"
                : "MASTER PIN · fila anclada"
        }
        if outputs.ltcAnyEnabled { return "LTC FILA · el MASTER de casa no es esa fila" }
        return "SIN LTC · foco de cabina"
    }

    // MARK: - Filas y waveform

    private func monitorRow(_ line: MonitorLine, compact: Bool) -> some View {
        let isMaster = masterLine.map { OutputController.sameDeckID($0.display.id, line.display.id) } ?? false
        let playing = line.display.isPlaying
        let loaded = line.display.loaded
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.tag)
                    .font(.system(size: compact ? 16 : 22, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.text)
                Text("\(line.display.sourceBrand)  \(line.display.kindLabel)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(palette.ledOrange)
            }
            .frame(width: compact ? 88 : 110, alignment: .leading)
            if showPlay {
                Text(playing ? localization.t("deck.play") : (loaded ? localization.t("deck.pause") : localization.t("deck.stop")))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(playing ? palette.ledGreen : palette.textTertiary)
                    .frame(width: 48, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(line.display.title.isEmpty ? localization.t("deck.notLoaded") : line.display.title)
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                    .foregroundColor(loaded ? palette.ledGreen : palette.textTertiary)
                    .lineLimit(1)
                if showArtist, !line.display.artist.isEmpty {
                    Text(line.display.artist)
                        .font(.system(size: 10))
                        .foregroundColor(palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isMaster {
                Text("MST")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(palette.controlOnText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(palette.ledOrange)
            }
            if showBPM {
                Text(line.display.bpm > 0 ? String(format: "%.2f", line.display.bpm) : "---.--")
                    .font(.system(size: compact ? 14 : 20, weight: .bold, design: .monospaced))
                    .foregroundColor(line.display.bpm > 0 ? palette.ledGreen : palette.ledDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 6 : 10)
        .background(isMaster ? palette.ledOrange.opacity(dayMode ? 0.10 : 0.12) : palette.deckFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    private func monitorWaveform(_ line: MonitorLine, mode: WaveformMode, height: CGFloat) -> some View {
        let d = line.display
        return WaveformView(
            progress: d.progress,
            trackLength: d.trackLength,
            bpm: d.bpm,
            beatInBar: d.beatInBar,
            isPlaying: d.isPlaying,
            accent: d.accent,
            trackSeed: d.trackSeed,
            peaks: d.peaks,
            peaksLow: d.peaksLow,
            peaksMid: d.peaksMid,
            peaksHigh: d.peaksHigh,
            elapsed: d.elapsed,
            cuePositionFraction: d.cuePositionFraction,
            extraCueFractions: d.extraCueFractions,
            loopInFraction: d.loopInFraction,
            loopOutFraction: d.loopOutFraction,
            mode: mode,
            windowSeconds: mapping.monitorWaveformWindowSeconds,
            canvasBackground: palette.waveformBG,
            playheadColor: palette.playhead
        )
        .id(d.id + (mode == .overview ? "-ov" : "-cdj"))
        .frame(height: height)
        .opacity(d.loaded && (d.progress != nil || d.elapsed != nil || !d.peaks.isEmpty || d.peaksLow.count > 1) ? 1 : 0.28)
        .transaction { $0.animation = nil }
    }

    private static func clockText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private var footerBar: some View {
        HStack {
            Text("ENTIK MEDIA")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(palette.textTertiary)
            Spacer()
            Text(sizePreset == .mini
                 ? localization.t("monitor.mode.mini")
                 : (alwaysOnTop ? localization.t("monitor.mode.overlay") : localization.t("monitor.mode.window")))
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundColor(palette.textTertiary)
                .id(localization.language)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - TC / artwork

    private var displayedTC: String {
        if let master = masterLine {
            // TC = playhead: OutputController lee TestLink.latest / BeatInfo sin
            // depender del snapshot UI throttled del Monitor.
            return outputs.displayTimecode(deckID: master.display.id, elapsed: master.display.elapsed)
        }
        if let first = lines.first(where: { $0.display.isPlaying }) {
            return outputs.displayTimecode(deckID: first.display.id, elapsed: first.display.elapsed)
        }
        return outputs.displayTimecode(deckID: nil, elapsed: nil)
    }

    private func resolvedArtwork(_ line: MonitorLine?) -> NSImage? {
        guard let line else { return nil }
        return ArtworkPixels.displayable(line.display.artworkImage)
            ?? ArtworkPixels.displayable(artwork.artwork(artist: line.display.artist, title: line.display.title))
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        chromeVisible = true
        if isFullscreen { scheduleHideChrome() }
    }

    private func handleEscape() {
        if isFullscreen {
            if !chromeVisible {
                chromeVisible = true
                scheduleHideChrome()
            } else {
                isFullscreen = false
                chromeVisible = true
            }
        }
    }

    private func revealChrome() {
        chromeVisible = true
        if isFullscreen { scheduleHideChrome() }
    }

    private func scheduleHideChrome() {
        hideChromeWork?.cancel()
        let work = DispatchWorkItem {
            if isFullscreen { chromeVisible = false }
        }
        hideChromeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    private func requestMasterArtwork() {
        guard let line = masterLine else { return }
        if let img = line.display.artworkImage {
            artwork.seed(artist: line.display.artist, title: line.display.title, image: img)
            return
        }
        artwork.fetch(artist: line.display.artist, title: line.display.title)
    }

    private func syncTracklistPlayhead() {
        let fps = outputs.ltcFrameRate.rawValue
        let head = masterLine.map { $0.display.elapsed ?? 0 } ?? 0
        tracklist.syncToPlayhead(seconds: head, smpte: displayedTC, fps: fps)
    }

    // MARK: - Roster (Dual: tope 4 CDJ LAN + capas Denon, igual que ContentView)

    private var lines: [MonitorLine] {
        let _ = testLink.rosterTick
        let _ = manager.rosterRevision
        let _ = proDJLink.rosterRevision
        let _ = software.rosterTick
        let _ = labels.tags
        let _ = mapping.mode
        var out: [MonitorLine] = []

        let pioneerLAN = proDJLink.devices.filter { $0.isLANPlayerWithTrack && !$0.isRekordboxExport }
            .sorted { $0.playerNumber < $1.playerNumber }
        let rekordboxLAN = proDJLink.devices
            .filter { $0.isRekordboxExport && $0.trackLoaded && !$0.isOwnVirtualCDJ && !$0.isMixer }
            .sorted { $0.playerNumber < $1.playerNumber }
        let mode = mapping.mode
        let showDenon = Self.sourceVisible(.denon, mode: mode, mapping: mapping)
        let showPioneer = Self.sourceVisible(.pioneer, mode: mode, mapping: mapping)
        let showSerato = Self.sourceVisible(.serato, mode: mode, mapping: mapping)
        let showVDJ = Self.sourceVisible(.virtualdj, mode: mode, mapping: mapping)
        let showRekordbox = Self.sourceVisible(.rekordbox, mode: mode, mapping: mapping)
        let capPioneer = mode == .auto || mode == .todos

        if showDenon {
            if testLink.roster.denonOn {
                let n = max(testLink.roster.loadedLayers.count, 2)
                for i in 0..<n where testLink.roster.layerLoaded(i) {
                    let overlay = testPlayback.snapshot?.deck(i)
                    let display = DeckDisplayBuilder.testDenon(layer: i, overlay: overlay)
                    let key = DeckLabelKey.denonTest(i)
                    out.append(MonitorLine(display: display, tag: labels.tag(for: key) ?? display.deckTag))
                }
            }
            for device in manager.devices where device.isDenonPlayerUnit {
                for deck in device.decks where deck.songLoaded || !deck.trackTitle.isEmpty || deck.playState == .playing {
                    let display = DeckDisplayBuilder.row(for: deck, device: device)
                    let key = DeckLabelKey.denon(token: device.token, layer: deck.id)
                    out.append(MonitorLine(display: display, tag: labels.tag(for: key) ?? display.deckTag))
                }
            }
        }

        if showPioneer {
            let showTestPioneer = Self.shouldShowTestPioneer(
                mode: mode,
                hasPioneerTrack: testLink.roster.hasPioneerTrack,
                denonOn: testLink.roster.denonOn,
                lanCount: pioneerLAN.count
            )
            if showTestPioneer {
                let overlay = testPlayback.snapshot?.firstLoadedDeck()
                let display = DeckDisplayBuilder.testPioneer(overlay: overlay)
                out.append(MonitorLine(display: display, tag: labels.tag(for: DeckLabelKey.pioneerTest) ?? display.deckTag))
            }
            let pioneerShown = capPioneer ? Array(pioneerLAN.prefix(4)) : pioneerLAN
            for device in pioneerShown {
                let display = DeckDisplayBuilder.row(for: device)
                let key = DeckLabelKey.pioneer(ip: device.ip, player: device.playerNumber)
                out.append(MonitorLine(display: display, tag: labels.tag(for: key) ?? display.deckTag))
            }
        }

        if showSerato || showVDJ {
            for deck in software.liveDecks {
                if deck.kind == .serato, !showSerato { continue }
                if deck.kind == .virtualdj, !showVDJ { continue }
                let display = DeckDisplayBuilder.software(deck)
                out.append(MonitorLine(display: display, tag: labels.tag(for: deck.id) ?? display.deckTag))
            }
        }
        if showRekordbox {
            for device in rekordboxLAN {
                let display = DeckDisplayBuilder.row(for: device)
                let key = DeckLabelKey.pioneer(ip: device.ip, player: device.playerNumber)
                out.append(MonitorLine(display: display, tag: labels.tag(for: key) ?? display.deckTag))
            }
        }
        return out
    }

    /// Misma regla que ContentView show* (ticks CONFIG en Auto/Todos).
    private static func sourceVisible(_ source: AppMode, mode: AppMode, mapping: MappingController) -> Bool {
        switch mode {
        case .denon: return source == .denon
        case .pioneer: return source == .pioneer
        case .serato: return source == .serato
        case .virtualdj: return source == .virtualdj
        case .rekordbox: return source == .rekordbox
        case .traktor: return source == .traktor
        case .auto, .todos:
            switch source {
            case .denon: return mapping.sourceDenon
            case .pioneer: return mapping.sourcePioneer
            case .serato: return mapping.sourceSerato
            case .virtualdj: return mapping.sourceVDJ
            case .rekordbox: return mapping.sourceRekordbox
            case .traktor: return mapping.sourceTraktor
            default: return false
            }
        }
    }

    /// Misma regla que ContentView.shouldShowTestPioneer.
    private static func shouldShowTestPioneer(
        mode: AppMode,
        hasPioneerTrack: Bool,
        denonOn: Bool,
        lanCount: Int
    ) -> Bool {
        guard hasPioneerTrack else { return false }
        if mode == .pioneer { return true }
        if mode == .denon { return false }
        if denonOn { return false }
        if mode == .auto || mode == .todos {
            return lanCount < 4
        }
        return true
    }

    private static func monitorDenonLoaded(manager: StageLinqManager, testLink: TestLinkReceiver) -> Bool {
        if testLink.roster.denonOn { return true }
        for device in manager.devices where !device.isDenonSimulator {
            if device.decks.contains(where: \.songLoaded) { return true }
        }
        return false
    }
}

private struct MonitorLine: Identifiable {
    let display: DeckDisplay
    let tag: String
    var id: String { display.id }
}

extension Notification.Name {
    static let scMonitorToggleFullscreen = Notification.Name("sc.monitor.toggleFullscreen")
    static let scMonitorEscape = Notification.Name("sc.monitor.escape")
}
