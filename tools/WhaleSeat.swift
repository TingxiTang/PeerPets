// Placement and movement of the DeepSeek guest in the existing glass desk.
import AppKit

struct WhaleWalk {
    private var from: CGFloat = 0
    private var target: CGFloat = 0
    private var began: TimeInterval = 0
    func progress(at time: TimeInterval) -> CGFloat {
        guard from != target else { return target }
        let duration = 0.82 * abs(target-from)
        let t = CGFloat(min(1, max(0, (time-began)/duration)))
        return from + (target-from)*t*t*(3-2*t)
    }
    mutating func faceDesk(_ front: Bool, at time: TimeInterval, reduce: Bool) {
        let next: CGFloat = front ? 1 : 0
        if reduce { target = next; from = next; return }
        if next != target {
            from = progress(at: time)
            began = time
            target = next
        }
    }
    func moving(at time: TimeInterval) -> Bool { progress(at: time) != target }
}

struct WhaleSprite {
    let image: NSImage
    let frame: NSRect
    let angle: CGFloat
    let opacity: CGFloat
    func contains(_ point: NSPoint) -> Bool {
        let transform = rotation()
        transform.invert()
        let p = transform.transform(point)
        let probe = NSRect(origin:p,size:NSSize(width:1,height:1))
        return frame.contains(p) && image.hitTest(probe,withDestinationRect:frame,context:nil,hints:nil,flipped:true)
    }
    private func rotation() -> NSAffineTransform {
        let t=NSAffineTransform()
        t.translateX(by:frame.midX,yBy:frame.maxY)
        t.rotate(byDegrees:angle)
        t.translateX(by:-frame.midX,yBy:-frame.maxY)
        return t
    }
    func draw() {
        NSGraphicsContext.saveGraphicsState()
        rotation().concat()
        image.draw(in:frame,from:.zero,operation:.sourceOver,fraction:opacity,respectFlipped:true,
                   hints:[.interpolation:NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}

func whaleSprite(art:[String:NSImage], depth:CGFloat, clock:Double, caught:Bool, reduce:Bool, landing:Double? = nil) -> WhaleSprite? {
    let atRear = depth < 0.035
    let traveling = depth >= 0.035 && depth < 0.94
    let pose = atRear ? "snack" : (traveling ? "step" : "work")
    guard let image=art["whale-"+pose], image.size.height>0 else { return nil }
    let stride = reduce ? 0 : abs(sin(depth * .pi * 2))
    let nibble = !reduce && atRear ? max(0, sin(clock*7)) * max(0,1-clock.truncatingRemainder(dividingBy:19)/1.1) : 0
    let height:CGFloat = 71 + 53*depth
    let scale = min(height/image.size.height, (79+32*depth)/image.size.width)
    let size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
    let x:CGFloat=184 + 7*depth + 19*sin(depth * .pi)
    let feet:CGFloat=113 + 65*depth - 4*stride + (caught && atRear && !reduce ? 3 : 0)
    let frame=NSRect(x:x-size.width/2,y:feet-size.height,width:size.width,height:size.height)
    let nod = landing.map { 3.5*sin(.pi*min(1,max(0,$0/0.55))) } ?? 0
    let angle = reduce ? 0 : (atRear ? 2.3*nibble : 3*sin(depth * .pi * 4) + nod)
    return WhaleSprite(image:image,frame:frame,angle:angle,opacity:0.83 + 0.17*depth)
}

// A narrow translucent desk lip masks the seated sprite and stays behind her as she approaches.
func drawWhaleSeat() {
    box(148,108,72,4,2,color(0xA7D0D5).withAlphaComponent(0.67))
    box(151,108,65,1,0.5,color(0xF4FCFA).withAlphaComponent(0.86))
    box(156,112,3,5,1,color(0x86AAB4).withAlphaComponent(0.44))
    box(210,112,3,5,1,color(0x86AAB4).withAlphaComponent(0.44))
}
