import Foundation

/// The GPU meter's one figure for the whole Mac.
///
/// macOS publishes a utilisation per GPU, not per Mac. With more than one —
/// an eGPU, or the integrated-plus-discrete pair of an older Mac — the figure
/// is the **busiest**, never the sum and never the average: two GPUs at 50%
/// are not a Mac at 100%, and an idle second GPU would halve a first one that
/// is pinned. The busiest answers the question the meter is for, which is
/// whether a GPU is what the Mac is waiting on.
///
/// **No figure is `nil`, never 0.** A virtual machine, or a driver that does
/// not publish the statistic, has a GPU the meter knows nothing about, and 0%
/// would say it is idle. The panel leaves the meter out instead.
public enum GPULoad {
    /// One figure from each GPU's own, in percent. Non-finite figures are no
    /// figure at all; the rest are held to 0–100.
    public static func busiest(of readings: [Double]) -> Double? {
        readings.lazy.filter(\.isFinite).map { min(100, max(0, $0)) }.max()
    }
}
