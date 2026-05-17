//
//  ExternalOfficeRuntimeDetectorTests.swift
//  osaurusTests
//
//  Uses temporary fake `soffice` executables so host-installed office suites
//  never influence detector behavior.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ExternalOfficeRuntimeDetector")
struct ExternalOfficeRuntimeDetectorTests {
    @Test func explicitURLWinsOverEnvironmentAndCommonPaths() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let explicit = root.appendingPathComponent("explicit/soffice")
        let environment = root.appendingPathComponent("environment/soffice")
        let common = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: explicit, output: "LibreOffice 24.2.0.3 420(Build:3)")
        try Self.writeFakeSoffice(at: environment, output: "Apache OpenOffice 4.1.15")
        try Self.writeFakeSoffice(at: common, output: "LibreOffice 7.6.4.1")

        let snapshot = await Self.detector(
            explicitExecutableURL: explicit,
            environment: [
                "OSAURUS_OFFICE_RUNTIME_PATH": environment.path
            ],
            commonApplicationCandidates: [
                .init(executableURL: common, kind: .libreOffice, source: .applicationBundle)
            ]
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.kind == .libreOffice)
        #expect(snapshot.version == "24.2.0.3")
        #expect(snapshot.executableURL == explicit.standardizedFileURL)
        #expect(snapshot.source == .explicitURL)
        #expect(snapshot.versionProbe?.status == .exited(status: 0))
    }

    @Test func environmentURLWinsWhenNoExplicitURLExists() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = root.appendingPathComponent("OpenOffice.app/Contents/MacOS/soffice")
        let common = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: environment, output: "Apache OpenOffice 4.1.15 AOO4115m1")
        try Self.writeFakeSoffice(at: common, output: "LibreOffice 7.6.4.1")

        let snapshot = await Self.detector(
            environment: [
                "OSAURUS_OFFICE_RUNTIME_URL": environment.absoluteString
            ],
            commonApplicationCandidates: [
                .init(executableURL: common, kind: .libreOffice, source: .applicationBundle)
            ]
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.kind == .openOffice)
        #expect(snapshot.version == "4.1.15")
        #expect(snapshot.executableURL == environment.standardizedFileURL)
        #expect(snapshot.source == .environmentVariable(name: "OSAURUS_OFFICE_RUNTIME_URL"))
    }

    @Test func commonApplicationOrderPrefersLibreOfficeBeforeOpenOffice() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let libreOffice = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        let openOffice = root.appendingPathComponent("OpenOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: libreOffice, output: "LibreOffice 7.6.4.1")
        try Self.writeFakeSoffice(at: openOffice, output: "Apache OpenOffice 4.1.15")

        let snapshot = await Self.detector(
            commonApplicationCandidates: [
                .init(executableURL: libreOffice, kind: .libreOffice, source: .applicationBundle),
                .init(executableURL: openOffice, kind: .openOffice, source: .applicationBundle),
            ]
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.kind == .libreOffice)
        #expect(snapshot.version == "7.6.4.1")
        #expect(snapshot.executableURL == libreOffice.standardizedFileURL)
    }

    @Test func pathSearchFindsExecutableSofficeAfterCommonMisses() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("bin/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "LibreOfficeDev 25.2.0.0.alpha0+ Build:abcd")

        let snapshot = await Self.detector(
            environment: [
                "PATH": soffice.deletingLastPathComponent().path
            ]
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.kind == .libreOffice)
        #expect(snapshot.version == "25.2.0.0.alpha0")
        #expect(snapshot.executableURL == soffice.standardizedFileURL)
        #expect(snapshot.source == .searchPath)
    }

    @Test func nonExecutableCandidateDoesNotBecomeAvailable() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nonExecutable = root.appendingPathComponent("bin/soffice")
        try Self.writePlainFile(at: nonExecutable, content: "LibreOffice 24.2.0.3\n")

        let snapshot = await Self.detector(
            environment: [
                "OSAURUS_OFFICE_RUNTIME_PATH": nonExecutable.path
            ]
        ).detect()

        #expect(snapshot == .unavailable)
    }

    @Test func versionProbeTimeoutStillReportsExecutableRuntime() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        try Self.writeExecutableScript(
            at: soffice,
            lines: [
                "#!/bin/sh",
                "while :; do :; done",
            ]
        )

        let snapshot = await Self.detector(
            commonApplicationCandidates: [
                .init(executableURL: soffice, kind: .libreOffice, source: .applicationBundle)
            ],
            timeoutSeconds: 0.05
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.kind == .libreOffice)
        #expect(snapshot.version == nil)
        #expect(snapshot.versionProbe?.status == .timedOut)
    }

    @Test func failedVersionProbeStillReportsExecutableRuntimeWithoutVersion() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("bin/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 24.2.0.3", exitStatus: 64)

        let snapshot = await Self.detector(
            environment: [
                "PATH": soffice.deletingLastPathComponent().path
            ]
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.kind == nil)
        #expect(snapshot.version == nil)
        #expect(snapshot.versionProbe?.status == .exited(status: 64))
    }

    @Test func versionProbeOutputIsBounded() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("bin/soffice")
        try Self.writeFakeSoffice(
            at: soffice,
            output: "LibreOffice 24.2.0.3 " + String(repeating: "x", count: 128)
        )

        let snapshot = await Self.detector(
            environment: [
                "PATH": soffice.deletingLastPathComponent().path
            ],
            maxOutputBytes: 16
        ).detect()

        #expect(snapshot.available)
        #expect(snapshot.version == nil)
        #expect(snapshot.versionProbe?.capturedOutputBytes == 16)
        #expect(snapshot.versionProbe?.outputWasTruncated == true)
    }

    @Test func representativeVersionParsing() {
        let libreOffice = ExternalOfficeRuntimeDetector.parseVersionOutput(
            "LibreOffice 7.5.9.2 50(Build:2)"
        )
        #expect(libreOffice?.kind == .libreOffice)
        #expect(libreOffice?.version == "7.5.9.2")

        let openOffice = ExternalOfficeRuntimeDetector.parseVersionOutput(
            "Apache OpenOffice 4.1.15 AOO4115m1(Build:9813)"
        )
        #expect(openOffice?.kind == .openOffice)
        #expect(openOffice?.version == "4.1.15")

        #expect(ExternalOfficeRuntimeDetector.parseVersionOutput("office runtime ready") == nil)
    }

    private static func detector(
        explicitExecutableURL: URL? = nil,
        environment: [String: String] = [:],
        commonApplicationCandidates: [ExternalOfficeRuntimeDetector.Candidate] = [],
        timeoutSeconds: TimeInterval = 2.0,
        maxOutputBytes: Int = 4_096
    ) -> ExternalOfficeRuntimeDetector {
        ExternalOfficeRuntimeDetector(
            configuration: .init(
                explicitExecutableURL: explicitExecutableURL,
                environment: environment,
                commonApplicationCandidates: commonApplicationCandidates,
                versionProbeTimeoutSeconds: timeoutSeconds,
                maxVersionProbeOutputBytes: maxOutputBytes
            )
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExternalOfficeRuntimeDetectorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeFakeSoffice(
        at url: URL,
        output: String,
        exitStatus: Int32 = 0
    ) throws {
        try Self.writeExecutableScript(
            at: url,
            lines: [
                "#!/bin/sh",
                #"if [ "$1" != "--version" ]; then"#,
                "  exit 64",
                "fi",
                "cat <<'OSAURUS_SOFFICE_VERSION'",
                output,
                "OSAURUS_SOFFICE_VERSION",
                "exit \(exitStatus)",
            ]
        )
    }

    private static func writePlainFile(
        at url: URL,
        content: String
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )
    }

    private static func writeExecutableScript(
        at url: URL,
        lines: [String]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
    }
}
