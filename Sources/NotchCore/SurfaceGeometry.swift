import Foundation

public struct SurfaceSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// What a surface asks for. Heights describe content below the notch band; the engine adds the band.
/// Contracts are computed from data (row counts, states), never measured from rendered views, so the
/// window size can't feed back into SwiftUI layout.
public struct SizeContract: Equatable, Sendable {
    public var minimum: SurfaceSize
    public var preferred: SurfaceSize
    public var maximum: SurfaceSize
    public init(minimum: SurfaceSize, preferred: SurfaceSize, maximum: SurfaceSize) {
        self.minimum = minimum; self.preferred = preferred; self.maximum = maximum
    }
    /// A fixed-width contract whose height grows with content up to a ceiling.
    public static func content(width: Double, height: Double, minHeight: Double = 0, maxHeight: Double = 420) -> SizeContract {
        SizeContract(minimum: SurfaceSize(width: width, height: minHeight),
                     preferred: SurfaceSize(width: width, height: height),
                     maximum: SurfaceSize(width: width, height: maxHeight))
    }
}

/// Resolves a contract against the display: keeps room beside the notch for the band controls,
/// never covers most of the screen, snaps to whole points and ignores sub-threshold jitter.
public enum SurfaceGeometryEngine {
    public static let screenMargin = 16.0
    public static let bottomClearance = 70.0
    public static let jitter = 2.0

    public static func resolve(_ contract: SizeContract, display: DisplayGeometry, wing: Double,
                               previous: SurfaceSize? = nil) -> SurfaceSize {
        let band = display.notchHeight
        let widest = display.width - 2 * screenMargin
        let narrowest = min(widest, display.notchWidth + 2 * wing)
        // The screen edge always wins over a contract's minimum.
        let lower = min(max(contract.minimum.width, narrowest), widest)
        let width = clamp(contract.preferred.width, lower, min(contract.maximum.width, widest))
        let tallest = max(band, display.height - bottomClearance)
        let content = clamp(contract.preferred.height, contract.minimum.height, contract.maximum.height)
        var size = SurfaceSize(width: width.rounded(.up), height: min(tallest, band + content).rounded(.up))
        if let previous, abs(previous.width - size.width) < jitter, abs(previous.height - size.height) < jitter {
            size = previous
        }
        return size
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        upper < lower ? lower : min(max(value, lower), upper)
    }
}
