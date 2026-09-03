// FlowLayout.swift
// Layout que coloca los elementos en fila y salta a la siguiente cuando no
// caben. Ningun control se encoge, se recorta ni se sale de la ventana:
// si no hay ancho, baja de linea. La cabecera crece en alto lo justo.

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6
    /// Empuja el resto de elementos a la derecha a partir de este indice
    /// cuando sobra espacio en la primera linea.
    var trailingFrom: Int? = nil

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()

        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let add = row.indices.isEmpty ? size.width : size.width + spacing

            if !row.indices.isEmpty && row.width + add > maxWidth {
                result.append(row)
                row = Row()
                row.indices = [i]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(i)
                row.width += add
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rs = rows(subviews, maxWidth: maxWidth)
        let w = rs.map(\.width).max() ?? 0
        let h = rs.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rs.count - 1))
        return CGSize(width: min(w, maxWidth), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rs = rows(subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for (rowIndex, row) in rs.enumerated() {
            // Si cabe todo en una sola linea y hay punto de separacion,
            // el bloque final se alinea a la derecha.
            var gap: CGFloat = 0
            if rs.count == 1, let split = trailingFrom,
               let pos = row.indices.firstIndex(where: { $0 >= split }), pos > 0 {
                gap = max(0, bounds.width - row.width)
            }

            var x = bounds.minX
            for (posInRow, i) in row.indices.enumerated() {
                let sv = subviews[i]
                let size = sv.sizeThatFits(.unspecified)

                if gap > 0, let split = trailingFrom, i >= split,
                   posInRow > 0, row.indices[posInRow - 1] < split {
                    x += gap
                }

                sv.place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + (rowIndex < rs.count - 1 ? lineSpacing : 0)
        }
    }
}
