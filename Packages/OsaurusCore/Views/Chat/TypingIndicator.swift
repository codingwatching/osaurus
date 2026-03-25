//
//  TypingIndicator.swift
//  osaurus
//
//  Animated typing indicator with bouncing dots and live memory pressure readout.
//  Shows a prefill-progress bar while the GPU processes the prompt.
//

import SwiftUI

struct TypingIndicator: View {
    @State private var animatingDot: Int = 0
    @State private var elapsedSeconds: Int = 0
    @State private var elapsedTimer: Task<Void, Never>? = nil
    @Environment(\.theme) private var theme
    @ObservedObject private var monitor = SystemMonitorService.shared
    @ObservedObject private var inferenceProgress = InferenceProgressManager.shared

    private let dotCount = 3
    private let dotSize: CGFloat = 6
    private let spacing: CGFloat = 4

    var body: some View {
        Group {
            if inferenceProgress.prefillTokenCount != nil {
                prefillProgressView
            } else {
                bouncingDotsView
            }
        }
        .onAppear {
            startAnimation()
        }
        .onChange(of: inferenceProgress.prefillTokenCount) { _, newValue in
            if newValue != nil {
                startElapsedTimer()
            } else {
                stopElapsedTimer()
            }
        }
    }

    // MARK: - Prefill progress view

    private var prefillProgressView: some View {
        let tokenCount = inferenceProgress.prefillTokenCount ?? 0
        let label: String
        if tokenCount > 0 {
            label = "Processing \(tokenCount) tokens… (\(elapsedSeconds)s)"
        } else {
            label = "Processing prompt… (\(elapsedSeconds)s)"
        }

        return HStack(spacing: 8) {
            // Indeterminate shimmer bar
            PrefillShimmerBar()
                .frame(width: 80, height: 4)

            Text(label)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                .foregroundColor(theme.tertiaryText.opacity(0.8))
                .monospacedDigit()
        }
    }

    // MARK: - Normal bouncing-dots view

    private var bouncingDotsView: some View {
        HStack(spacing: 10) {
            // Bouncing dots
            HStack(spacing: spacing) {
                ForEach(0 ..< dotCount, id: \.self) { index in
                    Circle()
                        .fill(dotColor(for: index))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: animatingDot == index ? -4 : 0)
                        .animation(
                            .spring(response: 0.3, dampingFraction: 0.5)
                                .delay(Double(index) * 0.1),
                            value: animatingDot
                        )
                }
            }

            // Memory pressure
            if monitor.totalMemoryGB > 0 {
                memoryLabel
            }
        }
    }

    private var memoryLabel: some View {
        let used = monitor.usedMemoryGB
        let total = monitor.totalMemoryGB

        return HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.orange)
            Text(String(format: "%.1f / %.0f GB", used, total))
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .regular))
                .foregroundColor(.orange)
                .monospacedDigit()
        }
    }

    private func dotColor(for index: Int) -> Color {
        if animatingDot == index {
            return theme.accentColor
        } else {
            return theme.tertiaryText.opacity(0.6)
        }
    }

    private func startAnimation() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation {
                    animatingDot = (animatingDot + 1) % dotCount
                }
            }
        }
    }

    private func startElapsedTimer() {
        elapsedSeconds = 0
        if let startedAt = inferenceProgress.prefillStartedAt {
            elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        }
        elapsedTimer?.cancel()
        elapsedTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let startedAt = inferenceProgress.prefillStartedAt {
                    elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                } else {
                    elapsedSeconds += 1
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }
}

// MARK: - Indeterminate shimmer bar for prefill

private struct PrefillShimmerBar: View {
    @State private var phase: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.tertiaryText.opacity(0.15))

                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [.clear, theme.accentColor.opacity(0.6), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: phase * (geo.size.width + geo.size.width * 0.4) - geo.size.width * 0.4)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Alternative Pulse Style

struct TypingIndicatorPulse: View {
    @State private var isAnimating = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(theme.tertiaryText.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Skeleton Placeholder

struct SkeletonLine: View {
    let width: CGFloat
    @State private var isAnimating = false
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(
                LinearGradient(
                    colors: [
                        theme.tertiaryBackground.opacity(0.3),
                        theme.tertiaryBackground.opacity(0.6),
                        theme.tertiaryBackground.opacity(0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: 14)
            .mask(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: isAnimating ? width : -width)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

// MARK: - Preview

#if DEBUG
    struct TypingIndicator_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bouncing Dots")
                        .font(.caption)
                    TypingIndicator()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pulse Style")
                        .font(.caption)
                    TypingIndicatorPulse()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skeleton Lines")
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonLine(width: 200)
                        SkeletonLine(width: 160)
                        SkeletonLine(width: 180)
                    }
                }
            }
            .padding(40)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
