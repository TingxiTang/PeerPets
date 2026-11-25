// Vector artwork for the glass desk. All coordinates use a top-left origin.
import AppKit

private let ice = color(0xDAF7FF)
private let aqua = color(0x91CFE0)
private let blue = color(0x507B98)
private let brass = color(0xC79D61)
private let ivory = color(0xFFF7DF)

private func path(_ points: [NSPoint], closed: Bool = true) -> NSBezierPath {
    let p = NSBezierPath()
    guard let first = points.first else { return p }
    p.move(to:first)
    for point in points.dropFirst() { p.line(to:point) }
    if closed { p.close() }
    p.lineJoinStyle = .round
    p.lineCapStyle = .round
    return p
}
private func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x:x,y:y) }
private func facet(_ points: [NSPoint], _ fill:NSColor, outline:NSColor? = nil) {
    let p = path(points)
    fill.setFill(); p.fill()
    if let edge = outline { edge.setStroke(); p.lineWidth = 0.8; p.stroke() }
}
private func stroke(_ points:[NSPoint], _ tint:NSColor, _ width:CGFloat = 1) {
    let p = path(points,closed:false)
    tint.setStroke(); p.lineWidth = width; p.stroke()
}
private func dot(_ x:CGFloat,_ y:CGFloat,_ r:CGFloat,_ tint:NSColor) {
    tint.setFill()
    NSBezierPath(ovalIn:NSRect(x:x-r,y:y-r,width:2*r,height:2*r)).fill()
}

func drawDesk(waitingAt lamp: CGFloat?) {
    let glass = NSBezierPath()
    glass.move(to:pt(44,174)); glass.line(to:pt(330,174))
    glass.curve(to:pt(339,177),controlPoint1:pt(335,174),controlPoint2:pt(337,175))
    glass.line(to:pt(350,186)); glass.curve(to:pt(346,191),controlPoint1:pt(354,190),controlPoint2:pt(350,191))
    glass.line(to:pt(30,191)); glass.curve(to:pt(26,186),controlPoint1:pt(25,191),controlPoint2:pt(22,190))
    glass.line(to:pt(36,177)); glass.curve(to:pt(44,174),controlPoint1:pt(39,175),controlPoint2:pt(41,174))
    glass.close()
    for x: CGFloat in [42,325] {
        facet([pt(x,191),pt(x+9,191),pt(x+7,208),pt(x+3,211)],
              aqua.withAlphaComponent(0.44),outline:blue.withAlphaComponent(0.65))
        stroke([pt(x+3,194),pt(x+4,205)],ice)
    }
    facet([pt(26,187),pt(350,187),pt(347,198),pt(29,198)],
          color(0x8DBDCB).withAlphaComponent(0.56),outline:blue.withAlphaComponent(0.74))
    NSGradient(starting:ice.withAlphaComponent(0.55),ending:aqua.withAlphaComponent(0.32))?.draw(in:glass, angle:90)
    glass.lineWidth = 1; blue.withAlphaComponent(0.68).setStroke(); glass.stroke()
    stroke([pt(41,175),pt(165,175)],NSColor.white.withAlphaComponent(0.86))
    stroke([pt(31,190),pt(345,190)],ice,1.4)
    stroke([pt(40,195),pt(71,195)],ice.withAlphaComponent(0.76))
    stroke([pt(306,195),pt(337,195)],ice.withAlphaComponent(0.76))
    for x:CGFloat in [35,341] { dot(x,194,1.8,brass); dot(x-0.4,193.4,0.65,ivory) }
    if let lamp {
        dot(lamp,183,8,gold.withAlphaComponent(0.16))
        dot(lamp,183,4.5,brass); dot(lamp,182.5,3.0,ivory)
    }
}

func drawCrumpledPaper(at center:NSPoint, angle:CGFloat = 0) {
    NSGraphicsContext.saveGraphicsState()
    let t=NSAffineTransform()
    t.translateX(by:center.x,yBy:center.y); t.rotate(byDegrees:angle); t.concat()
    facet([pt(-9,-2),pt(-6,-7),pt(0,-9),pt(7,-5),pt(9,1),pt(5,7),pt(-2,8),pt(-8,5)],
          ivory,outline:color(0x827768))
    facet([pt(-8,3),pt(-3,0),pt(1,6),pt(6,3),pt(4,7),pt(-2,8)],color(0xD2C4A6))
    stroke([pt(-6,-5),pt(-2,-2),pt(1,-4),pt(6,-2)],brass)
    stroke([pt(-3,0),pt(0,-2),pt(2,2),pt(5,3)],color(0xA59885))
    NSGraphicsContext.restoreGraphicsState()
}

enum PaperGame {
    case between, cat, dragon, rolling

