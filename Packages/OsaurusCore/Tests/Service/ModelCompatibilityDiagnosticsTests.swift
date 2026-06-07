//
//  ModelCompatibilityDiagnosticsTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelCompatibilityDiagnosticsTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-compat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeBundle(
        at dir: URL,
        config: String = #"{"model_type":"qwen3"}"#,
        tokenizer: Bool = true,
        weights: Bool = true
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        if tokenizer {
            try? Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        }
        if weights {
            try? Data("w".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        }
    }

    @Test func externalBundle_reportsUnprovenRuntimeAndMissingProof() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(at: root)

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.source.kind == .external)
        #expect(report.localBundle.kind == .available)
        #expect(report.runtime.reason == .externalBundleUnproven)
        #expect(report.benchmark.kind == .missingProof)
        #expect(report.featureHooks.map(\.code) == [.dflashSpeculativeDecoding, .tensorParallelism])
    }

    @Test func externalBundleDiagnostic_acceptsHFCacheBlobSymlinks() {
        let cacheRoot = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let fm = FileManager.default
        let blobs = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = cacheRoot.appendingPathComponent("models--org--repo/snapshots/rev", isDirectory: true)
        try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: snapshot, withIntermediateDirectories: true)

        let configBlob = blobs.appendingPathComponent("config")
        let tokenizerBlob = blobs.appendingPathComponent("tokenizer")
        let weightsBlob = blobs.appendingPathComponent("weights")
        try? Data(#"{"model_type":"qwen3"}"#.utf8).write(to: configBlob)
        try? Data("{}".utf8).write(to: tokenizerBlob)
        try? Data("w".utf8).write(to: weightsBlob)
        try? fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("config.json"),
            withDestinationURL: configBlob
        )
        try? fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("tokenizer.json"),
            withDestinationURL: tokenizerBlob
        )
        try? fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("model.safetensors"),
            withDestinationURL: weightsBlob
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: nil,
            bundleURL: snapshot,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.localBundle.kind == .available)
        #expect(report.runtime.reason == .externalBundleUnproven)
    }

    @Test func hunyuanDenseConfig_reportsUnsupportedFamily() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config:
                #"{"model_type":"hunyuan_v1_dense","architectures":["HunYuanDenseV1ForCausalLM"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "mlx-community/HY-MT1.5-7B-bf16",
            modelName: "HY-MT1.5",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.runtime.kind == .blocked)
        #expect(report.runtime.reason == .unsupportedHunyuanDense)
        #expect(report.benchmark.kind == .notApplicable)
    }

    @Test func hunyuanDenseArchitecture_reportsUnsupportedFamily() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"architectures":["HunYuanDenseV1ForCausalLM"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "mlx-community/HY-MT1.5-7B-bf16",
            modelName: "HY-MT1.5",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.runtime.kind == .blocked)
        #expect(report.runtime.reason == .unsupportedHunyuanDense)
    }

    @Test func longCatConfig_reportsUnsupportedFamily() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"longcat_next","architectures":["LongCatFlashForConditionalGeneration"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "meituan-longcat/LongCat-Next",
            modelName: "LongCat Next",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.runtime.kind == .blocked)
        #expect(report.runtime.reason == .unsupportedLongCat)
    }

    @Test func catalogEntryWithoutBundle_reportsDownloadRequired() {
        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: "qwen3",
            bundleURL: nil,
            externalSource: nil
        )

        #expect(report.source.kind == .catalog)
        #expect(report.localBundle.kind == .notDownloaded)
        #expect(report.runtime.reason == .needsDownload)
        #expect(report.benchmark.kind == .notApplicable)
        #expect(report.featureHooks.isEmpty)
    }

    @Test func incompleteBundle_reportsRuntimeBlocker() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(at: root, weights: false)

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.localBundle.kind == .incomplete)
        #expect(report.localBundle.title == "Safetensors missing")
        #expect(report.runtime.reason == .incompleteBundle)
    }
}
