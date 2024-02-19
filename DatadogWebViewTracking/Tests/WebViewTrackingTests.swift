/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if !os(tvOS)

import XCTest
import WebKit
import TestUtilities
import DatadogInternal
@testable import DatadogWebViewTracking

final class DDUserContentController: WKUserContentController {
    typealias NameHandlerPair = (name: String, handler: WKScriptMessageHandler)
    private(set) var messageHandlers = [NameHandlerPair]()

    override func add(_ scriptMessageHandler: WKScriptMessageHandler, name: String) {
        messageHandlers.append((name: name, handler: scriptMessageHandler))
    }

    override func removeScriptMessageHandler(forName name: String) {
        messageHandlers = messageHandlers.filter {
            return $0.name != name
        }
    }
}

final class MockMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { }
}

final class MockScriptMessage: WKScriptMessage {
    let mockBody: Any

    init(body: Any) {
        self.mockBody = body
    }

    override var body: Any { return mockBody }
}

class WebViewTrackingTests: XCTestCase {
    func testItAddsUserScriptAndMessageHandler() throws {
        let mockSanitizer = HostsSanitizerMock()
        let controller = DDUserContentController()

        let initialUserScriptCount = controller.userScripts.count

        WebViewTracking.enable(
            tracking: controller,
            hosts: ["datadoghq.com"],
            hostsSanitizer: mockSanitizer,
            logsSampleRate: 30,
            in: PassthroughCoreMock()
        )

        XCTAssertEqual(controller.userScripts.count, initialUserScriptCount + 1)
        XCTAssertEqual(controller.messageHandlers.map({ $0.name }), ["DatadogEventBridge"])

        let messageHandler = try XCTUnwrap(controller.messageHandlers.first?.handler) as? DDScriptMessageHandler
        XCTAssertEqual(messageHandler?.emitter.logsSampler.samplingRate, 30)

        XCTAssertEqual(mockSanitizer.sanitizations.count, 1)
        let sanitization = try XCTUnwrap(mockSanitizer.sanitizations.first)
        XCTAssertEqual(sanitization.hosts, ["datadoghq.com"])
        XCTAssertEqual(sanitization.warningMessage, "The allowed WebView host configured for Datadog SDK is not valid")
    }

    func testWhenAddingMessageHandlerMultipleTimes_itIgnoresExtraOnesAndPrintsWarning() throws {
        let dd = DD.mockWith(logger: CoreLoggerMock())
        defer { dd.reset() }

        let mockSanitizer = HostsSanitizerMock()
        let controller = DDUserContentController()

        let initialUserScriptCount = controller.userScripts.count

        let multipleTimes = 5
        (0..<multipleTimes).forEach { _ in
            WebViewTracking.enable(
                tracking: controller,
                hosts: ["datadoghq.com"],
                hostsSanitizer: mockSanitizer,
                logsSampleRate: 100,
                in: PassthroughCoreMock()
            )
        }

        XCTAssertEqual(controller.userScripts.count, initialUserScriptCount + 1)
        XCTAssertEqual(controller.messageHandlers.map({ $0.name }), ["DatadogEventBridge"])

        XCTAssertGreaterThanOrEqual(mockSanitizer.sanitizations.count, 1)
        let sanitization = try XCTUnwrap(mockSanitizer.sanitizations.first)
        XCTAssertEqual(sanitization.hosts, ["datadoghq.com"])
        XCTAssertEqual(sanitization.warningMessage, "The allowed WebView host configured for Datadog SDK is not valid")

        XCTAssertEqual(
            dd.logger.warnLogs.map({ $0.message }),
            Array(repeating: "`startTrackingDatadogEvents(core:hosts:)` was called more than once for the same WebView. Second call will be ignored. Make sure you call it only once.", count: multipleTimes - 1)
        )
    }

    func testWhenStoppingTracking_itKeepsNonDatadogComponents() throws {
        let core = PassthroughCoreMock()
        let controller = DDUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webview = WKWebView(frame: .zero, configuration: configuration)

        WebViewTracking.enable(
            webView: webview,
            in: core
        )

        let componentCount = 10
        for i in 0..<componentCount {
            let userScript = WKUserScript(
                source: String.mockRandom(),
                injectionTime: (i % 2 == 0 ? .atDocumentStart : .atDocumentEnd),
                forMainFrameOnly: i % 2 == 0
            )
            controller.addUserScript(userScript)
            controller.add(MockMessageHandler(), name: String.mockRandom())
        }

        XCTAssertEqual(controller.userScripts.count, componentCount + 1)
        XCTAssertEqual(controller.messageHandlers.count, componentCount + 1)

        WebViewTracking.disable(webView: webview)

        XCTAssertEqual(controller.userScripts.count, componentCount)
        XCTAssertEqual(controller.messageHandlers.count, componentCount)
    }

