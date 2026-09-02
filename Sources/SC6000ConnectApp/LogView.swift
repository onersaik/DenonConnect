// LogView.swift
// Log de protocolo de los dos motores (StageLinq y Pro DJ Link). Es la
// herramienta de diagnóstico cuando algo no aparece en la red.

import SwiftUI
import StageLinqKit

struct LogView: View {
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager

    private var lines: [String] {
        manager.logLines.map { "[denon] " + $0 } + proDJLink.logLines.map { "[pioneer] " + $0 }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.4))
            .onChange(of: lines.count) { _ in
                if let last = lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
