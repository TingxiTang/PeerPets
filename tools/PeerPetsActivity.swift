import Foundation
import Darwin

struct Event: Decodable {
    let peer: String
    let phase: String
    let time: Double
    let pid: Int32
    let reason: String?
    var sender: String? = nil
    var provider: String? = nil
    var ownerLocked: Bool? = nil
    var name: String { peer == "codex" ? "Codex" : "Antigravity" }
    var active: Bool { phase == "starting" || phase == "busy" || phase == "retrying" }
    var result: String {
        if phase == "done" { return reason == "verified" ? "文件通过复验" : "已回复" }
        return ["auth":"调用认证失败", "permission":"权限受限", "quota":"额度受限",
                "timeout":"等待超时", "refused":"连接被拒绝", "connection":"连接失败", "nested":"重复发起", "directory":"目录不存在",
                "empty":"任务为空", "missing":"找不到 CLI", "launch":"启动失败",
                "no_reply":"没有回包", "mismatch":"口令不符", "missing_output":"缺少文件", "verification":"文件未通过复验",
                "cancelled":"已取消", "cli":"调用失败"][reason ?? ""] ?? "未接通"
    }
}

let cache = URL(fileURLWithPath: "/tmp/codex-agy-pet-\(getuid())")
struct Activity {
    var active: [Event] = []
    var latest: Event?
    var lastResultByPeer: [String:Event] = [:]
    var recentReplies: [Event] = []
    var whaleJobs: [Event] = []
    var whaleLast: Event?
    func whaleAtDesk(since launch: Double, at now: Double) -> Bool {
        if !whaleJobs.isEmpty { return true }
        guard let last = whaleLast, last.phase == "done" else { return false }
        return last.time >= launch && last.time <= now && now < last.time + 0.55
    }
    var whaleStatus: String {
        if let job = whaleJobs.first {
            let who = job.sender == "antigravity" ? "Antigravity" : "Codex"
            return whaleJobs.count > 1 ? "CC · 正在处理 " + String(whaleJobs.count) + " 项" : who + " → CC · 处理中"
        }
        return "CC · " + (whaleLast?.result ?? "歇一会儿")
    }
    static let craneDuration = 2.4
    func keepsBothAwake(since launch:Double, at now:Double) -> Bool {
        if !active.isEmpty { return true }
        guard let last = latest else { return false }
        return last.time >= launch && last.time <= now && now < last.time + Self.craneDuration
    }
    func returningReplies(since launch:Double, at now:Double) -> [Event] {
        recentReplies.filter { $0.phase == "done" && $0.time >= launch && $0.time <= now
            && now < $0.time + Self.craneDuration }
    }
    func foreground(at now: Double) -> Event? {
        if let first = active.first { return first }
        guard let latest, now - latest.time < 12 else { return nil }
        return latest
    }

    func waitingLabel(at now: Double) -> String? {
        guard let current = active.first else { return nil }
        let direction = current.peer == "codex" ? "Antigravity → Codex" : "Codex → Antigravity"
        let count = active.count > 1 ? " · \(active.count) 条进行中" : ""
        let elapsed = Int(max(0, now - current.time))
        let wait = elapsed >= 10 ? " · 已等 \(elapsed) 秒" : ""
        return direction + count + wait
    }

    func resultLabel(at now: Double, hovered: Bool) -> String? {
        guard let latest, hovered || now - latest.time < 18 else { return nil }
        let prefix = active.isEmpty ? "" : "上一条 · "
        return prefix + latest.name + " · " + latest.result
    }
}
func readActivity(at cache: URL = cache, now: Double = Date().timeIntervalSince1970) -> Activity {
    let urls = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys:nil)) ?? []
    var activity = Activity()
    for url in urls where url.pathExtension == "json" {
        guard let stream = try? FileHandle(forReadingFrom:url) else { continue }
        defer { try? stream.close() }
        guard let data = try? stream.readToEnd(),
              let e = try? JSONDecoder().decode(Event.self, from:data),
              e.time.isFinite else { continue }
        let guest = e.peer == "cc" && e.provider == "deepseek" && ["codex","antigravity"].contains(e.sender ?? "")
        guard guest || ["codex","antigravity"].contains(e.peer),
              (guest && e.active) || now-e.time < 86400 else { continue }
        if e.active {
            guard e.pid > 0 else { continue }
            if guest && e.ownerLocked == true {
                // Probe the same inode we decoded. A reused PID cannot keep a dead request alive.
                guard flock(stream.fileDescriptor, LOCK_SH | LOCK_NB) == -1 && errno == EWOULDBLOCK else { continue }
            } else {
                guard kill(e.pid,0) == 0 || errno == EPERM else { continue }
            }
            if guest { activity.whaleJobs.append(e) } else { activity.active.append(e) }
        } else if ["done","failed"].contains(e.phase) {
            if guest {
                if e.time > (activity.whaleLast?.time ?? 0) { activity.whaleLast = e }
                continue
            }
            if e.time > (activity.lastResultByPeer[e.peer]?.time ?? 0) { activity.lastResultByPeer[e.peer] = e }
            if e.phase == "done" && now < e.time + Activity.craneDuration { activity.recentReplies.append(e) }
            if e.time > (activity.latest?.time ?? 0) { activity.latest = e }
        }
    }
    activity.whaleJobs.sort { $0.time > $1.time }
    activity.active.sort { $0.time > $1.time }
    return activity
}
