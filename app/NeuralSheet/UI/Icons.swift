import CoreGraphics
import SwiftUI

/// The UI's icons, as `Shape`s built in code rather than SVGs.
///
/// The design tints the same icon differently in almost every state, and an SVG bakes its colours
/// in, so each state would need its own file. A `Shape` is filled or stroked in whatever colour the
/// caller is already holding.
///
/// Every icon is drawn in the same 16 x 16 design square and that whole square is mapped onto the
/// rect, rather than fitting each path to its own extents. That is the difference between a set of
/// icons that share a weight and a set where the one with the least ink is drawn the largest -- and
/// it lets two paths meant to overlap still overlap (`loopStroked` + `loopHead`,
/// `followPlayheadStroked` + `followPlayheadFlag`).
enum Icons {
    /// The width every "...Stroked" icon is drawn with, so they all read as one weight. Multiply by
    /// the UI scale at the call site.
    static let strokeWidth: CGFloat = 1.3

    /// The stroke every "...Stroked" icon uses: curved joints, rounded caps.
    static func strokeStyle(scale: CGFloat = 1) -> StrokeStyle {
        StrokeStyle(lineWidth: strokeWidth * scale, lineCap: .round, lineJoin: .round)
    }

    // MARK: - Transport

    nonisolated struct SkipToStart: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addRoundedRect(2.5, 3.0, 1.8, 10.0, 0.9)
            p.addTriangle(13.5, 3.0, 13.5, 13.0, 5.5, 8.0)

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct Play: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addTriangle(4.0, 2.5, 4.0, 13.5, 13.0, 8.0)

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct Pause: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addRoundedRect(4.0, 2.0, 3.0, 12.0, 1.2)
            p.addRoundedRect(10.0, 2.0, 3.0, 12.0, 1.2)

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct Record: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addEllipse(in: CGRect(x: 3.0, y: 3.0, width: 10.0, height: 10.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The stadium outline. Stroke it, then fill `LoopHead` over the top.
    nonisolated struct LoopStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addRoundedRect(1.5, 4.0, 13.0, 8.0, 4.0)

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The play head sitting inside the loop outline. Filled.
    nonisolated struct LoopHead: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addTriangle(6.6, 5.4, 6.6, 10.6, 10.6, 8.0)

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The brackets and the playhead's stem. Stroke it, then fill `FollowPlayheadFlag` over the top.
    nonisolated struct FollowPlayheadStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            // Left bracket.
            p.move(to: CGPoint(x: 3.4, y: 3.0))
            p.addLine(to: CGPoint(x: 1.6, y: 3.0))
            p.addLine(to: CGPoint(x: 1.6, y: 13.0))
            p.addLine(to: CGPoint(x: 3.4, y: 13.0))

            // Right bracket.
            p.move(to: CGPoint(x: 12.6, y: 3.0))
            p.addLine(to: CGPoint(x: 14.4, y: 3.0))
            p.addLine(to: CGPoint(x: 14.4, y: 13.0))
            p.addLine(to: CGPoint(x: 12.6, y: 13.0))

            // The playhead's stem. Its flag is FollowPlayheadFlag, filled over the top.
            p.move(to: CGPoint(x: 8.0, y: 6.7))
            p.addLine(to: CGPoint(x: 8.0, y: 13.2))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The playhead's flag, a miniature of the timeline marker: it tapers to a point where the stem
    /// meets it. Filled.
    nonisolated struct FollowPlayheadFlag: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 5.4, y: 3.4))
            p.addLine(to: CGPoint(x: 10.6, y: 3.4))
            p.addLine(to: CGPoint(x: 10.6, y: 5.2))
            p.addLine(to: CGPoint(x: 8.0, y: 6.7))
            p.addLine(to: CGPoint(x: 5.4, y: 5.2))
            p.closeSubpath()

