//
//  PluginAccessibilityInvocationTests.swift
//  OsaurusCoreTests
//
//  Regresses the MCP stdio crash class where native macOS UI tools
//  (`click_element`, `type_text`, `press_key`) crossed `/mcp/call` and
//  dereferenced Accessibility/AppKit objects from a plugin queue.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PluginAccessibilityInvocationTests {
    final class InvokeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(id: String, payload: String, mainThread: Bool)] = []

        var snapshots: [(id: String, payload: String, mainThread: Bool)] {
            lock.withLock { calls }
        }

        func record(id: String, payload: String, mainThread: Bool) {
            lock.withLock { calls.append((id, payload, mainThread)) }
        }
    }

    @Test
    func accessibilityPluginToolsInvokeOnMainThread() async throws {
        let recorder = InvokeRecorder()
        let (plugin, retain) = makePlugin(recorder: recorder)
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }
        let tool = ExternalTool(
            plugin: plugin,
            spec: PluginManifest.ToolSpec(
                id: "type_text",
                description: "Type text into the focused UI element",
                parameters: nil,
                requirements: ["accessibility"],
                permission_policy: "auto"
            )
        )

        let result = try await tool.execute(argumentsJSON: #"{"text":"hello"}"#)

        #expect(result == #"{"ok":true}"#)
        let call = try #require(recorder.snapshots.first)
        #expect(call.id == "type_text")
        #expect(call.payload == #"{"text":"hello"}"#)
        #expect(call.mainThread)
    }

    @Test
    func regularPluginToolsStayOnPluginQueue() async throws {
        let recorder = InvokeRecorder()
        let (plugin, retain) = makePlugin(recorder: recorder)
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }
        let tool = ExternalTool(
            plugin: plugin,
            spec: PluginManifest.ToolSpec(
                id: "fetch_status",
                description: "Fetch status from a remote API",
                parameters: nil,
                requirements: [],
                permission_policy: "auto"
            )
        )

        _ = try await tool.execute(argumentsJSON: #"{"project":"osaurus"}"#)

        let call = try #require(recorder.snapshots.first)
        #expect(call.id == "fetch_status")
        #expect(!call.mainThread)
    }

    private func makePlugin(
        recorder: InvokeRecorder
    ) -> (plugin: ExternalPlugin, retain: Unmanaged<InvokeRecorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: { ctxPtr, _, idPtr, payloadPtr in
                guard let ctxPtr, let idPtr, let payloadPtr else { return nil }
                let recorder = Unmanaged<InvokeRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                recorder.record(
                    id: String(cString: idPtr),
                    payload: String(cString: payloadPtr),
                    mainThread: Thread.isMainThread
                )
                return UnsafePointer(strdup(#"{"ok":true}"#))
            },
            version: 6,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: nil
        )
        let pluginId = "com.test.accessibility-invoke.\(UUID().uuidString)"
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
        return (
            ExternalPlugin(
                handle: ctx,
                api: api,
                ctx: ctx,
                manifest: manifest,
                path: "/tmp/accessibility-invoke-\(pluginId)",
                abiVersion: 6
            ),
            retain
        )
    }
}
