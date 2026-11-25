// Build with GlassDesk.swift and PeerPetsActivity.swift, targeting macOS 13 or later.
import AppKit
import Darwin

func color(_ value: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255,
            blue: CGFloat(value & 255)/255, alpha: 1)
}
let ink = color(0x25253D), paper = color(0xFFF8E8), gold = color(0xF1CC87), lavender = color(0xC0B1F6)
func box(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ r: CGFloat,_ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: NSRect(x:x,y:y,width:w,height:h),xRadius:r,yRadius:r).fill()
}
func label(_ s: String,_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ size: CGFloat,_ c: NSColor, bold: Bool = false) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let font = NSFont.systemFont(ofSize:size, weight:bold ? .semibold : .medium)
    (s as NSString).draw(in:NSRect(x:x,y:y,width:w,height:size+7),
                          withAttributes:[.font:font,.foregroundColor:c,.paragraphStyle:p])
}

enum Companion: CaseIterable {
    case dragon, cat
    var name: String { self == .dragon ? "Codex" : "Antigravity" }
    var bundleID: String { self == .dragon ? "com.openai.codex" : "com.google.antigravity" }
    var badge: NSRect {
        self == .dragon ? NSRect(x:64,y:194,width:56,height:21) : NSRect(x:239,y:194,width:90,height:21)
    }
}

final class PetButton: NSAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let action = action else { return false }
        action()
        return true
    }
}

final class Scene: NSView {
    override var isFlipped: Bool { true }
    let launchedAt = Date().timeIntervalSince1970
    var activity = Activity() {
        didSet { updateProps() }
    }
    var hovered = false {
        didSet { updateProps(); needsDisplay = true }
    }
    private var shortcutButtons: [DeskButton] = []
    private(set) var tossStart:Double?
    var animatingProps:Bool {
        tossStart != nil || shortcutButtons.contains { $0.usedAt.isFinite } ||
            !activity.returningReplies(since:launchedAt, at:Date().timeIntervalSince1970).isEmpty
    }
    private func updateProps() {
        let playable = hovered && activity.active.isEmpty &&
            activity.returningReplies(since:launchedAt,at:Date().timeIntervalSince1970).isEmpty
        if !playable { tossStart = nil }
        for button in shortcutButtons {
            button.isHidden = !hovered || (button.item == .paper && !playable)
            if button.item == .paper { button.paperAirborne = tossStart != nil }
        }
    }
    @objc private func tossPaper() {
        guard hovered, tossStart == nil, activity.active.isEmpty,
              activity.returningReplies(since:launchedAt,at:Date().timeIntervalSince1970).isEmpty else { return }
        tossStart = ProcessInfo.processInfo.systemUptime
        updateProps()
        needsDisplay = true
    }
    func tick(at time:Double) {
        clock = time
        if let start = tossStart, time-start >= 1.65 { tossStart=nil; updateProps() }
        for button in shortcutButtons where button.usedAt.isFinite {
            button.needsDisplay = true
            if time-button.usedAt >= 0.32 { button.usedAt = -.infinity }
        }
        needsDisplay=true
    }
    var event: Event? {
        activity.foreground(at:Date().timeIntervalSince1970)
    }
    let closeRect = NSRect(x:345,y:4,width:24,height:24)
    var sprites: [(Companion,NSImage,NSRect)] = []
    var hideAtRest = UserDefaults.standard.bool(forKey: "hideAtRest")
    var notice: (text: String, until: TimeInterval)?
    var press: (pet: Companion, start: NSPoint, origin: NSPoint)?
    var dragging = false

    func companion(at point: NSPoint) -> Companion? {
        let probe = NSRect(origin:point, size:NSSize(width:1,height:1))
        for (pet,image,rect) in sprites {
            if pet.badge.contains(point) || (rect.contains(point) &&
                image.hitTest(probe,withDestinationRect:rect,context:nil,hints:nil,flipped:true)) { return pet }
        }
        return nil
    }
    func acceptsClick(_ point:NSPoint) -> Bool {
        (hovered && (closeRect.contains(point) || shortcutButtons.contains { !$0.isHidden && $0.frame.contains(point) }))
            || companion(at:point) != nil
    }