    func position(at beat:CGFloat, first:Companion, lift:CGFloat) -> NSPoint {
        let middle = pt(188,164), paw = pt(245,155), horn = pt(117,50)
        func arc(_ a:NSPoint,_ b:NSPoint,_ u:CGFloat,_ lift:CGFloat) -> NSPoint {
            let t = u*u*(3-2*u)
            return pt(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t-lift*sin(.pi*u))
        }
        switch self {
        case .rolling:
            return pt(188+24*sin(2 * .pi*beat)*sin(.pi*beat),164+5*sin(.pi*beat))
        case .cat, .dragon:
            let target = self == .cat ? paw : horn
            if beat < 0.5 { return arc(middle,target,beat*2,self == .cat ? 8 : 16) }
            return arc(target,middle,(beat-0.5)*2,self == .cat ? 24 : 48)
        case .between:
            let left = pt(130,164), right = pt(245,164)
            let from = first == .cat ? right : left
            let to = first == .cat ? left : right
            if beat < 0.25 { return arc(middle,from,beat/0.25,20) }
            let release:CGFloat = first == .cat ? 0.32 : 0.25
            if beat < release { return from }
            if beat < 0.72 { return arc(from,to,(beat-release)/(0.72-release),lift) }
            return arc(to,middle,(beat-0.72)/0.28,25)
        }
    }
}

func drawCrane(from source:CGFloat, to destination:CGFloat, progress:Double, reduce:Bool) {
    let u = CGFloat(min(1,progress / 0.9))
    let ease = u*u*(3-2*u)
    let x = reduce ? destination : source+(destination-source)*ease
    let y:CGFloat = reduce ? 125 : 129-54*sin(.pi*u)+5*sin(2 * .pi*u)
    let alpha = reduce ? min(1,progress/0.2) : 1
    NSGraphicsContext.saveGraphicsState()
    let t=NSAffineTransform()
    t.translateX(by:x,yBy:y); t.scaleX(by:destination > source ? 1 : -1, yBy:1); t.concat()
    let gc = NSGraphicsContext.current?.cgContext
    gc?.setAlpha(alpha * min(1,max(0,(2.4-progress)/0.25))); gc?.beginTransparencyLayer(auxiliaryInfo:nil)
    let wing:CGFloat = reduce || u >= 1 ? -17 : -16+4*sin(progress * 2 * .pi / 0.22)
    facet([pt(-21,-4),pt(-3,1),pt(3,8),pt(-8,5)],ice,outline:blue)
    facet([pt(-3,1),pt(-15,wing),pt(6,0),pt(2,8)],paper,outline:blue)
    facet([pt(-5,3),pt(7,1),pt(12,-10),pt(16,-8),pt(12,-6),pt(8,6),pt(1,9)],ivory,outline:blue)
    facet([pt(-6,3),pt(-3,wing-3),pt(5,1),pt(1,8)],ice,outline:blue)
    stroke([pt(-3,wing+1),pt(1,4),pt(7,3)],brass,1.1)
    gc?.endTransparencyLayer(); NSGraphicsContext.restoreGraphicsState()
}

enum DeskItem { case desktop, finder, paper }

final class DeskButton: NSButton {
    let item: DeskItem
    var paperAirborne = false { didSet { if oldValue != paperAirborne { needsDisplay = true } } }
    var usedAt:Double = -.infinity
    init(_ item:DeskItem, frame:NSRect, title:String, help:String, target:AnyObject, action:Selector) {
        self.item=item
        super.init(frame:frame)
        self.title=title; toolTip=help; setAccessibilityLabel(help)
        isBordered=false; self.target=target; self.action=action
    }
    required init?(coder:NSCoder) { fatalError("DeskButton requires a DeskItem") }
    override var isFlipped:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        let x=bounds.midX
        if item == .paper {
            if !paperAirborne { drawCrumpledPaper(at:pt(x,bounds.midY),angle:isHighlighted ? -12 : 0) }
            return
        }
        let dt = ProcessInfo.processInfo.systemUptime-usedAt
        let pulse:CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : sin(.pi*min(1,max(0,dt/0.32)))
        let y:CGFloat = isHighlighted ? 2 : 0
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by:x,yBy:y); transform.concat()
        if item == .desktop {
            for leg:CGFloat in [-13,11] {
                facet([pt(leg,11),pt(leg+3,11),pt(leg+2,20),pt(leg,21)],brass,outline:blue)
            }
            facet([pt(-18,7),pt(-10,2),pt(16,2),pt(19,7),pt(11,11),pt(-17,11)],ivory,outline:blue)
            facet([pt(-17,11),pt(12,11),pt(19,7),pt(19,10),pt(12,14),pt(-17,14)],gold,outline:blue)
            stroke([pt(-12,7),pt(-7,4),pt(4,4)],.white,1.4)
        } else {
            let shift = 3*pulse
            facet([pt(-16,6),pt(-10,2),pt(15,2),pt(17,6),pt(11,10),pt(-16,10)],ice,outline:blue)
            box(-16,6+shift,32,14,3,color(0x476E96))
            box(-15,6+shift,30,12,2,color(0x76BAEB))
            dot(-5,10+shift,1.1,ink); dot(5,10+shift,1.1,ink)
            stroke([pt(-4,13+shift),pt(-1,15+shift),pt(2,15+shift),pt(5,12+shift)],ink,1)
            stroke([pt(-12,8+shift),pt(-8,8+shift)],ice)
        }
        let w:CGFloat = item == .desktop ? 56 : 48
        box(-w/2,22,w,16,8,ink.withAlphaComponent(isHighlighted ? 1 : 0.89))
        label(title,-w/2,22,w,10.5, item == .desktop ? gold : ice,bold:true)
        NSGraphicsContext.restoreGraphicsState()
    }
}
