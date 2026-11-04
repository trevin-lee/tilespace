// Snapping by dragging a window to a screen edge or corner, as pure geometry. Matches
// Rectangle: a 5pt band along each edge, and corners that reach 20pt further.
import CoreGraphics

public enum SnapEdge: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
}

// What each edge does. These are the snap areas set up in Rectangle before this app.
public let snapAreas: [SnapEdge: SnapAction] = [
    .left: .leftHalf, .right: .rightHalf, .top: .maximizeHeight,
    .topLeft: .firstFourth, .topRight: .lastThreeFourths,
    .bottomLeft: .firstThird, .bottom: .centerThird, .bottomRight: .lastThird,
]

let edgeMargin: CGFloat = 5, cornerSize: CGFloat = 20

// The edge or corner of `frame` (a whole display) that `p` is in, if any.
public func snapEdge(at p: CGPoint, in frame: CGRect) -> SnapEdge? {
    // the far edges count too (CGRect.contains leaves them out)
    guard p.x >= frame.minX, p.x <= frame.maxX, p.y >= frame.minY, p.y <= frame.maxY else { return nil }
    let corner = edgeMargin + cornerSize
    let nearLeft = p.x < frame.minX + corner, nearRight = p.x > frame.maxX - corner
    let nearTop = p.y < frame.minY + corner, nearBottom = p.y > frame.maxY - corner
    if nearLeft && nearTop { return .topLeft }
    if nearRight && nearTop { return .topRight }
    if nearLeft && nearBottom { return .bottomLeft }
    if nearRight && nearBottom { return .bottomRight }
    if p.x < frame.minX + edgeMargin { return .left }
    if p.x > frame.maxX - edgeMargin { return .right }
    if p.y < frame.minY + edgeMargin { return .top }
    if p.y > frame.maxY - edgeMargin { return .bottom }
    return nil
}

public struct DropTarget: Equatable {
    public let action: SnapAction
    public let rect: CGRect
}

// Where a window being dragged would snap with the cursor at `p`.
public func dropTarget(at p: CGPoint, window: CGRect, screens: [Screen]) -> DropTarget? {
    for s in screens {
        guard let edge = snapEdge(at: p, in: s.frame), let action = snapAreas[edge] else { continue }
        return DropTarget(action: action, rect: dropRect(action, window: window, on: s))
    }
    return nil
}

func dropRect(_ action: SnapAction, window: CGRect, on s: Screen) -> CGRect {
    let v = s.visible
    guard action == .maximizeHeight else { return placement(action, in: v) }
    // keep the window's column, moved onto this display if it hangs off it
    let w = min(window.width, v.width)
    return CGRect(x: max(v.minX, min(v.maxX - w, window.minX)), y: v.minY, width: w, height: v.height)
}

// Dragging a snapped window away gives it back its size from before the snap. Keep the
// cursor at the same fraction of the way across it, so it stays on the title bar.
public func unsnapFrame(_ current: CGRect, size: CGSize, cursor: CGPoint) -> CGRect {
    let fraction = current.width > 0 ? (cursor.x - current.minX) / current.width : 0.5
    return CGRect(x: (cursor.x - fraction * size.width).rounded(), y: current.minY, width: size.width, height: size.height)
}
