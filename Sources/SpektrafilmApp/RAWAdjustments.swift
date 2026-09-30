#if os(macOS)
import Foundation
struct RAWAdjustments: Equatable, Sendable {
    var exposureEV: Double = 0
    var temperature: Double = 6500
    var tint: Double = 0
    var lensCorrectionEnabled: Bool = true

    static let `default` = RAWAdjustments()
}
#endif