            return IconGeometry.fitted(p, in: rect)
        }
    }

    // MARK: - Top bar

    nonisolated struct Speaker: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            // Cone: the back block plus the flare, as one filled shape.
            p.move(to: CGPoint(x: 1.5, y: 6.0))
            p.addLine(to: CGPoint(x: 4.5, y: 6.0))
            p.addLine(to: CGPoint(x: 8.0, y: 2.5))
            p.addLine(to: CGPoint(x: 8.0, y: 13.5))
            p.addLine(to: CGPoint(x: 4.5, y: 10.0))
            p.addLine(to: CGPoint(x: 1.5, y: 10.0))
            p.closeSubpath()

            // One wave, thick enough to survive at 13 px.
            p.addCentredArc(cx: 8.6, cy: 8.0, rx: 3.0, ry: 3.0, from: 0.6, to: 2.55, startNewSubpath: true)
            p.addCentredArc(cx: 8.6, cy: 8.0, rx: 4.1, ry: 4.1, from: 2.55, to: 0.6, startNewSubpath: false)
            p.closeSubpath()

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// Speaker with a cross. The cross is part of the same path, so one fill draws both.
    nonisolated struct SpeakerMuted: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            p.move(to: CGPoint(x: 1.0, y: 6.0))
            p.addLine(to: CGPoint(x: 4.0, y: 6.0))
            p.addLine(to: CGPoint(x: 7.5, y: 2.5))
            p.addLine(to: CGPoint(x: 7.5, y: 13.5))
            p.addLine(to: CGPoint(x: 4.0, y: 10.0))
            p.addLine(to: CGPoint(x: 1.0, y: 10.0))
            p.closeSubpath()

            // The cross, as two filled bars so it reads at the same weight as the cone.
            let bar: CGFloat = 1.3
            var cross = Path()
            cross.addRect(CGRect(x: -3.1, y: -bar / 2.0, width: 6.2, height: bar))
            cross.addRect(CGRect(x: -bar / 2.0, y: -3.1, width: bar, height: 6.2))

            let placed = CGAffineTransform(rotationAngle: .pi / 4.0)
                .concatenating(CGAffineTransform(translationX: 11.8, y: 8.0))
            p.addPath(cross, transform: placed)

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// Three horizontal rails with offset handles, so they read as faders rather than a hamburger.
    nonisolated struct SettingsStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            let rows: [CGFloat] = [4.0, 8.0, 12.0]
            let handles: [CGFloat] = [10.5, 5.5, 9.0]

            for i in 0 ..< 3 {
                p.move(to: CGPoint(x: 1.5, y: rows[i]))
                p.addLine(to: CGPoint(x: 14.5, y: rows[i]))
                p.move(to: CGPoint(x: handles[i], y: rows[i] - 2.0))
                p.addLine(to: CGPoint(x: handles[i], y: rows[i] + 2.0))
            }

            return IconGeometry.fitted(p, in: rect)
        }
    }

    // MARK: - Toolbar

    nonisolated struct FolderStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            p.move(to: CGPoint(x: 1.5, y: 12.5))
            p.addLine(to: CGPoint(x: 1.5, y: 4.0))
            p.addLine(to: CGPoint(x: 6.0, y: 4.0))
            p.addLine(to: CGPoint(x: 7.5, y: 5.8))
            p.addLine(to: CGPoint(x: 14.5, y: 5.8))
            p.addLine(to: CGPoint(x: 14.5, y: 12.5))
            p.closeSubpath()

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// Down arrow onto a baseline.
    nonisolated struct DownloadStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            p.move(to: CGPoint(x: 8.0, y: 2.0))
            p.addLine(to: CGPoint(x: 8.0, y: 10.0))
            p.move(to: CGPoint(x: 4.6, y: 6.8))
            p.addLine(to: CGPoint(x: 8.0, y: 10.2))
            p.addLine(to: CGPoint(x: 11.4, y: 6.8))
            p.move(to: CGPoint(x: 2.5, y: 13.5))
            p.addLine(to: CGPoint(x: 13.5, y: 13.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct TrashStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()

            p.move(to: CGPoint(x: 2.0, y: 4.2))
            p.addLine(to: CGPoint(x: 14.0, y: 4.2))

            p.move(to: CGPoint(x: 6.2, y: 4.2))
            p.addLine(to: CGPoint(x: 6.2, y: 2.2))
            p.addLine(to: CGPoint(x: 9.8, y: 2.2))
            p.addLine(to: CGPoint(x: 9.8, y: 4.2))

            p.move(to: CGPoint(x: 3.4, y: 4.2))
            p.addLine(to: CGPoint(x: 4.2, y: 13.8))
            p.addLine(to: CGPoint(x: 11.8, y: 13.8))
            p.addLine(to: CGPoint(x: 12.6, y: 4.2))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    // MARK: - Glyphs

    /// Built straight from the rect rather than through the design square: the triangles are the
    /// only icons the design gives a non-square size (7 x 4), and a uniform fit would shrink them to
    /// the shorter side.
    nonisolated struct TriangleUp: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.closeSubpath()

            return p
        }
    }

    nonisolated struct TriangleDown: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()

            return p
        }
    }

    nonisolated struct PlusStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 8.0, y: 2.5))
            p.addLine(to: CGPoint(x: 8.0, y: 13.5))
            p.move(to: CGPoint(x: 2.5, y: 8.0))
            p.addLine(to: CGPoint(x: 13.5, y: 8.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The cancel cross.
    nonisolated struct CrossStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 3.2, y: 3.2))
            p.addLine(to: CGPoint(x: 12.8, y: 12.8))
            p.move(to: CGPoint(x: 12.8, y: 3.2))
            p.addLine(to: CGPoint(x: 3.2, y: 12.8))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// A tick, drawn on the accent fill of a ticked checkbox. Stroked at 2 px by its caller.
    nonisolated struct CheckStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 3.2, y: 8.4))
            p.addLine(to: CGPoint(x: 6.3, y: 11.5))
            p.addLine(to: CGPoint(x: 12.8, y: 4.8))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// Five bars around the centre line, tallest in the middle: a level meter reading as pitches.
    nonisolated struct TranscribeStroked: Shape {
        private static let halfHeights: [CGFloat] = [2.4, 4.4, 5.4, 3.4, 1.4]

        func path(in rect: CGRect) -> Path {
            var p = Path()

            for i in 0 ..< 5 {
                let x = 2.0 + 3.0 * CGFloat(i)

                p.move(to: CGPoint(x: x, y: 8.0 - Self.halfHeights[i]))
                p.addLine(to: CGPoint(x: x, y: 8.0 + Self.halfHeights[i]))
            }

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// A vertical double-headed arrow.
    nonisolated struct VerticalZoomStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 8.0, y: 2.4))
            p.addLine(to: CGPoint(x: 8.0, y: 13.6))

            p.move(to: CGPoint(x: 5.4, y: 5.0))
            p.addLine(to: CGPoint(x: 8.0, y: 2.4))
            p.addLine(to: CGPoint(x: 10.6, y: 5.0))

            p.move(to: CGPoint(x: 5.4, y: 11.0))
            p.addLine(to: CGPoint(x: 8.0, y: 13.6))
            p.addLine(to: CGPoint(x: 10.6, y: 11.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    // MARK: - Editor

    /// The Select tool's pointer arrow.
    nonisolated struct ArrowStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 4.0, y: 2.5))
            p.addLine(to: CGPoint(x: 4.0, y: 13.0))
            p.addLine(to: CGPoint(x: 7.0, y: 10.2))
            p.addLine(to: CGPoint(x: 9.2, y: 14.0))
            p.addLine(to: CGPoint(x: 11.0, y: 13.1))
            p.addLine(to: CGPoint(x: 8.9, y: 9.4))
            p.addLine(to: CGPoint(x: 12.5, y: 9.2))
            p.closeSubpath()

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The Draw tool: a pencil with its ferrule line.
    nonisolated struct PencilStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 3.0, y: 13.0))
            p.addLine(to: CGPoint(x: 3.6, y: 10.2))
            p.addLine(to: CGPoint(x: 10.8, y: 3.0))
            p.addLine(to: CGPoint(x: 13.0, y: 5.2))
            p.addLine(to: CGPoint(x: 5.8, y: 12.4))
            p.closeSubpath()
            p.move(to: CGPoint(x: 9.2, y: 4.6))
            p.addLine(to: CGPoint(x: 11.4, y: 6.8))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// The Erase tool: a tilted block with its rubbing edge and the baseline it sits on.
    nonisolated struct EraserStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 6.0, y: 13.0))
            p.addLine(to: CGPoint(x: 2.8, y: 9.8))
            p.addLine(to: CGPoint(x: 9.6, y: 3.0))
            p.addLine(to: CGPoint(x: 13.2, y: 6.6))
            p.addLine(to: CGPoint(x: 6.8, y: 13.0))
            p.closeSubpath()
            p.move(to: CGPoint(x: 5.6, y: 7.0))
            p.addLine(to: CGPoint(x: 9.2, y: 10.6))
            p.move(to: CGPoint(x: 7.5, y: 13.0))
            p.addLine(to: CGPoint(x: 13.5, y: 13.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// Snap to grid: a horseshoe magnet with its two pole caps.
    nonisolated struct MagnetStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 4.0, y: 3.0))
            p.addLine(to: CGPoint(x: 4.0, y: 9.0))
            p.addArc(center: CGPoint(x: 8.0, y: 9.0), radius: 4.0, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: 12.0, y: 3.0))
            p.move(to: CGPoint(x: 2.5, y: 5.5))
            p.addLine(to: CGPoint(x: 5.5, y: 5.5))
            p.move(to: CGPoint(x: 10.5, y: 5.5))
            p.addLine(to: CGPoint(x: 13.5, y: 5.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// A curled arrow back to the left; `RedoStroked` is its mirror.
    nonisolated struct UndoStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 6.0, y: 3.5))
            p.addLine(to: CGPoint(x: 3.0, y: 6.5))
            p.addLine(to: CGPoint(x: 6.0, y: 9.5))
            p.move(to: CGPoint(x: 3.0, y: 6.5))
            p.addLine(to: CGPoint(x: 10.0, y: 6.5))
            p.addArc(center: CGPoint(x: 10.0, y: 9.5), radius: 3.0, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: 6.5, y: 12.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct RedoStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 10.0, y: 3.5))
            p.addLine(to: CGPoint(x: 13.0, y: 6.5))
            p.addLine(to: CGPoint(x: 10.0, y: 9.5))
            p.move(to: CGPoint(x: 13.0, y: 6.5))
            p.addLine(to: CGPoint(x: 6.0, y: 6.5))
            p.addArc(center: CGPoint(x: 6.0, y: 9.5), radius: 3.0, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: 9.5, y: 12.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    /// A ring with four ticks: "set the downbeat from the playhead".
    nonisolated struct PlayheadTargetStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addEllipse(in: CGRect(x: 4.5, y: 4.5, width: 7.0, height: 7.0))
            p.move(to: CGPoint(x: 8.0, y: 1.5))
            p.addLine(to: CGPoint(x: 8.0, y: 4.5))
            p.move(to: CGPoint(x: 8.0, y: 11.5))
            p.addLine(to: CGPoint(x: 8.0, y: 14.5))
            p.move(to: CGPoint(x: 1.5, y: 8.0))
            p.addLine(to: CGPoint(x: 4.5, y: 8.0))
            p.move(to: CGPoint(x: 11.5, y: 8.0))
            p.addLine(to: CGPoint(x: 14.5, y: 8.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }
}

/// The square every icon above is authored in, and the mapping onto the rect it is drawn into.
nonisolated enum IconGeometry {
    /// Every icon is drawn in this square, so the numbers in `Icons` can be read straight off the
    /// mockup's proportions instead of against a live size.
    static let designSize: CGFloat = 16

    /// Maps the whole design square onto the rect, centred, preserving the aspect ratio.
    static func fitted(_ path: Path, in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / designSize
        let side = designSize * scale

        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - side / 2.0,
                                             y: rect.midY - side / 2.0))

        return path.applying(transform)
    }
}

