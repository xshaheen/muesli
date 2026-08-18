import Foundation
import MuesliCore
import Observation
import SwiftUI

/// Local UI identity for a retained recording. This type is intentionally not
/// Codable: recording identities must not drift into diagnostics, CLI, sync, or
/// telemetry payloads through synthesized serialization.
typealias RecordingArtifactPlaybackID = RecordingArtifactID

/// A local UI lookup key. History and diagnostics resolve independently so a
/// diagnostic association can disappear without becoming an owner of the file.
enum RecordingArtifactOwner: Hashable, Sendable {
    case dictation(Int64)
    case meeting(Int64)
    case session(UUID)
}

enum RecordingArtifactAvailability: Equatable, Sendable {
    case notRetained
    case declined
    case pendingDecision(expiresAt: Date?)
    case available
    case deleting
    case missing
    case expired
    case deleted
    case invalidLegacy
    case saveFailed
}

struct RecordingArtifactResolution: Equatable, Sendable {
    let artifactID: RecordingArtifactPlaybackID?
    let availability: RecordingArtifactAvailability

    static func unavailable(_ availability: RecordingArtifactAvailability) -> Self {
        Self(artifactID: nil, availability: availability)
    }
}

struct RecordingArtifactPlaybackClient: Sendable {
    var resolve: @Sendable (RecordingArtifactOwner) async throws -> RecordingArtifactResolution
    var playbackURL: @Sendable (RecordingArtifactPlaybackID) async throws -> URL
    var reveal: @Sendable (RecordingArtifactPlaybackID) async throws -> Void
    /// The implementation owns the durable association transaction and file
    /// removal. The coordinator publishes `deleting` and invalidates players
    /// before invoking it.
    var delete: @Sendable (RecordingArtifactPlaybackID) async throws -> Void

    static let unavailable = Self(
        resolve: { _ in .unavailable(.notRetained) },
        playbackURL: { _ in throw RecordingArtifactPlaybackError.unavailable },
        reveal: { _ in throw RecordingArtifactPlaybackError.unavailable },
        delete: { _ in throw RecordingArtifactPlaybackError.unavailable }
    )
}

enum RecordingArtifactPlaybackError: Error, LocalizedError, Equatable {
    case unavailable
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The retained recording is unavailable."
        case .invalidFile:
            return "The retained recording could not be opened safely."
        }
    }
}

enum RecordingArtifactPresentation {
    static func message(for availability: RecordingArtifactAvailability) -> String {
        switch availability {
        case .notRetained:
            return "Recording was not retained."
        case .declined:
            return "Recording was discarded."
        case .pendingDecision(let expiresAt):
            guard let expiresAt else { return "Waiting for a save decision." }
            return "Waiting for a save decision until \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
        case .available:
            return "Recording available."
        case .deleting:
            return "Deleting recording…"
        case .missing:
            return "The retained recording is missing."
        case .expired:
            return "The temporary recording expired."
        case .deleted:
            return "The retained recording was deleted."
        case .invalidLegacy:
            return "The legacy recording could not be opened safely."
        case .saveFailed:
            return "The recording could not be retained."
        }
    }

    static func systemImage(for availability: RecordingArtifactAvailability) -> String {
        switch availability {
        case .available: return "waveform"
        case .pendingDecision: return "clock"
        case .deleting: return "trash"
        case .missing, .invalidLegacy, .saveFailed: return "exclamationmark.triangle"
        case .notRetained, .declined, .expired, .deleted: return "waveform.slash"
        }
    }
}

extension RecordingArtifactAvailability {
    init(_ availability: RecordingAvailability, pendingExpiresAt: Date? = nil) {
        switch availability {
        case .never: self = .notRetained
        case .declined: self = .declined
        case .pending: self = .pendingDecision(expiresAt: pendingExpiresAt)
        case .available: self = .available
        case .missing: self = .missing
        case .expired: self = .expired
        case .deleted: self = .deleted
        case .saveFailed: self = .saveFailed
        case .invalidLegacy: self = .invalidLegacy
        }
    }
}

/// One app-wide coordinator lets history and diagnostic windows observe and
/// invalidate the same retained artifact without exposing its filesystem path.
@MainActor
@Observable
final class RecordingArtifactPlaybackCoordinator {
    static let shared = RecordingArtifactPlaybackCoordinator()

    private var client: RecordingArtifactPlaybackClient
    private var resolutions: [RecordingArtifactOwner: RecordingArtifactResolution] = [:]
    private var artifactStates: [RecordingArtifactPlaybackID: RecordingArtifactAvailability] = [:]
    private var invalidators: [RecordingArtifactPlaybackID: [UUID: @MainActor () -> Void]] = [:]
    private var ownerReferenceCounts: [RecordingArtifactOwner: Int] = [:]
    private(set) var revision = 0

