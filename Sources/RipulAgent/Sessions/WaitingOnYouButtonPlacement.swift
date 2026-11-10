import Foundation

/// Store a fraction of the safe area, not screen pixels, so a moved question
/// button remains reachable after rotation or a window resize. Keyboard
/// avoidance is temporary and never changes the remembered position.
enum WaitingOnYouButtonPlacement {
    static let size: CGFloat = 64

    private static func origins(in safe: CGRect) -> CGRect {
        let horizontalMargin = min(12, max(0, (safe.width - size) / 2))
        let verticalMargin = min(8, max(0, (safe.height - size) / 2))
        return CGRect(x: safe.minX + horizontalMargin, y: safe.minY + verticalMargin,
                      width: max(0, safe.width - size - 2 * horizontalMargin),
                      height: max(0, safe.height - size - 2 * verticalMargin))
    }

    static func frame(position: CGPoint?, in safe: CGRect, keyboard: CGRect = .null, composers: [CGRect] = []) -> CGRect {
        let room = origins(in: safe)
        let origin = position.map {
            CGPoint(x: room.minX + min(max($0.x, 0), 1) * room.width,
                    y: room.minY + min(max($0.y, 0), 1) * room.height)
        } ?? CGPoint(x: room.maxX, y: safe.maxY - 96 - size)
        return frame(origin: origin, in: safe, keyboard: keyboard, composers: composers)
    }

    static func frame(origin: CGPoint, in safe: CGRect, keyboard: CGRect = .null, composers: [CGRect] = []) -> CGRect {
        guard safe.width >= size, safe.height >= size else { return .null }
        let room = origins(in: safe)
        let desired = CGPoint(x: min(max(origin.x, room.minX), room.maxX),
                              y: min(max(origin.y, room.minY), room.maxY))
        let obstacles = composers.filter { !$0.isNull && !$0.isEmpty }.map { $0.insetBy(dx: -8, dy: -8) }
            + (keyboard.isNull || keyboard.isEmpty ? [] : [keyboard.insetBy(dx: 0, dy: -16)])
        let proposed = CGRect(origin: desired, size: CGSize(width: size, height: size))
        guard obstacles.contains(where: { $0.intersects(proposed) }) else { return proposed }

        // The closest free place is beside an obstacle or at a safe-area edge.
        // Try both axes: a narrow/split chat may leave room alongside its composer.
        let xs = Set(([desired.x, room.minX, room.maxX] + obstacles.flatMap { [$0.minX - size, $0.maxX] })
            .map { min(max($0, room.minX), room.maxX) })
        let ys = Set(([desired.y, room.minY, room.maxY] + obstacles.flatMap { [$0.minY - size, $0.maxY] })
            .map { min(max($0, room.minY), room.maxY) })
        var best = CGRect.null
        var distance = CGFloat.infinity
        for y in ys.sorted() {
            for x in xs.sorted() {
                let candidate = CGRect(x: x, y: y, width: size, height: size)
                guard !obstacles.contains(where: { $0.intersects(candidate) }) else { continue }
                let squared = pow(x - desired.x, 2) + pow(y - desired.y, 2)
                if squared < distance { best = candidate; distance = squared }
            }
        }
        // A very tall composer can leave no room. Hide until space returns,
        // rather than cover its controls; the saved position is not changed.
        return best
    }

    static func position(of frame: CGRect, in safe: CGRect) -> CGPoint {
        let room = origins(in: safe)
        return CGPoint(x: room.width > 0 ? min(max((frame.minX - room.minX) / room.width, 0), 1) : 0,
                       y: room.height > 0 ? min(max((frame.minY - room.minY) / room.height, 0), 1) : 0)
    }
}