private extension Path {
    /// `juce::Path::addRoundedRectangle`, in design-square units.
    nonisolated mutating func addRoundedRect(_ x: CGFloat,
                                 _ y: CGFloat,
                                 _ width: CGFloat,
                                 _ height: CGFloat,
                                 _ corner: CGFloat) {
        addRoundedRect(in: CGRect(x: x, y: y, width: width, height: height),
                       cornerSize: CGSize(width: corner, height: corner),
                       style: .circular)
    }

    /// `juce::Path::addTriangle`, in design-square units.
    nonisolated mutating func addTriangle(_ x1: CGFloat,
                              _ y1: CGFloat,
                              _ x2: CGFloat,
                              _ y2: CGFloat,
                              _ x3: CGFloat,
                              _ y3: CGFloat) {
        move(to: CGPoint(x: x1, y: y1))
        addLine(to: CGPoint(x: x2, y: y2))
        addLine(to: CGPoint(x: x3, y: y3))
        closeSubpath()
    }

    /// `juce::Path::addCentredArc` with no ellipse rotation, stepped at JUCE's own angular
    /// increment so the polyline matches. Angle 0 is straight up and grows clockwise on screen,
    /// which is not what Core Graphics' arc APIs mean by an angle -- hence the explicit points.
    nonisolated mutating func addCentredArc(cx: CGFloat,
                                cy: CGFloat,
                                rx: CGFloat,
                                ry: CGFloat,
                                from: CGFloat,
                                to end: CGFloat,
                                startNewSubpath: Bool) {
        let increment: CGFloat = 0.05

        func point(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * sin(angle), y: cy - ry * cos(angle))
        }

        var angle = from

        if startNewSubpath {
            move(to: point(angle))
        }

        if from < end {
            if startNewSubpath {
                angle += increment
            } else {
                addLine(to: point(angle))
            }

            while angle < end {
                addLine(to: point(angle))
                angle += increment
            }
        } else {
            if startNewSubpath {
                angle -= increment
            } else {
                addLine(to: point(angle))
            }

            while angle > end {
                addLine(to: point(angle))
                angle -= increment
            }
        }

        addLine(to: point(end))
    }
}