    init(client: RecordingArtifactPlaybackClient = .unavailable) {
        self.client = client
    }

    func configure(client: RecordingArtifactPlaybackClient) {
        invalidateAllPlayers()
        self.client = client
        resolutions.removeAll()
        artifactStates.removeAll()
        ownerReferenceCounts.removeAll()
        revision &+= 1
    }

    func resolution(for owner: RecordingArtifactOwner) -> RecordingArtifactResolution {
        _ = revision
        guard let resolution = resolutions[owner] else {
            return .unavailable(.notRetained)
        }
        guard let artifactID = resolution.artifactID,
              let state = artifactStates[artifactID] else {
            return resolution
        }
        return RecordingArtifactResolution(artifactID: artifactID, availability: state)
    }

    func availability(for artifactID: RecordingArtifactPlaybackID) -> RecordingArtifactAvailability {
        _ = revision
        return artifactStates[artifactID] ?? .missing
    }

    func refresh(_ owner: RecordingArtifactOwner) async {
        do {
            let resolution = try await client.resolve(owner)
            let previousResolution = resolutions[owner]
            let artifactStateChanged: Bool
            if let artifactID = resolution.artifactID {
                let previousArtifactState = artifactStates[artifactID]
                artifactStateChanged = previousArtifactState != .deleting
                    && previousArtifactState != resolution.availability
            } else {
                artifactStateChanged = false
            }
            resolutions[owner] = resolution
            if let artifactID = resolution.artifactID,
               artifactStates[artifactID] != .deleting {
                artifactStates[artifactID] = resolution.availability
            }
            if previousResolution != resolution || artifactStateChanged {
                revision &+= 1
            }
        } catch {
            let missing = RecordingArtifactResolution.unavailable(.missing)
            if resolutions[owner] != missing {
                resolutions[owner] = missing
                revision &+= 1
            }
        }
    }

    func refreshAllCachedOwners() async {
        let cachedOwners = Array(resolutions.keys)
        for owner in cachedOwners {
            await refresh(owner)
        }
    }

    func retain(_ owner: RecordingArtifactOwner) {
        ownerReferenceCounts[owner, default: 0] += 1
    }

    func release(_ owner: RecordingArtifactOwner) {
        guard let count = ownerReferenceCounts[owner] else { return }
        if count > 1 {
            ownerReferenceCounts[owner] = count - 1
            return
        }
        ownerReferenceCounts[owner] = nil
        let artifactID = resolutions.removeValue(forKey: owner)?.artifactID
        if let artifactID,
           !resolutions.values.contains(where: { $0.artifactID == artifactID }),
           invalidators[artifactID] == nil {
            artifactStates[artifactID] = nil
        }
    }

    func playbackURL(for artifactID: RecordingArtifactPlaybackID) async throws -> URL {
        guard availability(for: artifactID) == .available else {
            throw RecordingArtifactPlaybackError.unavailable
        }
        do {
            let url = try await client.playbackURL(artifactID)
            guard url.isFileURL else { throw RecordingArtifactPlaybackError.invalidFile }
            return url
        } catch {
            await refreshAllCachedOwners()
            throw error
        }
    }

    func reveal(_ owner: RecordingArtifactOwner) async throws {
        let resolution = resolution(for: owner)
        guard resolution.availability == .available,
              let artifactID = resolution.artifactID else {
            throw RecordingArtifactPlaybackError.unavailable
        }
        do {
            try await client.reveal(artifactID)
        } catch {
            await refreshAllCachedOwners()
            throw error
        }
    }

    func delete(_ owner: RecordingArtifactOwner) async throws {
        let resolution = resolution(for: owner)
        guard resolution.availability == .available,
              let artifactID = resolution.artifactID else {
            throw RecordingArtifactPlaybackError.unavailable
        }

        artifactStates[artifactID] = .deleting
        revision &+= 1
        invalidatePlayers(for: artifactID)

        do {
            try await client.delete(artifactID)
            publishDeletionResult(artifactID: artifactID, succeeded: true)
        } catch {
            // The durable store owns retry state. Keep playback disabled rather
            // than reopening a file whose associations may already be cleared.
            publishDeletionResult(artifactID: artifactID, succeeded: false)
            throw error
        }
    }

    /// History deletion starts outside this coordinator because ownership is
    /// decided transactionally by the store. Publish the transition first so
    /// every window stops using the file before that transaction begins.
    func beginExternalDeletion(artifactID: RecordingArtifactPlaybackID) {
        artifactStates[artifactID] = .deleting
        revision &+= 1
        invalidatePlayers(for: artifactID)
    }

    /// Completes a history-owned deletion attempt. Failure intentionally keeps
    /// playback disabled because the store may have durably queued file cleanup.
    func finishExternalDeletion(
        artifactID: RecordingArtifactPlaybackID,
        succeeded: Bool
    ) {
        publishDeletionResult(artifactID: artifactID, succeeded: succeeded)
    }

