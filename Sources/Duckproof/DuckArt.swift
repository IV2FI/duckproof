import AppKit

/// The "muted" duck, used for the menu bar icon and the app icon.
/// Everything is drawn in a 100 × 100 square (origin bottom-left), duck facing left.
enum DuckArt {
    private static func body() -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: 16, y: 16, width: 72, height: 42))
        path.append(NSBezierPath(ovalIn: NSRect(x: 15, y: 47, width: 38, height: 38)))   // head
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 66, y: 54))
        tail.curve(to: NSPoint(x: 97, y: 66), controlPoint1: NSPoint(x: 80, y: 56), controlPoint2: NSPoint(x: 92, y: 58))
        tail.curve(to: NSPoint(x: 84, y: 30), controlPoint1: NSPoint(x: 99, y: 52), controlPoint2: NSPoint(x: 94, y: 38))
        tail.close()
        path.append(tail.reversed)   // same winding as the ovals, or the overlap becomes a hole
        return path
    }

    private static func beak() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 22, y: 72))
        path.curve(to: NSPoint(x: 2, y: 62), controlPoint1: NSPoint(x: 12, y: 71), controlPoint2: NSPoint(x: 4, y: 66))
        path.curve(to: NSPoint(x: 22, y: 58), controlPoint1: NSPoint(x: 8, y: 58), controlPoint2: NSPoint(x: 16, y: 57))
        path.close()
        return path
    }

    private static func eye() -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: 29, y: 67, width: 8, height: 8)) }

    private static func wing() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 44, y: 44))
        path.curve(to: NSPoint(x: 76, y: 40), controlPoint1: NSPoint(x: 54, y: 30), controlPoint2: NSPoint(x: 70, y: 30))
        path.curve(to: NSPoint(x: 44, y: 44), controlPoint1: NSPoint(x: 66, y: 48), controlPoint2: NSPoint(x: 54, y: 48))
        path.close()
        return path
    }

    private static func slash(width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 10, y: 92)); path.line(to: NSPoint(x: 92, y: 10))
        path.lineWidth = width
        path.lineCapStyle = .round
        return path
    }

    /// Menu bar icon (template image, adapts to light/dark mode).
    /// `active`: fully visible duck during a call, dimmed otherwise.
    static func menuBarImage(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: 1, yBy: 0)
            transform.scale(by: 0.18)
            transform.concat()

            NSColor.black.withAlphaComponent(active ? 1 : 0.55).setFill()
            let duck = body()
            duck.append(beak())
            duck.windingRule = .nonZero
            duck.fill()

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            eye().fill()
            slash(width: 20).stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash(width: 8).stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// App icon on the macOS grid (content within 824/1024 of the square).
    static func appIcon(pixels: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
            let unit = rect.width / 1024
            let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
            let background = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)
            NSGradient(starting: NSColor(red: 0.27, green: 0.62, blue: 0.96, alpha: 1),
                       ending: NSColor(red: 0.10, green: 0.33, blue: 0.72, alpha: 1))?.draw(in: background, angle: -90)

            // The duck is drawn into its own image so the slash gap can be cut out of it.
            let duckSize = 620 * unit
            let duckImage = NSImage(size: NSSize(width: duckSize, height: duckSize), flipped: false) { _ in
                let transform = NSAffineTransform()
                transform.scale(by: duckSize / 100)
                transform.concat()
                NSColor(red: 1.0, green: 0.82, blue: 0.20, alpha: 1).setFill(); body().fill()
                NSColor(red: 1.0, green: 0.70, blue: 0.10, alpha: 1).setFill(); wing().fill()
                NSColor(red: 1.0, green: 0.52, blue: 0.12, alpha: 1).setFill(); beak().fill()
                NSColor(white: 0.12, alpha: 1).setFill(); eye().fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                slash(width: 17).stroke()
                return true
            }
            let origin = NSPoint(x: (rect.width - duckSize) / 2, y: (rect.height - duckSize) / 2 - 10 * unit)
            duckImage.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

            let transform = NSAffineTransform()
            transform.translateX(by: origin.x, yBy: origin.y)
            transform.scale(by: duckSize / 100)
            transform.concat()
            NSColor.white.setStroke()
            slash(width: 7).stroke()
            return true
        }
    }
}
