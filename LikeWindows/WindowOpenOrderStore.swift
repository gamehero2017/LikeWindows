//
//  WindowOpenOrderStore.swift
//  likeWindows
//

import AppKit

/// 记录每个应用窗口的打开顺序，避免 AX 返回的 Z 序导致 popup 列表重排。
enum WindowOpenOrderStore {
    private static var orderedKeys: [pid_t: [String]] = [:]
    private static var fingerprintKeys: [String: String] = [:]
    private static var fingerprintsByKey: [String: Set<String>] = [:]
    private static var cgKeyOwners: [String: String] = [:]
    private static let lock = NSLock()
    private static var didStartObservingTermination = false

    static func startObservingAppTermination() {
        guard !didStartObservingTermination else { return }
        didStartObservingTermination = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            removeProcess(app.processIdentifier)
        }
    }

    static func removeProcess(_ processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        orderedKeys.removeValue(forKey: processIdentifier)
        let prefix = "\(processIdentifier)|"
        fingerprintKeys = fingerprintKeys.filter { !$0.key.hasPrefix(prefix) }
        cgKeyOwners = cgKeyOwners.filter { !$0.value.hasPrefix(prefix) }
    }

    static func lookupKey(processIdentifier: pid_t, fingerprint: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return fingerprintKeys["\(processIdentifier)|\(fingerprint)"]
    }

    static func knownFingerprints(for orderKey: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return fingerprintsByKey[orderKey] ?? []
    }

    static func registerFingerprint(_ orderKey: String, fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        fingerprintsByKey[orderKey, default: []].insert(fingerprint)
    }

    static func orderKey(
        processIdentifier: pid_t,
        cgWindowNumber: Int?,
        fingerprint: String
    ) -> String {
        lock.lock()
        defer { lock.unlock() }

        let mapKey = "\(processIdentifier)|\(fingerprint)"

        if let existing = fingerprintKeys[mapKey] {
            if let cgWindowNumber {
                let cgKey = "cg:\(cgWindowNumber)"
                if existing.hasPrefix("fp:"),
                   cgKeyOwners[cgKey] == nil || cgKeyOwners[cgKey] == mapKey {
                    migrateOrderKey(from: existing, to: cgKey, processIdentifier: processIdentifier)
                    fingerprintKeys[mapKey] = cgKey
                    cgKeyOwners[cgKey] = mapKey
                    registerFingerprintLocked(cgKey, fingerprint: fingerprint)
                    return cgKey
                }
            }
            registerFingerprintLocked(existing, fingerprint: fingerprint)
            return existing
        }

        if let cgWindowNumber {
            let cgKey = "cg:\(cgWindowNumber)"
            if let owner = cgKeyOwners[cgKey], owner != mapKey {
                let key = "fp:\(UUID().uuidString)"
                fingerprintKeys[mapKey] = key
                registerFingerprintLocked(key, fingerprint: fingerprint)
                return key
            }

            fingerprintKeys[mapKey] = cgKey
            cgKeyOwners[cgKey] = mapKey
            registerFingerprintLocked(cgKey, fingerprint: fingerprint)
            return cgKey
        }

        let key = "fp:\(UUID().uuidString)"
        fingerprintKeys[mapKey] = key
        registerFingerprintLocked(key, fingerprint: fingerprint)
        return key
    }

    private static func registerFingerprintLocked(_ orderKey: String, fingerprint: String) {
        fingerprintsByKey[orderKey, default: []].insert(fingerprint)
    }

    static func sortedWindows(_ windows: [DockWindowInfo], for processIdentifier: pid_t) -> [DockWindowInfo] {
        lock.lock()
        defer { lock.unlock() }

        var order = orderedKeys[processIdentifier] ?? []
        let currentKeys = windows.map(\.stableOrderKey)

        for key in currentKeys where !order.contains(key) {
            order.append(key)
        }

        order = order.filter { currentKeys.contains($0) }
        orderedKeys[processIdentifier] = order

        let windowsByKey = Dictionary(
            windows.map { ($0.stableOrderKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return order.enumerated().compactMap { index, key in
            guard let info = windowsByKey[key] else { return nil }
            return DockWindowInfo(
                stableOrderKey: key,
                title: info.title,
                isMinimized: info.isMinimized,
                processIdentifier: info.processIdentifier,
                windowIndex: index,
                canClose: info.canClose,
                canMinimize: info.canMinimize,
                canZoom: info.canZoom,
                cgWindowNumber: info.cgWindowNumber
            )
        }
    }

    private static func migrateOrderKey(from oldKey: String, to newKey: String, processIdentifier: pid_t) {
        guard var order = orderedKeys[processIdentifier],
              let index = order.firstIndex(of: oldKey) else {
            return
        }
        order[index] = newKey
        orderedKeys[processIdentifier] = order
    }
}
