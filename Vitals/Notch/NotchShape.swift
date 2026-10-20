//
//  NotchShape.swift
//  Vitals
//
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Via: https://github.com/TheBoredTeam/boring.notch
//
// The top corners curve *outward*, so the panel blends into the screen edge
// instead of sitting on it as a floating rectangle. The body is therefore
// inset by topCornerRadius on each side — see NotchView's frame maths.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let t = topCornerRadius, b = bottomCornerRadius
        // The flat top is the screen edge. An edge that lands on it
        // anti-aliases into a hairline of the menu bar across the notch, so
        // the close runs a point above the rect and the window clips it off.
        //
        // Each flare still starts on `minY`, where its tangent is horizontal,
        // so it leaves the bezel flat. Started up on `top` instead, it has
        // already dropped by the time it reaches the edge and meets it at an
        // angle — a visible kink. The overhang reaches each tip by a sliver
        // that keeps the same horizontal tangent and tapers outward, not by
        // a square: if the window lands a pixel low and that point shows, a
        // square's end draws as a 1px vertical line at both tips.
        let top = rect.minY - 1
        let taper: CGFloat = 6

        path.move(to: CGPoint(x: rect.minX - taper, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                          control: CGPoint(x: rect.minX - taper / 2, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                          control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                          control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                          control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + taper, y: top),
                          control: CGPoint(x: rect.maxX + taper / 2, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
