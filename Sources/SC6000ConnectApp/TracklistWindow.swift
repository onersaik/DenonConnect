// TracklistWindow.swift
// Ventana SETLIST: editor TC/anotaciones + vista en vivo.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StageLinqKit

struct TracklistWindowView: View {
    @EnvironmentObject var store: TracklistStore
    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager
    @EnvironmentObject var testLink: TestLinkReceiver
    @EnvironmentObject var software: SoftwareDJManager
    @EnvironmentObject var theme: ThemeStore

    @State private var showImporter = false
    @State private var editingID: UUID?

    private var dayMode: Bool { !theme.isDark }
    private var palette: MonitorPalette { MonitorPalette.resolve(day: dayMode) }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                chrome
                if store.showEditor {
                    editorBar
                }
                liveBanner
                if store.items.isEmpty {
                    emptyState
                } else {
                    list
                }
                footer
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .preferredColorScheme(dayMode ? .light : .dark)
        .background(MonitorWindowChrome(
            dayMode: dayMode,
            opacity: 1,
            alwaysOnTop: false,
            sizeToken: "setlist",
            targetSize: CGSize(width: 780, height: 900),
            wantsFullscreen: false,
            chromeHidden: false
        ))
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            tickPlayhead()
            ingestLive()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            if case .success(let url) = result {
                store.importFile(url: url)
            }
        }
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            Text("TRACKLIST")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.6)
                .foregroundColor(palette.ledOrange)
            Text("\(store.playedCount)/\(store.items.count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(palette.ledGreen)
            Spacer(minLength: 8)
            Text(store.playheadSMPTE)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(outputs.ltcAnyEnabled ? palette.ledGreen : palette.ledDim)
                .onTapGesture { outputs.copyTimecode() }
                .help("TC = playhead. Clic: copiar")
            chromeBtn("EDITAR", on: store.showEditor) { store.showEditor.toggle() }
            chromeBtn("+ FILA", on: false) { store.addBlankRow() }
            chromeBtn("ARCHIVO", on: false) { showImporter = true }
            chromeBtn("HISTORIAL", on: false) { store.importFromHistory(outputs.playlistHistory) }
            chromeBtn("DÍA", on: dayMode) {
                if theme.isDark { theme.isDark = false }
            }
            chromeBtn("NOCHE", on: !dayMode) {
                if !theme.isDark { theme.isDark = true }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
    }

    private var liveBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cur = store.currentItem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("AHORA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(palette.controlOnText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.ledOrange)
                    Text(cur.displayTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(palette.text)
                        .lineLimit(1)
                    if !cur.displayArtist.isEmpty {
                        Text(cur.displayArtist)
                            .font(.system(size: 13))
                            .foregroundColor(palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !cur.tcSMPTE.isEmpty {
                        Text(cur.tcSMPTE)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.ledGreen)
                    }
                }
            }
            if !store.liveNotes.isEmpty {
                Text(store.liveNotes)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.ledYellow)
            }
            if !store.liveAnnotations.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(store.liveAnnotations) { ann in
                        Text(ann.text)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(palette.controlOnText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.ledOrange)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.strip)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
    }

    private var editorBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Una pista por línea. Opcional: 00:01:30:00 | Artista - Título  ·  CSV  ·  PEGAR y CARGAR")
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
            TextEditor(text: $store.pasteDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 100)
                .scrollContentBackground(.hidden)
                .foregroundColor(palette.text)
                .padding(6)
                .background(palette.deckFill)
                .overlay(Rectangle().stroke(palette.divider, lineWidth: 1))
            HStack(spacing: 8) {
                chromeBtn("CARGAR", on: true) {
                    store.replace(fromLines: store.pasteDraft)
                    store.showEditor = false
                }
                chromeBtn("AÑADIR", on: false) {
                    store.append(fromLines: store.pasteDraft)
                }
                chromeBtn("LIMPIAR MARCAS", on: false) { store.clearMarks() }
                chromeBtn("VACIAR", on: false) { store.clearAll() }
                Spacer()
                if !store.status.isEmpty {
                    Text(store.status)
                        .font(.system(size: 10))
                        .foregroundColor(palette.ledGreen)
                }
            }
            Text("En cada fila: TC (SMPTE) = inicio del tramo. CAPTURAR TC usa el playhead actual. Anotaciones (FX, fuego…) aparecen en vivo cuando el TC entra en ese cue.")
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(palette.strip)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Sin tracklist")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(palette.text)
            Text("EDITAR para pegar una lista, importar TXT/CSV, o + FILA.")
                .font(.system(size: 12))
                .foregroundColor(palette.textSecondary)
            Text("Enlaza cada pista a un TC. Al avanzar el playhead cambia la fila activa y las anotaciones del tramo.")
                .font(.system(size: 11))
                .foregroundColor(palette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        row(index: index, item: item)
                            .id(item.id)
                    }
                }
            }
            .onChange(of: store.currentID) { id in
                if let id {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(index: Int, item: SetlistItem) -> some View {
        let isCurrent = store.currentID == item.id
        let isEditing = editingID == item.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textTertiary)
                    .frame(width: 28, alignment: .trailing)

                Button {
                    store.togglePlayed(item.id)
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(item.played ? palette.ledGreen : (isCurrent ? palette.ledOrange : palette.controlFill))
                            .frame(width: 18, height: 18)
                        if item.played {
                            Text("OK")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.black)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    if isEditing {
                        TextField("Título", text: Binding(
                            get: { item.title },
                            set: { store.updateTitle(item.id, title: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(palette.text)
                        TextField("Artista", text: Binding(
                            get: { item.artist },
                            set: { store.updateArtist(item.id, artist: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(palette.textSecondary)
                        HStack(spacing: 6) {
                            Text("TC")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(palette.textTertiary)
                            TextField("00:00:00:00", text: Binding(
                                get: { item.tcSMPTE },
                                set: { store.setTC(item.id, smpte: $0) }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.ledGreen)
                            .frame(width: 110)
                            chromeBtn("CAPTURAR", on: false) { store.captureTC(item.id) }
                        }
                        TextField("Notas pista (FX global…)", text: Binding(
                            get: { item.notes },
                            set: { store.updateNotes(item.id, notes: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(palette.ledYellow)
                        annotationsEditor(item)
                    } else {
                        Text(item.displayTitle)
                            .font(.system(size: isCurrent ? 18 : 15, weight: isCurrent ? .bold : .semibold))
                            .foregroundColor(item.played && !isCurrent ? palette.textTertiary : palette.text)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if !item.tcSMPTE.isEmpty {
                                Text(item.tcSMPTE)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.ledGreen)
                            }
                            if !item.displayArtist.isEmpty {
                                Text(item.displayArtist)
                                    .font(.system(size: 11))
                                    .foregroundColor(palette.textSecondary)
                                    .lineLimit(1)
                            }
                            if !item.notes.isEmpty {
                                Text(item.notes)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(palette.ledYellow)
                                    .lineLimit(1)
                            }
                            if !item.annotations.isEmpty {
                                Text("\(item.annotations.count) cue")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(palette.textTertiary)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Text("AHORA")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(palette.controlOnText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.ledOrange)
                }
                VStack(spacing: 2) {
                    chromeBtn("↑", on: false) { store.moveUp(item.id) }
                    chromeBtn("↓", on: false) { store.moveDown(item.id) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, isCurrent || isEditing ? 12 : 8)
            .contentShape(Rectangle())
            .onTapGesture { store.select(item.id) }
            .onTapGesture(count: 2) {
                editingID = isEditing ? nil : item.id
            }
            .contextMenu {
                Button(isEditing ? "Cerrar edición" : "Editar fila") {
                    editingID = isEditing ? nil : item.id
                }
                Button("Capturar TC actual") { store.captureTC(item.id) }
                Button("Añadir anotación en TC") {
                    store.addAnnotation(to: item.id, text: "FX")
                    editingID = item.id
                }
                Button(item.played ? "Desmarcar" : "Marcar reproducida") {
                    store.togglePlayed(item.id)
                }
                Button("Quitar de la lista", role: .destructive) {
                    store.remove(id: item.id)
                }
            }
        }
        .background(
            isCurrent ? palette.ledOrange.opacity(dayMode ? 0.12 : 0.16)
            : (item.played ? palette.background.opacity(0.4) : palette.deckFill)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
        .opacity(item.played && !isCurrent ? 0.55 : 1)
    }

    private func annotationsEditor(_ item: SetlistItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(item.annotations) { ann in
                HStack(spacing: 6) {
                    TextField("TC", text: Binding(
                        get: { ann.smpte },
                        set: { store.updateAnnotation(trackID: item.id, annotationID: ann.id, smpte: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.ledGreen)
                    .frame(width: 100)
                    TextField("Anotación", text: Binding(
                        get: { ann.text },
                        set: { store.updateAnnotation(trackID: item.id, annotationID: ann.id, text: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.text)
                    Button {
                        store.removeAnnotation(trackID: item.id, annotationID: ann.id)
                    } label: {
                        Text("×")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            chromeBtn("+ CUE / ANOTACIÓN", on: false) {
                store.addAnnotation(to: item.id, text: "FX")
            }
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        HStack {
            Text(store.status.isEmpty
                 ? "Doble clic: editar · CAPTURAR TC enlaza playhead · cues visibles en el tramo"
                 : store.status)
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
            Spacer()
            Button("Exportar TXT") { exportTXT() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(palette.textSecondary)
            Text("ENTIK MEDIA")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(palette.panel)
    }

    private func chromeBtn(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
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
    }

    private func tickPlayhead() {
        let fps = outputs.ltcFrameRate.rawValue
        let snap = outputs.liveDeckSnapshots()
        let master = snap.first(where: { $0.ltcSource })
            ?? snap.first(where: { $0.isMaster })
            ?? snap.first(where: { $0.isPlaying })
        let seconds = master?.playhead ?? master?.elapsed ?? 0
        let smpte = master?.tcTimecode
            ?? outputs.ltcTimecode
        store.syncToPlayhead(seconds: seconds, smpte: smpte, fps: fps)
    }

    private func ingestLive() {
        let decks = outputs.liveDeckSnapshots()
        store.ingest(playing: decks.compactMap { d in
            guard d.isPlaying, !d.title.isEmpty else { return nil }
            return (d.title, d.artist, d.label, d.isMaster || d.ltcSource)
        })
    }

    private func exportTXT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "STAGE-CONNECT-tracklist.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? store.exportTXT().write(to: url, atomically: true, encoding: .utf8)
            store.status = "TXT exportado"
        }
    }
}

/// Vista compacta para el modo MONITOR → Tracklist (solo lectura en vivo).
struct TracklistMonitorBody: View {
    @EnvironmentObject var store: TracklistStore
    let palette: MonitorPalette
    let dayMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TRACKLIST")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.6)
                        .foregroundColor(palette.ledOrange)
                    if let cur = store.currentItem {
                        Text(cur.displayTitle)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(palette.text)
                            .lineLimit(1)
                        if !cur.displayArtist.isEmpty {
                            Text(cur.displayArtist)
                                .font(.system(size: 14))
                                .foregroundColor(palette.textSecondary)
                        }
                    } else {
                        Text(store.items.isEmpty ? "Sin lista" : "Esperando TC")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(palette.textTertiary)
                    }
                }
                Spacer()
                Text(store.playheadSMPTE)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.ledGreen)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !store.liveNotes.isEmpty || !store.liveAnnotations.isEmpty {
                HStack(spacing: 8) {
                    if !store.liveNotes.isEmpty {
                        Text(store.liveNotes)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(palette.ledYellow)
                    }
                    ForEach(store.liveAnnotations) { ann in
                        Text(ann.text)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(palette.controlOnText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(palette.ledOrange)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                            let isCurrent = store.currentID == item.id
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.textTertiary)
                                    .frame(width: 32, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle)
                                        .font(.system(size: isCurrent ? 20 : 15, weight: isCurrent ? .bold : .semibold))
                                        .foregroundColor(isCurrent ? palette.text : (item.played ? palette.textTertiary : palette.text))
                                        .lineLimit(1)
                                    HStack(spacing: 8) {
                                        if !item.tcSMPTE.isEmpty {
                                            Text(item.tcSMPTE)
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(palette.ledGreen)
                                        }
                                        if !item.displayArtist.isEmpty {
                                            Text(item.displayArtist)
                                                .font(.system(size: 11))
                                                .foregroundColor(palette.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                Spacer()
                                if isCurrent {
                                    Text("AHORA")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(palette.controlOnText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(palette.ledOrange)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, isCurrent ? 14 : 9)
                            .background(isCurrent ? palette.ledOrange.opacity(dayMode ? 0.12 : 0.16) : palette.deckFill)
                            .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
                            .id(item.id)
                        }
                    }
                }
                .onChange(of: store.currentID) { id in
                    if let id {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}
