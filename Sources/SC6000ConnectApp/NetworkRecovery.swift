// NetworkRecovery.swift
// Vigila Ethernet/Wi‑Fi: al reconectar el cable o recuperar la LAN,
// dispara recuperación inmediata de StageLinq / Pro DJ Link y avisa a LTC.

import Foundation
import Network
import StageLinqKit

final class NetworkRecoveryMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.entikrecords.stageconnect.net-recovery")
    private weak var stageLinq: StageLinqManager?
    private weak var proDJLink: ProDJLinkManager?
    private weak var outputs: OutputController?
    private var lastSatisfied = false
    private var lastIfaceSig = ""
    private var started = false

    func start(
        stageLinq: StageLinqManager,
        proDJLink: ProDJLinkManager,
        outputs: OutputController
    ) {
        guard !started else { return }
        started = true
        self.stageLinq = stageLinq
        self.proDJLink = proDJLink
        self.outputs = outputs

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
        // Firma inicial sin kick (arranque normal).
        let path = monitor.currentPath
        lastSatisfied = path.status == .satisfied
        lastIfaceSig = Self.signature(path)
    }

    func stop() {
        monitor.cancel()
        started = false
    }

    private func handle(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        let sig = Self.signature(path)
        let regained = satisfied && (!lastSatisfied || sig != lastIfaceSig)
        lastSatisfied = satisfied
        if sig != lastIfaceSig {
            lastIfaceSig = sig
        }
        guard regained else {
            if !satisfied {
                DispatchQueue.main.async { [weak self] in
                    self?.outputs?.noteNetworkLost()
                }
            }
            return
        }
        let detail = sig.isEmpty ? "LAN" : sig
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outputs?.noteNetworkRestored()
            self.stageLinq?.kickNetworkRecovery(reason: "path \(detail)")
            self.proDJLink?.kickNetworkRecovery(reason: "path \(detail)")
        }
    }

    private static func signature(_ path: NWPath) -> String {
        var parts: [String] = []
        if path.usesInterfaceType(.wiredEthernet) { parts.append("eth") }
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.other) { parts.append("other") }
        // Cambio de IPv4 en en* (cable directo / DHCP).
        let lan = NetworkInfo.allLANAddresses().map(\.description).sorted().joined(separator: ",")
        if !lan.isEmpty { parts.append(lan) }
        return parts.joined(separator: "|")
    }
}
