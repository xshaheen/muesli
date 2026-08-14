import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Recording artifact playback", .serialized)
struct RecordingArtifactPlaybackTests {
    @MainActor
    private final class PlayerProbe {
        var invalidatedPlayers = 0
        var invalidationsSeenWhenDeletionStarted = 0
        var deletionCalls = 0
    }

    @MainActor
    private final class LifecycleProbe {
        var resolution: RecordingArtifactResolution

        init(_ resolution: RecordingArtifactResolution) {
            self.resolution = resolution
        }
    }

    private enum ExpectedFailure: Error {
        case deletionFailed
        case playbackFailed
        case revealFailed
    }

    @Test("cached history and diagnostic owners follow lifecycle transitions")
    func cachedOwnersRefreshTogether() async {
        let artifactID = RecordingArtifactPlaybackID(rawValue: UUID())
        let sessionID = UUID()
        let probe = LifecycleProbe(RecordingArtifactResolution(
            artifactID: artifactID,
            availability: .pendingDecision(expiresAt: Date(timeIntervalSince1970: 1_800))
        ))
        let coordinator = RecordingArtifactPlaybackCoordinator(
            client: RecordingArtifactPlaybackClient(
                resolve: { _ in await MainActor.run { probe.resolution } },
                playbackURL: { _ in URL(fileURLWithPath: "/tmp/not-opened-by-this-test.m4a") },
                reveal: { _ in },
                delete: { _ in }
            )
        )
        let owners: [RecordingArtifactOwner] = [.dictation(41), .session(sessionID)]
        for owner in owners {
            await coordinator.refresh(owner)
        }

        probe.resolution = RecordingArtifactResolution(
            artifactID: artifactID,
            availability: .available
        )
        await coordinator.refreshAllCachedOwners()
        for owner in owners {
            #expect(coordinator.resolution(for: owner).availability == .available)
        }

        probe.resolution = .unavailable(.expired)
        await coordinator.refreshAllCachedOwners()
        for owner in owners {
            #expect(coordinator.resolution(for: owner).availability == .expired)
        }

        probe.resolution = .unavailable(.deleted)
        await coordinator.refreshAllCachedOwners()
        for owner in owners {
            #expect(coordinator.resolution(for: owner).availability == .deleted)
        }
    }

    @Test("failed playback and reveal refresh missing state in both windows")
    func failedFileAccessRefreshesEveryCachedOwner() async {
        let artifactID = RecordingArtifactPlaybackID(rawValue: UUID())
        let sessionID = UUID()
        let available = RecordingArtifactResolution(
            artifactID: artifactID,
            availability: .available
        )
        let probe = LifecycleProbe(available)
        let coordinator = RecordingArtifactPlaybackCoordinator(
            client: RecordingArtifactPlaybackClient(
                resolve: { _ in await MainActor.run { probe.resolution } },
                playbackURL: { _ in
                    await MainActor.run { probe.resolution = .unavailable(.missing) }
                    throw ExpectedFailure.playbackFailed
                },
                reveal: { _ in
                    await MainActor.run { probe.resolution = .unavailable(.missing) }
                    throw ExpectedFailure.revealFailed
                },
                delete: { _ in }
            )
        )
        let owners: [RecordingArtifactOwner] = [.meeting(42), .session(sessionID)]
        for owner in owners {
            await coordinator.refresh(owner)
        }

        do {
            _ = try await coordinator.playbackURL(for: artifactID)
            Issue.record("Playback unexpectedly succeeded")
        } catch is ExpectedFailure {
            // Expected: the failed resolution publishes the store's missing state.
        } catch {
            Issue.record("Unexpected playback error: \(error)")
        }
        for owner in owners {
            #expect(coordinator.resolution(for: owner).availability == .missing)
        }

        probe.resolution = available
        await coordinator.refreshAllCachedOwners()
        do {
            try await coordinator.reveal(.meeting(42))
            Issue.record("Reveal unexpectedly succeeded")
        } catch is ExpectedFailure {
            // Expected: reveal failures follow the same refresh path.
        } catch {
            Issue.record("Unexpected reveal error: \(error)")
        }
        for owner in owners {
            #expect(coordinator.resolution(for: owner).availability == .missing)
        }
    }

