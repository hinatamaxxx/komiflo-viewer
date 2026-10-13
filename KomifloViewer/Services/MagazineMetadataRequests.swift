import Foundation

/// 表示対象の掲載誌情報を待たせすぎず、同時通信は4件までに収める。
actor MagazineMetadataRequests {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < 4 {
            active += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}
