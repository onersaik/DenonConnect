// TracklistWindow.swift
// Ventana SETLIST: concierto, match al play, override manual.

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

    @AppStorage("sc.monitor.day") private var dayMode = false
    @State private var showImporter = false

    private var palette: MonitorPalette { MonitorPalette.resolve(day: dayMode) }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                chrome
                if store.showEditor {
                    editorBar
                }
                if store.items.isEmpty {
                    emptyState
                } else {
                    list
                }
                footer
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .preferredColorScheme(dayMode ? .light : .dark)
        .background(MonitorWindowChrome(
            dayMode: dayMode,
            opacity: 1,
            alwaysOnTop: false,
            sizeToken: "setlist",
            targetSize: CGSize(width: 720, height: 860),
            wantsFullscreen: false,
            chromeHidden: false
        ))
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
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
            Text("SETLIST")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.6)
                .foregroundColor(palette.ledOrange)
            Text("\(store.playedCount)/\(store.items.count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(palette.ledGreen)
            Spacer(minLength: 8)
            Text(outputs.ltcTimecode)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(outputs.ltcAnyEnabled ? palette.ledGreen : palette.ledDim)
                .onTapGesture { outputs.copyTimecode() }
                .help("Clic: copiar TC")
            chromeBtn("PEGAR", on: store.showEditor) { store.showEditor.toggle() }
            chromeBtn("ARCHIVO", on: false) { showImporter = true }
            chromeBtn("HISTORIAL", on: false) { store.importFromHistory(outputs.playlistHistory) }
            chromeBtn("DÍA", on: dayMode) { dayMode.toggle() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
    }

    private var editorBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Una pista por línea: Artista - Título  ·  o solo Título  ·  CSV artista,titulo")
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
            TextEditor(text: $store.pasteDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 120)
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
        }
        .padding(12)
        .background(palette.strip)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Sin setlist")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(palette.text)
            Text("PEGAR una lista, importar TXT/CSV o cargar desde el historial.")
                .font(.system(size: 12))
                .foregroundColor(palette.textSecondary)
            Text("Durante el show, un deck en PLAY que coincida con una fila la marca sola. Clic para corregir.")
                .font(.system(size: 11))
                .foregroundColor(palette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
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
        let isNext = !item.played && store.nextUnplayed?.id == item.id && !isCurrent
        return Button {
            store.togglePlayed(item.id)
        } label: {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textTertiary)
                    .frame(width: 28, alignment: .trailing)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.system(size: isCurrent ? 18 : 15, weight: isCurrent ? .bold : .semibold))
                        .foregroundColor(item.played && !isCurrent ? palette.textTertiary : palette.text)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if !item.displayArtist.isEmpty {
                            Text(item.displayArtist)
                                .font(.system(size: 11))
                                .foregroundColor(palette.textSecondary)
                                .lineLimit(1)
                        }
                        if item.played {
                            Text(item.timeText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(palette.ledGreen)
                            if !item.playedBy.isEmpty {
                                Text(item.playedBy)
                                    .font(.system(size: 10))
                                    .foregroundColor(palette.textTertiary)
                                    .lineLimit(1)
                            }
                            if item.manual {
                                Text("MANUAL")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(palette.ledYellow)
                            }
                        } else if isNext {
                            Text("PROXIMA")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.6)
                                .foregroundColor(palette.ledOrange)
                        }
                    }
                }
                Spacer()
                if isCurrent {
                    Text("AHORA")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(palette.controlOnText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.ledOrange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, isCurrent ? 12 : 8)
            .background(
                isCurrent ? palette.ledOrange.opacity(dayMode ? 0.12 : 0.16)
                : (item.played ? palette.background.opacity(0.4) : palette.deckFill)
            )
            .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .opacity(item.played && !isCurrent ? 0.55 : 1)
        .contextMenu {
            Button(item.played ? "Desmarcar" : "Marcar reproducida") {
                store.togglePlayed(item.id)
            }
            Button("Quitar de la lista", role: .destructive) {
                store.remove(id: item.id)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(store.status.isEmpty ? "Clic en una fila para marcar o desmarcar" : store.status)
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
            Spacer()
            Button("Exportar TXT") { exportTXT() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(palette.textSecondary)
            Text("entikrecords.com")
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

    private func ingestLive() {
        let decks = outputs.liveDeckSnapshots()
        store.ingest(playing: decks.compactMap { d in
            guard d.isPlaying, !d.title.isEmpty else { return nil }
            return (d.title, d.artist, d.label, d.isMaster || d.ltcSource)
        })
    }

    private func exportTXT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "STAGE-CONNECT-setlist.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? store.exportTXT().write(to: url, atomically: true, encoding: .utf8)
            store.status = "TXT exportado"
        }
    }
}