    @Test("deleting from one surface invalidates every player before storage deletion")
    func deletionInvalidatesEverySurfaceBeforeStorage() async throws {
        let artifactID = RecordingArtifactPlaybackID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        )
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        let probe = PlayerProbe()
        let client = RecordingArtifactPlaybackClient(
            resolve: { owner in
                switch owner {
                case .meeting(14), .session(sessionID):
                    return RecordingArtifactResolution(
                        artifactID: artifactID,
                        availability: .available
                    )
                default:
                    return .unavailable(.notRetained)
                }
            },
            playbackURL: { _ in URL(fileURLWithPath: "/tmp/not-opened-by-this-test.m4a") },
            reveal: { _ in },
            delete: { receivedID in
                await MainActor.run {
                    #expect(receivedID == artifactID)
                    probe.invalidationsSeenWhenDeletionStarted = probe.invalidatedPlayers
                    probe.deletionCalls += 1
                }
            }
        )
        let coordinator = RecordingArtifactPlaybackCoordinator(client: client)

        await coordinator.refresh(.meeting(14))
        await coordinator.refresh(.session(sessionID))
        _ = coordinator.registerPlayer(for: artifactID) {
            probe.invalidatedPlayers += 1
        }
        _ = coordinator.registerPlayer(for: artifactID) {
            probe.invalidatedPlayers += 1
        }

        try await coordinator.delete(.meeting(14))

