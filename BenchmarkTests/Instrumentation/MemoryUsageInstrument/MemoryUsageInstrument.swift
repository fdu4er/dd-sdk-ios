/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

internal class MemoryUsageInstrument: Instrument {
    struct Measure {
        /// POSIX time in seconds (since 1/1/1970).
        var timestamp: TimeInterval
        /// Memory footprint in bytes.
        var footprint: Double
    }

    private var measures: [Measure] = []
    private var currentMeasureIndex = 0

    private let uploader: MetricUploader
    private let samplingInterval: TimeInterval
    private var timer: Timer!

    init(samplingInterval: TimeInterval, metricUploader: MetricUploader) {
        // Ref.: https://developer.apple.com/documentation/foundation/timer
        // > A general rule, set the tolerance to at least 10% of the interval, for a repeating timer.
        // > Even a small amount of tolerance has significant positive impact on the power usage of the application.
        let timerTolerance: Double = 0.1

        self.uploader = metricUploader
        self.samplingInterval = samplingInterval
        self.timer = Timer(timeInterval: samplingInterval, repeats: true) { [weak self] _ in self?.step() }
        self.timer.tolerance = samplingInterval * timerTolerance
    }

    private func step() {
        defer { currentMeasureIndex += 1 }
        guard currentMeasureIndex < measures.count else {
            return
        }

        if let value = currentMemoryFootprint() {
            measures[currentMeasureIndex].timestamp = Date().timeIntervalSince1970
            measures[currentMeasureIndex].footprint = value
        }
    }

    func beforeStart(scenario: BenchmarkScenario) {
        // To not skew measures by instrument allocations too much, pre-allocate most memory before it starts.
        let estimatedNumberOfSamples = Int(scenario.duration / samplingInterval)
        let now = Date()
        for i in (0..<estimatedNumberOfSamples) {
            // Pre-allocate each measure with distinct values to avoid skewing result due memory pages being significantly compressed.
            let any = Double(i)
            let measure = Measure(
                timestamp: now.addingTimeInterval(any).timeIntervalSince1970,
                footprint: any
            )
            measures.append(measure)
        }
    }

    func start() { RunLoop.main.add(timer, forMode: .common) }
    func stop() { timer.invalidate() }

    func afterStop(scenario: BenchmarkScenario, completion: @escaping (Bool) -> Void) {
        for (idx, measure) in measures.enumerated() {
            debug("Measure #\(idx): \(measure.footprint.prettyKB) -- \(Date(timeIntervalSince1970: measure.timestamp))")
        }

        uploader.send(
            metricPoints: measures.map { .init(timestamp: UInt64($0.timestamp), value: $0.footprint) },
            completion: completion
        )
    }
}
