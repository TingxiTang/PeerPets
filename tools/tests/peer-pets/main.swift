// swiftc tools/PetReactions.swift tools/PeerPetsActivity.swift tools/tests/peer-pets/main.swift -o /tmp/test-peer-pets
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
// At the deadline, subtracting two timestamps can round the age below 2.4.
let replyTime = 100001.0
let deadline = replyTime + Activity.craneDuration
let reply = Event(peer:"codex", phase:"done", time:replyTime, pid:getpid(), reason:nil)
let timedReply = Activity(latest:reply, recentReplies:[reply])
precondition(timedReply.returningReplies(since:replyTime, at:deadline.nextDown).count == 1)
precondition(timedReply.returningReplies(since:replyTime, at:deadline).isEmpty)
precondition(!timedReply.keepsBothAwake(since:replyTime, at:deadline))
// Silence and a second request finishing must not put the participants to sleep.
precondition(concurrent.keepsBothAwake(since:now-1,at:now+180))
try write("other","failed",age:0,peer:"codex",reason:"cancelled")
let settled = snapshot()
precondition(settled.active.isEmpty && settled.keepsBothAwake(since:now-1,at:now))
precondition(!settled.keepsBothAwake(since:now-1,at:now+3))
precondition(!settled.keepsBothAwake(since:now+0.1,at:now+0.2))
precondition(settled.lastResultByPeer["codex"]?.reason == "cancelled")
precondition(settled.lastResultByPeer["antigravity"]?.phase == "failed")
precondition(settled.waitingLabel(at:now) == nil)
print("桌宠联系、并发、回执、失败、取消、终态停表及死进程检查通过")

// Visits are per character. A stationary pointer, a quick pass or a busy request consumes no extra greeting.
var hover = PetReactions()
func visit(_ pet:Companion, _ t:Double, awake:Bool=true) {
    hover.observe(nil,awake:false,allowed:true,at:t)
    hover.observe(pet,awake:awake,allowed:true,at:t+0.1)
    hover.observe(pet,awake:awake,allowed:true,at:t+0.3)
}
hover.observe(.cat,awake:true,allowed:true,at:0)
hover.observe(nil,awake:false,allowed:true,at:0.08)
visit(.cat,1)
precondition(hover.response == .welcome)
hover.observe(.cat,awake:true,allowed:true,at:3)
precondition(hover.response == nil)
visit(.dragon,4)
precondition(hover.response == .welcome)
visit(.cat,5)
precondition(hover.response == .familiar)
visit(.cat,7)
precondition(hover.response == nil)
visit(.cat,40)
precondition(hover.response == .welcome)
hover.observe(.cat,awake:true,allowed:false,at:41)
hover.observe(.cat,awake:true,allowed:true,at:43)
precondition(hover.response == nil)
visit(.dragon,44,awake:false)
precondition(hover.response == .stir)
print("悬停停留、独立记忆、连续接近、过期、睡姿及在途抑制检查通过")

// Each registered CC job has its own event file. The two original roles keep their own activity.
func ccEvent(_ id:String, _ phase:String, _ timestamp:Double, _ pid:Int32 = getpid()) throws {
    let value:[String:Any]=["peer":"cc","provider":"deepseek","sender":"codex","phase":phase,"pid":pid,"time":timestamp]
    try JSONSerialization.data(withJSONObject:value).write(to:directory.appendingPathComponent(id+".json"))
}
try ccEvent("whaleA","busy",now-150)
try ccEvent("whaleB","busy",now-1)
try ccEvent("whaleOrphan","busy",now,Int32.max)
precondition(snapshot().whaleJobs.count == 2 && snapshot().active.isEmpty)
try ccEvent("whaleB","failed",now)
precondition(snapshot().whaleJobs.count == 1 && snapshot().whaleAtDesk(since:now-1,at:now))
try ccEvent("whaleA","done",now+1)
let landed=readActivity(at:directory,now:now+1)
precondition(landed.whaleJobs.isEmpty && landed.whaleAtDesk(since:now,at:now+1.2))
precondition(!landed.whaleAtDesk(since:now,at:now+1.55))
precondition(!landed.whaleAtDesk(since:now+1.1,at:now+1.2))
precondition(landed.returningReplies(since:now,at:now+1).allSatisfy { $0.peer != "cc" })
print("鲸鱼娘并发、长静默、死进程、终态和旧回执检查通过")

// The kernel releases a crashed bridge's lock even if its PID later belongs to a live process.
let lockedURL = directory.appendingPathComponent("held.json")
let held:[String:Any] = ["peer":"cc","provider":"deepseek","sender":"antigravity","phase":"busy",
                         "pid":getpid(),"time":now-90000,"ownerLocked":true]
try JSONSerialization.data(withJSONObject:held).write(to:lockedURL)
let owner = try FileHandle(forWritingTo:lockedURL)
precondition(flock(owner.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
precondition(snapshot().whaleJobs.count == 1)
try owner.close()
precondition(snapshot().whaleJobs.isEmpty)
print("跨日静默与 PID 重用时的请求锁检查通过")
