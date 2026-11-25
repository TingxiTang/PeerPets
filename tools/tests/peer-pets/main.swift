// swiftc tools/PeerPetsActivity.swift tools/tests/peer-pets/main.swift -o /tmp/test-peer-pets
import Foundation
import Darwin

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let now = Date().timeIntervalSince1970
func write(_ id: String, _ phase: String, age: Double, peer: String = "antigravity",
           reason: String = "", pid: Int32 = getpid()) throws {
    let event: [String: Any] = ["peer":peer, "phase":phase, "time":now-age, "pid":pid, "reason":reason]
    try JSONSerialization.data(withJSONObject:event).write(to:directory.appendingPathComponent(id+".json"), options:.atomic)
}
func snapshot() -> Activity { readActivity(at:directory, now:now) }

try write("a", "starting", age:0)
precondition(snapshot().foreground(at:now)?.phase == "starting")
try write("a", "busy", age:20)
try write("b", "busy", age:12, peer:"codex")
precondition(snapshot().waitingLabel(at:now) == "Antigravity → Codex · 2 条进行中 · 已等 12 秒")
try write("b", "failed", age:2, peer:"codex", reason:"timeout")
precondition(snapshot().waitingLabel(at:now) == "Codex → Antigravity · 已等 20 秒")
precondition(snapshot().resultLabel(at:now, hovered:false) == "上一条 · Codex · 等待超时")
try write("a", "done", age:1)
precondition(snapshot().resultLabel(at:now, hovered:false) == "Antigravity · 已回复")
precondition(snapshot().foreground(at:now)?.phase == "done")
precondition(snapshot().waitingLabel(at:now+10) == nil)
for reason in ["no_reply", "timeout", "cancelled", "mismatch"] {
    try write("a", "failed", age:0, reason:reason)
    let state = snapshot()
    precondition(state.active.isEmpty && state.foreground(at:now)?.reason == reason)
    precondition(state.waitingLabel(at:now) == nil && state.waitingLabel(at:now+15) == nil)
    precondition(state.resultLabel(at:now+19, hovered:false) == nil)
    precondition(state.resultLabel(at:now+19, hovered:true) != nil)
}
// A dead bridge's busy record cannot restart the waiting clock.
try write("orphan", "busy", age:10, pid:Int32.max)
precondition(snapshot().waitingLabel(at:now) == nil)
precondition(snapshot().returningReplies(since:now-10,at:now).isEmpty)
try write("reply", "done", age:0.5)
try write("other", "busy", age:1, peer:"codex")
let concurrent = snapshot()
precondition(concurrent.active.count == 1)
precondition(concurrent.returningReplies(since:now-1,at:now).map(\.peer) == ["antigravity"])
precondition(concurrent.returningReplies(since:now,at:now).isEmpty)
precondition(concurrent.returningReplies(since:now-1,at:now+Activity.craneDuration).isEmpty)
print("桌宠联系、并发、回执、失败、取消、终态停表及死进程检查通过")
