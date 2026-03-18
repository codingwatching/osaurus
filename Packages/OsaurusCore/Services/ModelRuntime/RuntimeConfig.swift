//
//  RuntimeConfig.swift
//  osaurus
//
//  Captures a snapshot of server-side generation configuration used by MLX.
//

import Foundation

struct RuntimeConfig: Sendable {
    let topP: Float
    let kvBits: Int?
    let kvGroup: Int
    let quantStart: Int
    let maxKV: Int?
    let prefillStep: Int

    static func snapshot() async -> RuntimeConfig {
        let cfg = await ServerController.sharedConfiguration()
        return RuntimeConfig(
            topP: cfg?.genTopP ?? 1.0,
            kvBits: cfg?.genKVBits,
            kvGroup: cfg?.genKVGroupSize ?? 64,
            quantStart: cfg?.genQuantizedKVStart ?? 0,
            maxKV: cfg?.genMaxKVSize ?? Self.defaultMaxKV(),
            prefillStep: cfg?.genPrefillStepSize ?? 1024
        )
    }

    /// Auto-detect a reasonable maxKV default based on available system RAM.
    /// Machines with more RAM can afford larger context windows.
    private static func defaultMaxKV() -> Int {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        switch ramGB {
        case 0 ..< 24: return 8192
        case 24 ..< 48: return 16384
        case 48 ..< 96: return 32768
        default: return 65536
        }
    }
}
