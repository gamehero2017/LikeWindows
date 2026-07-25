//
//  WindowOpenOrderStore.swift
//  likeWindows
//

import AppKit

/// 每个应用窗口的「打开顺序」与稳定身份存储。
///
/// ## 要解决的问题
/// AX 返回的窗口列表顺序常随 Z 序 / 焦点变化，导致悬停弹窗列表上下跳动。
/// 本类型为每个窗口分配稳定的 `stableOrderKey`，并按**首次出现顺序**排列。
///
/// ## 数据结构（均受 `lock` 保护）
/// - `orderedKeys[pid]`：该进程窗口 orderKey 的出现顺序
/// - `fingerprintKeys["pid|fingerprint"]` → orderKey：指纹到身份的映射
/// - `fingerprintsByKey[orderKey]`：某身份历史上出现过的指纹集合（标题/尺寸变化后仍可配对）
/// - `cgKeyOwners`：CG 窗口号键的占用，避免两个指纹抢同一个 `cg:` key
///
/// ## orderKey 形态
/// - `cg:<windowNumber>`：已匹配到 CGWindow 时优先（更稳）
/// - `fp:<UUID>`：仅有指纹时的临时身份；之后若拿到 CG 号可 migrate 升级
enum WindowOpenOrderStore {
    private static var orderedKeys: [pid_t: [String]] = [:]
    private static var fingerprintKeys: [String: String] = [:]
    private static var fingerprintsByKey: [String: Set<String>] = [:]
    private static var cgKeyOwners: [String: String] = [:]
    private static let lock = NSLock()
    private static let maxFingerprintsPerProcess = 50
    private static var didStartObservingTermination = false

    /// 监听应用退出，清理对应进程的顺序缓存，避免 pid 复用后串数据。
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

    /// 移除指定进程的全部顺序与指纹映射。
    static func removeProcess(_ processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        if let order = orderedKeys.removeValue(forKey: processIdentifier) {
            for key in order {
                fingerprintsByKey.removeValue(forKey: key)
            }
        }

        let prefix = "\(processIdentifier)|"
        fingerprintKeys = fingerprintKeys.filter { !$0.key.hasPrefix(prefix) }
        cgKeyOwners = cgKeyOwners.filter { !$0.value.hasPrefix(prefix) }
    }

    /// 由当前指纹反查已登记的 stableOrderKey。
    static func lookupKey(processIdentifier: pid_t, fingerprint: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return fingerprintKeys["\(processIdentifier)|\(fingerprint)"]
    }

    /// 某 orderKey 历史上关联过的指纹（窗口改标题/改尺寸后仍能配对到同一身份）。
    static func knownFingerprints(for orderKey: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return fingerprintsByKey[orderKey] ?? []
    }

    /// 登记指纹与 orderKey 的关联。
    static func registerFingerprint(_ orderKey: String, fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        registerFingerprintLocked(orderKey, fingerprint: fingerprint)
    }

    /// 为窗口生成或复用稳定 orderKey。
    ///
    /// 逻辑概要：
    /// 1. 指纹已有映射 → 复用；若现有是 `fp:` 且首次拿到空闲 CG 号 → migrate 为 `cg:`
    /// 2. 指纹未见过但有 CG 号 → 用 `cg:`（若 CG 号已被其他指纹占用则退回新 `fp:`）
    /// 3. 仅有指纹 → 新建 `fp:UUID`
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
                // 临时 fp 身份升级为稳定 cg 身份（CG 号未被他人占用时）
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
            // CG 号已被另一指纹占用：避免错误合并，改发新 fp
            if let owner = cgKeyOwners[cgKey], owner != mapKey {
                let key = "fp:\(UUID().uuidString)"
                fingerprintKeys[mapKey] = key
                registerFingerprintLocked(key, fingerprint: fingerprint)
                evictExcessFingerprintsLocked(for: processIdentifier)
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
        evictExcessFingerprintsLocked(for: processIdentifier)
        return key
    }

    private static func registerFingerprintLocked(_ orderKey: String, fingerprint: String) {
        fingerprintsByKey[orderKey, default: []].insert(fingerprint)
    }

    /// 按首次出现顺序排序窗口列表，并同步该进程的打开顺序记录。
    /// 新窗口追加到末尾；已关闭的 key 从顺序与指纹表中剔除。
    static func sortedWindows(_ windows: [DockWindowInfo], for processIdentifier: pid_t) -> [DockWindowInfo] {
        lock.lock()
        defer { lock.unlock() }

        var order = orderedKeys[processIdentifier] ?? []
        let currentKeys = windows.map(\.stableOrderKey)

        for key in currentKeys where !order.contains(key) {
            order.append(key)
        }

        let removedKeys = order.filter { !currentKeys.contains($0) }
        if !removedKeys.isEmpty {
            for key in removedKeys {
                fingerprintsByKey.removeValue(forKey: key)
            }
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

    /// 将顺序表与指纹集合从旧 key 迁到新 key（fp → cg 升级时）。
    private static func migrateOrderKey(from oldKey: String, to newKey: String, processIdentifier: pid_t) {
        guard var order = orderedKeys[processIdentifier],
              let index = order.firstIndex(of: oldKey) else {
            return
        }

        if let fingerprints = fingerprintsByKey.removeValue(forKey: oldKey) {
            fingerprintsByKey[newKey] = fingerprints
        }

        order[index] = newKey
        orderedKeys[processIdentifier] = order
    }

    /// 限制每进程指纹映射数量，优先淘汰仍为 `fp:` 的临时项。
    private static func evictExcessFingerprintsLocked(for processIdentifier: pid_t) {
        let prefix = "\(processIdentifier)|"
        let mapKeys = fingerprintKeys.keys.filter { $0.hasPrefix(prefix) }
        guard mapKeys.count > maxFingerprintsPerProcess else { return }

        let removable = mapKeys.filter { fingerprintKeys[$0]?.hasPrefix("fp:") == true }
        let excess = removable.count - max(0, maxFingerprintsPerProcess - (mapKeys.count - removable.count))
        guard excess > 0 else { return }

        for mapKey in removable.prefix(excess) {
            if let orderKey = fingerprintKeys.removeValue(forKey: mapKey) {
                fingerprintsByKey.removeValue(forKey: orderKey)
            }
        }
    }
}