        #expect(probe.invalidatedPlayers == 2)
        #expect(probe.invalidationsSeenWhenDeletionStarted == 2)
        #expect(probe.deletionCalls == 1)
        #expect(coordinator.resolution(for: .meeting(14)).availability == .deleted)
        #expect(coordinator.resolution(for: .session(sessionID)).availability == .deleted)
    }

    @Test("failed durable deletion keeps playback disabled for a safe retry")
    func failedDeletionDoesNotRepublishPlayback() async {
        let artifactID = RecordingArtifactPlaybackID(rawValue: UUID())
        let probe = PlayerProbe()
        let coordinator = RecordingArtifactPlaybackCoordinator(
            client: RecordingArtifactPlaybackClient(
                resolve: { _ in
                    RecordingArtifactResolution(
                        artifactID: artifactID,
                        availability: .available
                    )
                },
                playbackURL: { _ in URL(fileURLWithPath: "/tmp/not-opened-by-this-test.m4a") },
                reveal: { _ in },
                delete: { _ in throw ExpectedFailure.deletionFailed }
            )
        )
        await coordinator.refresh(.dictation(22))
        _ = coordinator.registerPlayer(for: artifactID) {
            probe.invalidatedPlayers += 1
        }

        do {
            try await coordinator.delete(.dictation(22))
            Issue.record("Deletion unexpectedly succeeded")
        } catch is ExpectedFailure {
            // Expected: the store owns durable retry state.
        } catch {
            Issue.record("Unexpected deletion error: \(error)")
        }

        #expect(probe.invalidatedPlayers == 1)
        #expect(coordinator.resolution(for: .dictation(22)).availability == .deleting)
    }

    @Test("history-owned deletion can complete or restore a surviving shared artifact")
    func externalDeletionStateFollowsOwnerTransaction() async {
        let artifactID = RecordingArtifactPlaybackID(rawValue: UUID())
        let probe = PlayerProbe()
        let coordinator = RecordingArtifactPlaybackCoordinator(
            client: RecordingArtifactPlaybackClient(
                resolve: { _ in
                    RecordingArtifactResolution(
                        artifactID: artifactID,
                        availability: .available
                    )
                },
                playbackURL: { _ in URL(fileURLWithPath: "/tmp/not-opened-by-this-test.m4a") },
                reveal: { _ in },
                delete: { _ in }
            )
        )
        await coordinator.refresh(.meeting(31))
        await coordinator.refresh(.session(UUID()))
        _ = coordinator.registerPlayer(for: artifactID) {
            probe.invalidatedPlayers += 1
        }

        coordinator.beginExternalDeletion(artifactID: artifactID)

        #expect(probe.invalidatedPlayers == 1)
        #expect(coordinator.availability(for: artifactID) == .deleting)

        await coordinator.restoreAfterSharedOwnerRemoval(artifactID: artifactID)
        #expect(coordinator.availability(for: artifactID) == .available)

        coordinator.beginExternalDeletion(artifactID: artifactID)
        coordinator.finishExternalDeletion(artifactID: artifactID, succeeded: true)
        #expect(coordinator.availability(for: artifactID) == .deleted)
    }

    @Test("every unavailable recording lifecycle has explicit user-facing copy")
    func unavailableStatesHaveExplicitMessages() {
        let expiry = Date(timeIntervalSince1970: 1_800)
        let states: [RecordingArtifactAvailability] = [
            .notRetained,
            .declined,
            .pendingDecision(expiresAt: expiry),
            .deleting,
            .missing,
            .expired,
            .deleted,
            .invalidLegacy,
            .saveFailed,
        ]

        for state in states {
            #expect(!RecordingArtifactPresentation.message(for: state).isEmpty)
            #expect(!RecordingArtifactPresentation.systemImage(for: state).isEmpty)
        }

        #expect(RecordingArtifactAvailability(.never) == .notRetained)
        #expect(RecordingArtifactAvailability(.declined) == .declined)
        #expect(RecordingArtifactAvailability(.missing) == .missing)
        #expect(RecordingArtifactAvailability(.expired) == .expired)
        #expect(RecordingArtifactAvailability(.deleted) == .deleted)
        #expect(RecordingArtifactAvailability(.invalidLegacy) == .invalidLegacy)
        #expect(RecordingArtifactAvailability(.saveFailed) == .saveFailed)
    }

    @Test("controller shutdown retains Always audio and durably discards Ask audio")
    func controllerShutdownResolvesFrozenRecordingPolicies() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-shutdown-audio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let database = support.appendingPathComponent("muesli.sqlite")
        let historyStore = DictationStore(databaseURL: database)
        try historyStore.migrateIfNeeded()
        let artifactStore = try RecordingArtifactStore(
            databaseURL: database,
            recordingsRootURL: support.appendingPathComponent("recordings", isDirectory: true),
            legacyMeetingRootURL: support.appendingPathComponent("meeting-recordings", isDirectory: true),
            migrateDatabase: false
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: historyStore,
            recordingArtifactStore: artifactStore,
            configStore: ConfigStore(supportDirectory: support)
        )
        let alwaysSession = UUID()
        let promptSession = UUID()
        let alwaysURL = support.appendingPathComponent("always.wav")
        let promptURL = support.appendingPathComponent("prompt.wav")
        try Data(repeating: 1, count: 32).write(to: alwaysURL)
        try Data(repeating: 2, count: 32).write(to: promptURL)

        await controller.resolveShutdownDictationCapture(
            DictationAudioTerminalCapture(
                sessionID: alwaysSession,
                outcome: .cancelled,
                recordingSavePolicy: .always,
                wavURL: alwaysURL
            ),
            startedAt: Date()
        )
        await controller.resolveShutdownDictationCapture(
            DictationAudioTerminalCapture(
                sessionID: promptSession,
                outcome: .cancelled,
                recordingSavePolicy: .prompt,
                wavURL: promptURL
            ),
            startedAt: Date()
        )

        let rows = await controller.audioOnlyDictationHistory()
        let always = try #require(rows.first(where: { $0.sessionID == alwaysSession }))
        let prompt = try #require(rows.first(where: { $0.sessionID == promptSession }))
        #expect(always.availability == .available)
        #expect(always.artifactID != nil)
        #expect(prompt.availability == .deleted)
        #expect(prompt.artifactID == nil)
        #expect(!FileManager.default.fileExists(atPath: alwaysURL.path))
        #expect(!FileManager.default.fileExists(atPath: promptURL.path))
    }
}
