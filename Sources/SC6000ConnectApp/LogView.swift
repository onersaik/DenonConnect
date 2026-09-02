// LogView.swift
// Panel de log de protocolo, útil para diagnosticar problemas de conexión.

import SwiftUI
import StageLinqKit

struct LogView: View {
    @EnvironmentObject var manager: StageLinqManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(manager.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .id(index)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.35))
            .onChange(of: manager.logLines.count) { _ in
                if let last = manager.logLines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