    func testSendingWebEvents() throws {
        let logMessageExpectation = expectation(description: "Log message received")
        let core = PassthroughCoreMock(
            messageReceiver: FeatureMessageReceiverMock { message in
                switch message.value(WebViewMessage.self) {
                case let .log(event):
                    XCTAssertEqual(event["date"] as? Int, 1_635_932_927_012)
                    XCTAssertEqual(event["message"] as? String, "console error: error")
                    XCTAssertEqual(event["status"] as? String, "error")
                    XCTAssertEqual(event["view"] as? [String: String], ["referrer": "", "url": "https://datadoghq.dev/browser-sdk-test-playground"])
                    XCTAssertEqual(event["error"] as? [String: String], ["origin": "console"])
                    XCTAssertEqual(event["session_id"] as? String, "0110cab4-7471-480e-aa4e-7ce039ced355")
                    logMessageExpectation.fulfill()
                case .none:
                    break
                default:
                    XCTFail("Unexpected webview message received: \(message)")
                }
            }
        )

        let controller = DDUserContentController()
        WebViewTracking.enable(
            tracking: controller,
            hosts: ["datadoghq.com"],
            hostsSanitizer: HostsSanitizerMock(),
            logsSampleRate: 100,
            in: core
        )

        let messageHandler = try XCTUnwrap(controller.messageHandlers.first?.handler) as? DDScriptMessageHandler
        let webLogMessage = MockScriptMessage(body: """
        {
          "eventType": "log",
          "event": {
            "date": 1635932927012,
            "error": {
              "origin": "console"
            },
            "message": "console error: error",
            "session_id": "0110cab4-7471-480e-aa4e-7ce039ced355",
            "status": "error",
            "view": {
              "referrer": "",
              "url": "https://datadoghq.dev/browser-sdk-test-playground"
            }
          },
          "tags": [
            "browser_sdk_version:3.6.13"
          ]
        }
        """)
        messageHandler?.userContentController(controller, didReceive: webLogMessage)
        waitForExpectations(timeout: 1)
    }

    func testSendingWebRUMEvent() throws {
        let rumMessageExpectation = expectation(description: "RUM message received")
        let core = PassthroughCoreMock(
            messageReceiver: FeatureMessageReceiverMock { message in
                switch message.value(WebViewMessage.self) {
                case let .rum(event):
                    XCTAssertEqual((event["view"] as? [String: Any])?["id"] as? String, "64308fd4-83f9-48cb-b3e1-1e91f6721230")
                    rumMessageExpectation.fulfill()
                case .none:
                    break
                default:
                    XCTFail("Unexpected webview message received: \(message)")
                }
            }
        )

        let controller = DDUserContentController()
        WebViewTracking.enable(
            tracking: controller,
            hosts: ["datadoghq.com"],
            hostsSanitizer: HostsSanitizerMock(),
            logsSampleRate: 100,
            in: core
        )

        let messageHandler = try XCTUnwrap(controller.messageHandlers.first?.handler) as? DDScriptMessageHandler
        let webRUMMessage = MockScriptMessage(body: """
        {
          "eventType": "view",
          "event": {
            "application": {
              "id": "xxx"
            },
            "date": 1635933113708,
            "service": "super",
            "session": {
              "id": "0110cab4-7471-480e-aa4e-7ce039ced355",
              "type": "user"
            },
            "type": "view",
            "view": {
              "action": {
                "count": 0
              },
              "cumulative_layout_shift": 0,
              "dom_complete": 152800000,
              "dom_content_loaded": 118300000,
              "dom_interactive": 116400000,
              "error": {
                "count": 0
              },
              "first_contentful_paint": 121300000,
              "id": "64308fd4-83f9-48cb-b3e1-1e91f6721230",
              "in_foreground_periods": [],
              "is_active": true,
              "largest_contentful_paint": 121299000,
              "load_event": 152800000,
              "loading_time": 152800000,
              "loading_type": "initial_load",
              "long_task": {
                "count": 0
              },
              "referrer": "",
              "resource": {
                "count": 3
              },
              "time_spent": 3120000000,
              "url": "http://localhost:8080/test.html"
            },
            "_dd": {
              "document_version": 2,
              "drift": 0,
              "format_version": 2,
              "session": {
                "plan": 2
              }
            }
          },
          "tags": [
            "browser_sdk_version:3.6.13"
          ]
        }
        """)
        messageHandler?.userContentController(controller, didReceive: webRUMMessage)
        waitForExpectations(timeout: 1)
    }

    func testSendingWebRecordEvent() throws {
        let recordMessageExpectation = expectation(description: "Record message received")
        let controller = DDUserContentController()

        let core = PassthroughCoreMock(
            messageReceiver: FeatureMessageReceiverMock { message in
                switch message {
                case .value(let record as WebViewRecord):
                    XCTAssertEqual(record.view.id, "64308fd4-83f9-48cb-b3e1-1e91f6721230")
                    XCTAssertEqual(record.slotId, "\(controller.hash)")
                    let matcher = JSONObjectMatcher(object: record.event)
                    XCTAssertEqual(try? matcher.value("date"), 1_635_932_927_012)
                    recordMessageExpectation.fulfill()
                case .context:
                    break
                default:
                    XCTFail("Unexpected message received: \(message)")
                }
            }
        )

        WebViewTracking.enable(
            tracking: controller,
            hosts: ["datadoghq.com"],
            hostsSanitizer: HostsSanitizerMock(),
            logsSampleRate: 100,
            in: core
        )

        let messageHandler = try XCTUnwrap(controller.messageHandlers.first?.handler) as? DDScriptMessageHandler
        let webLogMessage = MockScriptMessage(body: """
        {
          "eventType": "record",
          "event": {
            "date": 1635932927012
          },
          "view": { "id": "64308fd4-83f9-48cb-b3e1-1e91f6721230" }
        }
        """)

        messageHandler?.userContentController(controller, didReceive: webLogMessage)
        waitForExpectations(timeout: 1)
    }
}

#endif
