import Foundation

/// 人物の肩・腰が確認できる候補から、上半身が画像内に収まる大きな人物を選ぶ。
enum ThumbnailPersonComposition {
    struct Joint {
        let point: CGPoint
        let score: Double
    }
    struct Person {
        let bounds: CGRect
        let score: Double
        let joints: [Joint]
    }
    struct Framing {
        let focus: CGRect
        let protectedHead: CGRect
    }

    static func select(_ people: [Person], image: CGSize) -> Framing? {
        let imageRect = CGRect(origin: .zero, size: image)
        guard image.width > 0, image.height > 0 else { return nil }
        let candidates = people.compactMap { person -> (Framing, CGFloat, CGFloat)? in
            guard person.score >= 0.3, person.joints.count == 17,
                  person.bounds.width > 0, person.bounds.height > 0 else { return nil }
            let joints = person.joints
            // 鼻・両肩・両腰を条件にする。顔だけの候補や不確かな胴体を選ばない。
            let required = [0, 5, 6, 11, 12]
            guard required.allSatisfy({ joints[$0].score >= ($0 >= 11 ? 0.25 : 0.3)
                && imageRect.contains(joints[$0].point) }) else { return nil }
            let head = bounds(of: Array(joints[0...4].filter { $0.score >= 0.3 }.map(\.point)))
            let shoulders = bounds(of: [joints[5].point, joints[6].point])
            let hips = bounds(of: [joints[11].point, joints[12].point])
            guard head.width > 0, hips.midY > shoulders.midY, shoulders.midY > head.midY else { return nil }
            // 髪はモデルの検出対象ではない。顔の横幅と人物枠から頭頂側の余裕を見積もる。
            let top = min(person.bounds.minY, head.minY - head.width)
            let left = min(head.minX - head.width / 2, shoulders.minX)
            let right = max(head.maxX + head.width / 2, shoulders.maxX)
            let headBottom = head.maxY + head.width / 2
            let protected = CGRect(x: left, y: top, width: right - left,
                                   height: max(headBottom, shoulders.maxY) - top)
            let upperBody = protected.union(hips)
            let visible = upperBody.intersection(imageRect)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
            let completeness = visible.width * visible.height / (upperBody.width * upperBody.height)
            let framing = Framing(focus: normalized(visible, image: image),
                                  protectedHead: normalized(protected.intersection(imageRect), image: image))
            return (framing, completeness, person.bounds.width * person.bounds.height)
        }
        // 画面内に収まる割合を優先し、同じなら大きく描かれた人物を選ぶ。
        return candidates.enumerated().max { a, b in
            if a.element.1 != b.element.1 { return a.element.1 < b.element.1 }
            if a.element.2 != b.element.2 { return a.element.2 < b.element.2 }
            return a.offset > b.offset
        }?.element.0
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }

    private static func normalized(_ rect: CGRect, image: CGSize) -> CGRect {
        CGRect(x: rect.minX / image.width, y: rect.minY / image.height,
               width: rect.width / image.width, height: rect.height / image.height)
    }
}
