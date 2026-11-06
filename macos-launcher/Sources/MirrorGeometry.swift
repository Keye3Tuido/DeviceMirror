// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import CoreGraphics

enum MirrorGeometry {
    static func imageRect(in bounds: CGRect, size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    static func orientedSize(_ native: CGSize, image: CGSize) -> CGSize {
        (native.width > native.height) == (image.width > image.height)
            ? native : CGSize(width: native.height, height: native.width)
    }

}
