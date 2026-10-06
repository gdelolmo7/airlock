import XCTest
@testable import AirlockCore

/// The GPU meter's figure. The trace under it is `SystemTraceRecorder`, shared
/// with the CPU and covered by `SystemTraceTests`; what is the GPU's own is how
/// several GPUs become one figure, and that "no figure" never becomes 0%.
final class GPULoadTests: XCTestCase {

    func testTheBusiestGPUIsTheFigureNeverTheSum() {
        XCTAssertEqual(GPULoad.busiest(of: [29, 64]), 64)
        XCTAssertEqual(GPULoad.busiest(of: [50, 50]), 50)
        XCTAssertEqual(GPULoad.busiest(of: [0, 90]), 90)
    }

    /// A VM, or a driver that does not publish the statistic: the meter is left
    /// out, which is what `nil` tells the panel. 0% would say the GPU is idle.
    func testNoFigureIsUnavailableRatherThanZero() {
        XCTAssertNil(GPULoad.busiest(of: []))
        XCTAssertNil(GPULoad.busiest(of: [.nan]))
        XCTAssertNil(GPULoad.busiest(of: [.infinity, -.infinity]))
    }

    func testAnIdleGPUIsZeroAndNotUnavailable() {
        XCTAssertEqual(GPULoad.busiest(of: [0]), 0)
    }

    func testAFigureThatIsNotOneIsIgnoredAndTheRestAreHeldToTheScale() {
        XCTAssertEqual(GPULoad.busiest(of: [.nan, 12]), 12)
        XCTAssertEqual(GPULoad.busiest(of: [140]), 100)
        XCTAssertEqual(GPULoad.busiest(of: [-3]), 0)
    }

    /// The accessibility sentence is the CPU's with the GPU's name in it.
    func testTheGPUTraceIsSpokenLikeTheCPUs() {
        var recorder = SystemTraceRecorder()
        for value in [12.0, 64, 29] { recorder.record(value, spacing: SystemSampling.dormant) }
        XCTAssertEqual(recorder.trace.spoken(label: "GPU"), "GPU over the last 2 minutes, now 29%, peak 64%")
    }
}
