//
//  ClipboardService.swift
//  osaurus
//
//  Service for monitoring the macOS pasteboard and capturing selections.
//

import AppKit
import Combine
import Foundation

/// Service for monitoring the macOS pasteboard and capturing selections from other apps
@MainActor
public final class ClipboardService: ObservableObject {
    public static let shared = ClipboardService()

    /// The current text on the pasteboard
    @Published public private(set) var currentClipboardText: String?
    
    /// The application that was frontmost when the clipboard last changed
    @Published public private(set) var lastSourceApp: String?

    /// Whether the clipboard content has been "seen" or used
    @Published public var hasNewContent: Bool = false

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: AnyCancellable?
    private let keyboardService = KeyboardSimulationService.shared

    private init() {
        startMonitoring()
    }

    /// Start polling the pasteboard for changes
    public func startMonitoring() {
        guard timer == nil else { return }
        print("[ClipboardService] Starting monitoring...")
        
        // Poll every 0.5 seconds for pasteboard changes
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPasteboard()
            }
    }

    /// Stop polling the pasteboard
    public func stopMonitoring() {
        print("[ClipboardService] Stopping monitoring")
        timer?.cancel()
        timer = nil
    }

    /// Explicitly check the pasteboard for changes
    public func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        
        print("[ClipboardService] Pasteboard change detected. Count: \(pb.changeCount) (was \(lastChangeCount))")
        lastChangeCount = pb.changeCount
        
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // only update if text actually changed to avoid noise from non-string clipboard changes
            if text != currentClipboardText {
                print("[ClipboardService] New text content detected: \"\(text.prefix(30))...\"")
                currentClipboardText = text
                hasNewContent = true
                
                // identify the source application
                if let frontmost = NSWorkspace.shared.frontmostApplication {
                    lastSourceApp = frontmost.localizedName ?? frontmost.bundleIdentifier
                    print("[ClipboardService] Source app identified: \(lastSourceApp ?? "unknown")")
                }
            } else {
                print("[ClipboardService] Change detected but text content is identical to current.")
            }
        } else {
            print("[ClipboardService] Change detected but no meaningful text found on pasteboard.")
        }
    }

    /// Attempt to grab the current selection from the active application
    /// by simulating Cmd+C and waiting for the pasteboard to update.
    public func grabSelection() async -> String? {
        let pb = NSPasteboard.general
        let startChangeCount = pb.changeCount
        print("[ClipboardService] Starting grabSelection. Current changeCount: \(startChangeCount)")
        
        // 1. simulate Cmd+C
        let posted = keyboardService.copySelection()
        print("[ClipboardService] copySelection() call returned: \(posted)")
        
        if !posted {
            print("[ClipboardService] FAILED to post Cmd+C event. Likely missing accessibility permissions.")
            return nil
        }
        
        // 2. wait for update (up to 500ms)
        print("[ClipboardService] Waiting for pasteboard update...")
        for i in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if pb.changeCount != startChangeCount {
                print("[ClipboardService] Pasteboard update detected at iteration \(i+1). New count: \(pb.changeCount)")
                checkPasteboard()
                return currentClipboardText
            }
        }
        
        print("[ClipboardService] TIMEOUT: Pasteboard did not update after 500ms.")
        return nil
    }

    /// Mark the current clipboard content as "read"
    public func markAsRead() {
        hasNewContent = false
    }
}