    private func publishDeletionResult(
        artifactID: RecordingArtifactPlaybackID,
        succeeded: Bool
    ) {
        artifactStates[artifactID] = succeeded ? .deleted : .deleting
        if succeeded {
            for (owner, existing) in resolutions where existing.artifactID == artifactID {
                resolutions[owner] = RecordingArtifactResolution(
                    artifactID: artifactID,
                    availability: .deleted
                )
            }
        }
        revision &+= 1
    }

    /// Removing one of several owners does not delete the shared file. Re-read
    /// every known association after the store commits so surviving windows can
    /// publish `available` again without reopening during the transaction.
    func restoreAfterSharedOwnerRemoval(artifactID: RecordingArtifactPlaybackID) async {
        let owners = resolutions.compactMap { owner, resolution in
            resolution.artifactID == artifactID ? owner : nil
        }
        artifactStates[artifactID] = nil
        revision &+= 1
        for owner in owners {
            await refresh(owner)
        }
    }

    @discardableResult
    func registerPlayer(
        for artifactID: RecordingArtifactPlaybackID,
        invalidate: @escaping @MainActor () -> Void
    ) -> UUID {
        let token = UUID()
        invalidators[artifactID, default: [:]][token] = invalidate
        return token
    }

    func unregisterPlayer(for artifactID: RecordingArtifactPlaybackID, token: UUID) {
        invalidators[artifactID]?[token] = nil
        if invalidators[artifactID]?.isEmpty == true {
            invalidators[artifactID] = nil
        }
    }

    private func invalidatePlayers(for artifactID: RecordingArtifactPlaybackID) {
        let callbacks = invalidators
            .removeValue(forKey: artifactID)
            .map { Array($0.values) } ?? []
        for callback in callbacks {
            callback()
        }
    }

    private func invalidateAllPlayers() {
        let callbacks = invalidators.values.flatMap { $0.values }
        invalidators.removeAll()
        for callback in callbacks {
            callback()
        }
    }
}

struct RecordingArtifactSection: View {
    let owner: RecordingArtifactOwner
    var coordinator: RecordingArtifactPlaybackCoordinator = .shared
    var allowsReveal = true
    var allowsDeletion = true

    @State private var isConfirmingDeletion = false
    @State private var errorMessage: String?

    var body: some View {
        let resolution = coordinator.resolution(for: owner)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                Label("Source Recording", systemImage: RecordingArtifactPresentation.systemImage(for: resolution.availability))
                    .font(MuesliTheme.headline())
                Spacer()
                if resolution.availability == .available {
                    if allowsReveal {
                        Button("Show in Finder") {
                            Task { await reveal() }
                        }
                        .buttonStyle(.link)
                    }
                    if allowsDeletion {
                        Button("Delete Recording", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if resolution.availability == .available, let artifactID = resolution.artifactID {
                RecordingArtifactPlayerView(
                    artifactID: artifactID,
                    coordinator: coordinator
                )
            } else if resolution.availability == .deleting {
                HStack(spacing: MuesliTheme.spacing8) {
                    ProgressView().controlSize(.small)
                    Text(RecordingArtifactPresentation.message(for: resolution.availability))
                }
                .foregroundStyle(MuesliTheme.textTertiary)
            } else {
                Text(RecordingArtifactPresentation.message(for: resolution.availability))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .task(id: owner) { await coordinator.refresh(owner) }
        .onAppear { coordinator.retain(owner) }
        .onDisappear { coordinator.release(owner) }
        .alert("Delete Recording?", isPresented: $isConfirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Recording", role: .destructive) {
                Task { await deleteRecording() }
            }
        } message: {
            Text("This removes the retained audio from every history and diagnostic player. Transcript and diagnostic metadata are preserved.")
        }
        .alert(
            "Recording",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func reveal() async {
        do {
            try await coordinator.reveal(owner)
        } catch {
            errorMessage = error.localizedDescription
            await coordinator.refresh(owner)
        }
    }

    @MainActor
    private func deleteRecording() async {
        do {
            try await coordinator.delete(owner)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RecordingArtifactAvailabilityBadge: View {
    let owner: RecordingArtifactOwner
    var coordinator: RecordingArtifactPlaybackCoordinator = .shared

    var body: some View {
        let availability = coordinator.resolution(for: owner).availability
        if availability == .available {
            Label("Recording", systemImage: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MuesliTheme.textSecondary.opacity(0.12))
                .clipShape(Capsule())
                .help("Saved recording available")
                .accessibilityLabel("Saved recording available")
        }
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: owner) { await coordinator.refresh(owner) }
            .onAppear { coordinator.retain(owner) }
            .onDisappear { coordinator.release(owner) }
    }
}