    func setupAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("同桌")
        let buttons = Companion.allCases.map { pet -> PetButton in
            let button = PetButton()
            button.setAccessibilityParent(self)
            button.setAccessibilityEnabled(true)
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel("打开 " + pet.name)
            button.setAccessibilityFrameInParentSpace(NSRect(x:pet.badge.midX-60,y:40,width:120,height:150))
            button.action = { [weak self] in self?.openClient(pet) }
            return button
        }
        shortcutButtons = [
            DeskButton(.desktop,frame:NSRect(x:121,y:181,width:60,height:39),title:"显示桌面",
                       help:"显示桌面",target:self,action:#selector(showDesktop)),
            DeskButton(.finder,frame:NSRect(x:185,y:181,width:53,height:39),title:"Finder",
                       help:"在 Finder 打开个人主目录",target:self,action:#selector(openFinder)),
            DeskButton(.paper,frame:NSRect(x:175,y:151,width:26,height:26),title:"纸团",
                       help:"点纸团，让紫猫和白龙传球",target:self,action:#selector(tossPaper))]
        for button in shortcutButtons {
            addSubview(button)
        }
        updateProps()
        setAccessibilityChildren((buttons as [Any]) + shortcutButtons)
    }

    @objc private func showDesktop() {
        // Mission Control ships its own menu mapping. Use the system's Show Desktop action.
        let url = URL(fileURLWithPath:"/System/Applications/Mission Control.app")
        guard let bundle = Bundle(url:url),
              let menu = bundle.url(forResource:"Menu", withExtension:"plist"),
              let data = try? Data(contentsOf:menu),
              let entries = try? PropertyListSerialization.propertyList(from:data, format:nil) as? [[String:Any]],
              let command = entries.first(where:{ $0["name"] as? String == "Show Desktop" })?["command"] as? Int
        else { showNotice("系统未提供显示桌面动作"); return }
        let options = NSWorkspace.OpenConfiguration()
        options.arguments = [String(command)]
        options.activates = false
        options.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at:url, configuration:options) { [weak self] _, error in
            if error != nil { DispatchQueue.main.async { self?.showNotice("显示桌面失败") } }
        }
    }

    @objc private func openFinder() {
        shortcutButtons.first { $0.item == .finder }?.usedAt = ProcessInfo.processInfo.systemUptime
        let workspace = NSWorkspace.shared
        guard let finder = workspace.urlForApplication(withBundleIdentifier:"com.apple.finder") else {
            showNotice("未找到 Finder"); return
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        workspace.open([FileManager.default.homeDirectoryForCurrentUser], withApplicationAt:finder,
                       configuration:options) { [weak self] _, error in
            if error != nil { DispatchQueue.main.async { self?.showNotice("打开 Finder 失败") } }
        }
    }

    func openClient(_ pet: Companion) {
        let workspace = NSWorkspace.shared
        let installed = NSRunningApplication.runningApplications(withBundleIdentifier:pet.bundleID).first?.bundleURL
            ?? workspace.urlForApplication(withBundleIdentifier:pet.bundleID)
        guard let url = installed else { showNotice("未找到 " + pet.name); return }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        workspace.openApplication(at:url,configuration:options) { [weak self] _,error in
            DispatchQueue.main.async {
                if error != nil { self?.showNotice("打开 " + pet.name + " 失败") }
                else if workspace.frontmostApplication?.bundleIdentifier == pet.bundleID {
                    self?.showNotice("已切到 " + pet.name)
                }
            }
        }
    }
    func showNotice(_ text: String) {
        notice = (text, ProcessInfo.processInfo.systemUptime + 4)
        needsDisplay = true
    }

    var clock: TimeInterval = 0
    let artwork: [String:NSImage] = {
        var images: [String:NSImage] = [:]
        for character in ["gpt","gemini"] {
            for pose in ["idle","thinking"] {
                let name = character + "-" + pose
                if let path = Bundle.main.url(forResource:name,withExtension:"webp") {
                    images[name] = NSImage(contentsOf:path)
                }
            }
        }
        return images
    }()
    func character(_ name: String, _ pose: String, at x: CGFloat, bottom: CGFloat) {
        guard let image = artwork[name + "-" + pose], image.size.height > 0 else { return }
        let ratio = min(145/image.size.height, 150/image.size.width)
        let w = image.size.width * ratio, h = image.size.height * ratio
        let rect=NSRect(x:x-w/2,y:bottom-h,width:w,height:h)
        sprites.append((name == "gpt" ? .dragon : .cat,image,rect))
        image.draw(in:rect,from:.zero,
                   operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high.rawValue])
    }
    func bubble(_ text: String, at x: CGFloat) {
        box(x-40, 29, 80, 23, 10, paper)
        let tip = NSBezierPath()
        tip.move(to:NSPoint(x:x-4,y:51)); tip.line(to:NSPoint(x:x,y:56))
        tip.line(to:NSPoint(x:x+5,y:51)); tip.close(); paper.setFill(); tip.fill()
        label(text,x-40,32,80,11,ink,bold:true)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using:.copy)
        sprites.removeAll(keepingCapacity:true)
        let now = Date().timeIntervalSince1970
        let event = activity.foreground(at:now)
        let phase = event?.phase ?? "idle", busy = event?.active == true
        let receiver: CGFloat = event?.peer == "codex" ? 92 : 284
        let sender: CGFloat = receiver == 92 ? 284 : 92
        let early = busy && now - (event?.time ?? now) < 2.8
        func chip(_ text:String, x:CGFloat, y:CGFloat, accent:NSColor) {
            let font=NSFont.systemFont(ofSize:11,weight:.semibold)
            let w=ceil((text as NSString).size(withAttributes:[.font:font]).width)+20
            box(x,y,w,20,10,ink.withAlphaComponent(0.9))
            label(text,x,y+2,w,11,accent,bold:true)
        }
        let result = activity.resultLabel(at:now, hovered:hovered)
        let showingNotice = notice.map { clock < $0.until } ?? false
        let resting = !hovered && event == nil && result == nil && !showingNotice
        if resting && hideAtRest { return }
        if let waiting = activity.waitingLabel(at:now) {
            chip(waiting,x:7,y:5,accent:paper)
        }
        if hovered {
            box(closeRect.minX,closeRect.minY,closeRect.width,closeRect.height,12,ink)
            label("×",closeRect.minX,closeRect.minY-1,closeRect.width,18,paper)
        }
        if let result, let last=activity.latest {
            chip(result,x:7,y:busy ? 220:5,
                 accent:last.phase=="failed" ? color(0xFFB8AD) : gold)
        }
        if let notice = notice, showingNotice { chip(notice.text,x:7,y:30,accent:paper) }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func bob(_ x: CGFloat) -> CGFloat {
            guard !reduce else { return 0 }
            return busy && x == receiver ? abs(sin(clock*4))*3 : (sin(clock*1.5+x)>0.8 ? 1:0)
        }
        let beat = CGFloat(min(1, max(0, (clock-(tossStart ?? clock))/1.65)))
        let playing = tossStart != nil && !reduce
        let catchRight: CGFloat = playing ? max(0, 1-abs(beat-0.25)*12) : 0
        let catchLeft: CGFloat = playing ? max(0, 1-abs(beat-0.72)*12) : 0
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext.current?.cgContext
        context?.setAlpha(resting ? 0.36 : 1)
        context?.beginTransparencyLayer(auxiliaryInfo:nil)
        drawDesk(waitingAt:busy ? (receiver == 92 ? 38 : 338) : nil)
        character("gpt",busy && receiver == 92 ? "thinking" : "idle",
                  at:92,bottom:183-bob(92)-catchLeft*4)
        character("gemini",busy && receiver == 284 ? "thinking" : "idle",
                  at:284,bottom:183-bob(284)-catchRight*4)
        if tossStart != nil {
            if reduce {
                context?.saveGState()
                context?.setAlpha(0.6 + 0.4*min(1,CGFloat(max(0,clock-(tossStart ?? clock)))/0.2))
                drawCrumpledPaper(at:NSPoint(x:188,y:164))
                context?.restoreGState()
            } else {
                let start:CGFloat, end:CGFloat, t:CGFloat, height:CGFloat
                if beat < 0.25 { start=188; end=245; t=beat/0.25; height=20 }
                else if beat < 0.72 { start=245; end=130; t=(beat-0.25)/0.47; height=45 }
                else { start=130; end=188; t=(beat-0.72)/0.28; height=25 }
                let x=start+(end-start)*t*t*(3-2*t)
                drawCrumpledPaper(at:NSPoint(x:x,y:164-height*sin(.pi*t)),angle:18*sin(.pi*2*t))
            }
        }
        if !resting {
            box(64,194,56,21,10,ink.withAlphaComponent(0.9))
            box(239,194,90,21,10,ink.withAlphaComponent(0.9))
            label("Codex",42,195,100,13,gold,bold:true)
            label("Antigravity",222,195,124,13,lavender,bold:true)
        }
        context?.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        if let e = event {
            let phrase: String
            switch phase {
            case "starting": phrase = "正在联系…"
            case "busy": phrase = early ? "帮我看看？" : "等对方回包…"
            case "retrying": phrase = "再连一次…"
            case "done": phrase = "回你啦！"
            default: phrase = e.result
            }
            bubble(phrase,at:early || phase == "failed" ? sender : receiver)
        }
        for reply in activity.returningReplies(since:launchedAt,at:now) {
            let source:CGFloat = reply.peer == "codex" ? 105 : 271
            drawCrane(from:source,to:376-source,progress:now-reply.time,reduce:reduce)
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let pos = convert(event.locationInWindow,from:nil)
        if hovered && closeRect.contains(pos) { NSApp.terminate(nil); return }
        guard let window = window, let pet = companion(at:pos) else { return }
        press = (pet, window.convertPoint(toScreen:event.locationInWindow), window.frame.origin)
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press = press, let window = window else { return }
        let cursor = window.convertPoint(toScreen:event.locationInWindow)
        let dx = cursor.x-press.start.x, dy = cursor.y-press.start.y
        if hypot(dx,dy) >= 5 { dragging = true }
        if dragging { window.setFrameOrigin(NSPoint(x:press.origin.x+dx,y:press.origin.y+dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let press = press else { return }
        let point = convert(event.locationInWindow,from:nil)
        let cursor = window?.convertPoint(toScreen:event.locationInWindow) ?? press.start
        let click = !dragging && hypot(cursor.x-press.start.x,cursor.y-press.start.y) < 5
        self.press = nil
        dragging = false
        if click && companion(at:point) == press.pet { openClient(press.pet) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard companion(at:convert(event.locationInWindow,from:nil)) != nil else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle:"空闲时完全隐身",action:#selector(toggleHidden),keyEquivalent:"")
        item.target = self
        item.state = hideAtRest ? .on : .off
        return menu
    }
    @objc func toggleHidden() {
        hideAtRest.toggle()
        UserDefaults.standard.set(hideAtRest,forKey:"hideAtRest")
        needsDisplay = true
    }
}

final class PetApp: NSObject, NSApplicationDelegate {
    let scene = Scene(frame:NSRect(x:0,y:0,width:376,height:243))
    var panel: NSPanel!
    var timer: Timer?
    var lastCheck: TimeInterval = -10
    var lastFrame: TimeInterval = -10
    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect:scene.bounds,styleMask:[.borderless,.nonactivatingPanel],
                        backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false; panel.ignoresMouseEvents=true
        panel.level = .floating; panel.hidesOnDeactivate=false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=scene
        panel.setFrameAutosaveName("PeerPetsGijinkaWindow")
        if !panel.setFrameUsingName("PeerPetsGijinkaWindow"), let screen=NSScreen.main {
            let frame=screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x:frame.maxX-396,y:frame.minY+20))
        }
        panel.setContentSize(NSSize(width:376,height:243))
        scene.setupAccessibility()
        scene.toolTip = "点击角色打开客户端 · 点纸团传球 · 悬停使用课桌和 Finder · 拖动移动"
        panel.orderFrontRegardless()
        let tick = Timer(timeInterval:1/30.0,repeats:true) { [weak self] _ in
            guard let self = self else {return}
            let t = ProcessInfo.processInfo.systemUptime
            let point=self.scene.convert(self.panel.mouseLocationOutsideOfEventStream,from:nil)
            let hovered=self.scene.bounds.contains(point)
            if hovered != self.scene.hovered {
                self.scene.hovered=hovered; self.scene.needsDisplay=true
            }
            let passThrough = self.scene.press == nil && (!hovered || !self.scene.acceptsClick(point))
            if self.panel.ignoresMouseEvents != passThrough { self.panel.ignoresMouseEvents=passThrough }
            if t-self.lastCheck >= 0.5 { self.scene.activity=readActivity(); self.lastCheck=t }
            let interval: Double = self.scene.animatingProps ? 1/30.0 : (self.scene.event != nil ? 0.125 : 0.5)
            if t-self.lastFrame >= interval {
                self.scene.tick(at:t); self.lastFrame=t
            }
        }
        timer=tick; RunLoop.main.add(tick,forMode:.common)
    }
}

@main
enum PeerPets {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = PetApp()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
