import XCTest
@testable import SpeechLogic

final class BenchmarkMathTests: XCTestCase {
    // MARK: - cpuBusyPercent

    func testCPUBusyPercentHalfBusy() {
        let prev = CPULoadSnapshot(user: 100, system: 100, idle: 800, nice: 0)
        let cur = CPULoadSnapshot(user: 300, system: 300, idle: 1400, nice: 0)
        // Δbusy 400 of Δtotal 1000 → 40 %.
        XCTAssertEqual(BenchmarkMath.cpuBusyPercent(previous: prev, current: cur)!, 40.0, accuracy: 0.0001)
    }

    func testCPUBusyPercentFullyBusy() {
        let prev = CPULoadSnapshot.zero
        let cur = CPULoadSnapshot(user: 500, system: 300, idle: 0, nice: 200)
        XCTAssertEqual(BenchmarkMath.cpuBusyPercent(previous: prev, current: cur)!, 100.0, accuracy: 0.0001)
    }

    func testCPUBusyPercentIdle() {
        let prev = CPULoadSnapshot(user: 10, system: 10, idle: 980, nice: 0)
        let cur = CPULoadSnapshot(user: 10, system: 10, idle: 1980, nice: 0)
        XCTAssertEqual(BenchmarkMath.cpuBusyPercent(previous: prev, current: cur)!, 0.0, accuracy: 0.0001)
    }

    func testCPUBusyPercentNoTicksIsNilNotZero() {
        // A suspended process sees no scheduling — the window carries zero
        // ticks, and recording 0 % would be a fabricated reading.
        let snapshot = CPULoadSnapshot(user: 42, system: 7, idle: 100, nice: 0)
        XCTAssertNil(BenchmarkMath.cpuBusyPercent(previous: snapshot, current: snapshot))
    }

    // MARK: - Percentiles / mean

    func testMean() {
        XCTAssertNil(BenchmarkMath.mean([]))
        XCTAssertEqual(BenchmarkMath.mean([1.0, 2.0, 3.0])!, 2.0, accuracy: 0.0001)
        XCTAssertEqual(BenchmarkMath.mean([0.5, 0.7])!, 0.6, accuracy: 0.0001)
    }

    func testMedianOddAndEven() {
        XCTAssertEqual(BenchmarkMath.median([3.0, 1.0, 2.0])!, 2.0, accuracy: 0.0001)
        XCTAssertEqual(BenchmarkMath.median([4.0, 1.0, 3.0, 2.0])!, 2.5, accuracy: 0.0001)
    }

    func testPercentileInterpolates() {
        let values = [10.0, 20.0, 30.0, 40.0]
        // p95 of 4 values: rank = 0.95 × 3 = 2.85 → 30 + 0.85 × 10 = 38.5.
        XCTAssertEqual(BenchmarkMath.percentile(values, 0.95)!, 38.5, accuracy: 0.0001)
        XCTAssertEqual(BenchmarkMath.percentile(values, 0.25)!, 17.5, accuracy: 0.0001)
        XCTAssertEqual(BenchmarkMath.percentile(values, 0)!, 10, accuracy: 0.0001)
        XCTAssertEqual(BenchmarkMath.percentile(values, 1)!, 40, accuracy: 0.0001)
        // Clamped out-of-range inputs.
        XCTAssertEqual(BenchmarkMath.percentile(values, 5)!, 40, accuracy: 0.0001)
        XCTAssertNil(BenchmarkMath.percentile([], 0.5))
    }

    func testPercentileSingleValue() {
        XCTAssertEqual(BenchmarkMath.percentile([7.0], 0.9)!, 7, accuracy: 0.0001)
    }

    // MARK: - CSV

    func testCSVRowPlainFields() {
        XCTAssertEqual(BenchmarkMath.csvRow(["1", "kokoro-fp32", "0.50"]), "1,kokoro-fp32,0.50")
    }

    func testCSVEscapingCommaQuoteNewline() {
        XCTAssertEqual(BenchmarkMath.csvEscaped("plain"), "plain")
        XCTAssertEqual(BenchmarkMath.csvEscaped("a,b"), "\"a,b\"")
        XCTAssertEqual(BenchmarkMath.csvEscaped("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(BenchmarkMath.csvEscaped("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(BenchmarkMath.csvEscaped(""), "")
        XCTAssertEqual(
            BenchmarkMath.csvRow(["1", "a,b", "c"]),
            "1,\"a,b\",c"
        )
    }
}
