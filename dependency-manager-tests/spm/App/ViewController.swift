/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-Present Datadog, Inc.
*/

import UIKit
import Datadog
import DatadogLogs
import DatadogTrace
import DatadogRUM
import DatadogCrashReporting
#if os(iOS)
import DatadogSessionReplay
#endif

internal class ViewController: UIViewController {
    private var logger: DatadogLogger! // swiftlint:disable:this implicitly_unwrapped_optional

    override func viewDidLoad() {
        super.viewDidLoad()

        Datadog.initialize(
            appContext: .init(),
            trackingConsent: .granted,
            configuration: Datadog.Configuration
                .builderUsing(clientToken: "abc", environment: "tests")
                .build()
        )

        Logs.enable()

        DatadogCrashReporter.initialize()

        self.logger = DatadogLogger.builder
            .sendLogsToDatadog(false)
            .printLogsToConsole(true)
            .build()

        // RUM APIs must be visible:
        RUM.enable(with: .init(applicationID: "app-id"))
        RUMMonitor.shared().startView(viewController: self)

        // DDURLSessionDelegate APIs must be visible:
        _ = DDURLSessionDelegate()
        _ = DatadogURLSessionDelegate()
        class CustomDelegate: NSObject, __URLSessionDelegateProviding {
            var ddURLSessionDelegate: DatadogURLSessionDelegate { DatadogURLSessionDelegate() }
        }

        DatadogTracer.initialize()

        logger.info("It works")

        // Start span, but never finish it (no upload)
        _ = DatadogTracer.shared().startSpan(operationName: "This too")

        #if os(iOS)
        // Session Replay API must be visible:
        SessionReplay.enable(with: .init(replaySampleRate: 0))
        #endif

        addLabel()
    }

    private func addLabel() {
        let label = UILabel()
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)

        label.text = "Testing..."
        label.textColor = .white
        label.sizeToFit()
        label.center = view.center
    }
}
