import Testing
import AppKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meetings navigation")
struct MeetingsNavigationTests {

    private func makeController(
        dictationStore: DictationStore? = nil,
        configStore: ConfigStore? = nil
    ) -> MuesliController {
        MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: dictationStore,
            configStore: configStore ?? ConfigStore(supportDirectory: makeSupportDirectory())
        )
    }

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-nav-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeSupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-nav-support-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeInFlightCleanupController() throws -> (
        controller: MuesliController,
        meetingID: Int64,
        probe: CancellableMeetingCleanupSenderProbe
    ) {
        let store = try makeStore()
        let transcript = (0..<40).map {
            "[10:\(String(format: "%02d", $0)):00] Speaker 1: "
                + String(repeating: "word ", count: 40)
        }.joined(separator: "\n")
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Consent cancellation",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: transcript,
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let configStore = ConfigStore(supportDirectory: makeSupportDirectory())
        let backend = TranscriptCleanupBackendOption.hosted(.ollama)
        var config = AppConfig()
        config.postProcessorBackend = backend.backend
        config.ollamaURL = "http://localhost:11434"
        #expect(MeetingTranscriptCleanupPolicy.grantConsent(for: backend, config: &config))
        configStore.save(config)

        let probe = CancellableMeetingCleanupSenderProbe()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: configStore,
            meetingTranscriptCleanupSenderFactory: { _, _ in
                { payload in try await probe.send(payload) }
            }
        )
        return (controller, meetingID, probe)
    }

    private func waitForCleanupSend(
        _ probe: CancellableMeetingCleanupSenderProbe,
        toFinish: Bool = false
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let reached = toFinish ? await probe.finishedSendCount > 0 : await probe.sendCount > 0
            if reached { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult
    private func insertMeeting(
        in store: DictationStore,
        title: String,
        savedRecordingPath: String?
    ) throws -> Int64 {
        let now = Date()
        return try store.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingPath
        )
    }

    @Test("app state defaults meetings to browser mode")
    func meetingsDefaultToBrowser() {
        let appState = AppState()

        #expect(appState.meetingsNavigationState == .browser)
        #expect(appState.selectedMeeting == nil)
    }

    @Test("foreground meeting starts open and present notes")
    func foregroundMeetingStartPresentation() {
        let presentation = MeetingStartPresentation.foregroundNotes

        #expect(presentation.opensMeetingDocument)
        #expect(presentation.presentsHistoryWindow)
        #expect(!presentation.presentsFloatingPanelWhenRecordingStarts)
    }

    @Test("background meeting starts only transition the recording pill")
    func backgroundMeetingStartPresentation() {
        let presentation = MeetingStartPresentation.backgroundPill

        #expect(!presentation.opensMeetingDocument)
        #expect(!presentation.presentsHistoryWindow)
        #expect(!presentation.presentsFloatingPanelWhenRecordingStarts)
    }

    @Test("compact control presentation requests floating UI without opening the main window")
    func compactControlMeetingStartPresentation() {
        let presentation = MeetingStartPresentation.compactControl

        #expect(presentation == .floatingPanel)
        #expect(!presentation.opensMeetingDocument)
        #expect(!presentation.presentsHistoryWindow)
        #expect(presentation.presentsFloatingPanelWhenRecordingStarts)
    }

    @Test("each dashboard statistic opens insights with its originating section")
    func dashboardStatisticsOpenInsights() {
        let controller = makeController()

        for section in InsightsSection.allCases {
            controller.openInsights(section: section)
            #expect(controller.appState.selectedTab == .insights)
            #expect(controller.appState.insightsInitialSection == section)
        }
    }

    @Test("closing insights returns to dictations")
    func closingInsightsReturnsToDictations() {
        let controller = makeController()
        controller.openInsights(section: .meetings)

        controller.closeInsights()

        #expect(controller.appState.selectedTab == .dictations)
        #expect(controller.appState.insightsInitialSection == .meetings)
    }

    @Test("discard confirmation maps checkbox selections to meeting discard resolutions")
    func discardConfirmationResolutionMapping() {
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: nil
            ) == .discardRecording
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: false
            ) == .keepManualNotes
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: true
            ) == .deleteDraft
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertSecondButtonReturn,
                deleteManualNotes: false
            ) == nil
        )
    }

    /// A confirmation the user leaves open while its meeting ends must not discard the
    /// recording that replaced it — the sheet is modal to a window, not to the meeting.
    @Test("a discard only applies to the recording its confirmation was raised for")
    func discardAppliesOnlyToItsOwnRecording() {
        let owner = UUID()
        let replacement = UUID()

        #expect(MuesliController.shouldApplyDiscard(alertOwnerID: owner, activeOwnerID: owner))
        #expect(!MuesliController.shouldApplyDiscard(alertOwnerID: owner, activeOwnerID: replacement))
        #expect(!MuesliController.shouldApplyDiscard(alertOwnerID: owner, activeOwnerID: nil))
        // The menu path raises the alert without a panel behind it, so it is not scoped.
        #expect(MuesliController.shouldApplyDiscard(alertOwnerID: nil, activeOwnerID: replacement))
        #expect(MuesliController.shouldApplyDiscard(alertOwnerID: nil, activeOwnerID: nil))
    }

    @Test("selectedMeeting requires the full document record")
    func selectedMeetingUsesFullDocumentRecord() {
        let appState = AppState()
        let second = makeMeeting(id: 202, title: "Second")
        appState.meetingRows = [makeMeetingList(id: 202, title: "Second")]

        #expect(appState.selectedMeeting == nil)

        appState.selectedMeetingID = 202
        #expect(appState.selectedMeeting == nil)

        appState.selectedMeetingRecord = second
        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Second")
    }

    @Test("selectedMeeting falls back to the stored document record outside the browser slice")
    func selectedMeetingUsesStoredRecordWhenNotInRows() {
        let appState = AppState()
        let selected = makeMeeting(id: 202, title: "Selected Outside Slice")
        appState.meetingRows = [makeMeetingList(id: 101, title: "Visible")]
        appState.selectedMeetingID = 202
        appState.selectedMeetingRecord = selected

        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Selected Outside Slice")
    }

    @Test("dashboard projection keeps document selection fully hydrated")
    func dashboardProjectionLoadsFullSelectedMeeting() throws {
        let store = try makeStore()
        let transcript = "full transcript " + String(repeating: "x", count: 2_000)
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Projected",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: transcript,
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let controller = makeController(dictationStore: store)
        controller.appState.selectedMeetingID = meetingID

        controller.syncAppState()

        let listRow = try #require(controller.appState.meetingRows.first { $0.id == meetingID })
        #expect(listRow.preview.count == MeetingListRecord.previewCharacterLimit)
        #expect(controller.appState.selectedMeeting?.rawTranscript == transcript)
        #expect(controller.meeting(id: meetingID)?.rawTranscript == transcript)
    }

    @Test("showMeetingDocument enters meetings document route and records selection")
    func showMeetingDocumentRoutesToDocument() {
        let controller = makeController()

        controller.appState.selectedTab = .dictations
        controller.appState.selectedFolderID = 55

        controller.showMeetingDocument(id: 202)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedMeetingID == 202)
        #expect(controller.appState.meetingsNavigationState == .document(202))
        #expect(controller.appState.selectedFolderID == 55)
    }

    @Test("showMeetingsHome returns to browser and preserves prior meeting selection")
    func showMeetingsHomeReturnsToBrowser() {
        let controller = makeController()

        controller.appState.selectedMeetingID = 303
        controller.appState.meetingsNavigationState = .document(303)

        controller.showMeetingsHome(folderID: 99)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedFolderID == 99)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(controller.appState.selectedMeetingID == 303)
    }

    @Test("showMeetingsHome with nil folder resets browser to all meetings")
    func showMeetingsHomeResetsFolderFilter() {
        let controller = makeController()

        controller.appState.selectedFolderID = 11
        controller.appState.meetingsNavigationState = .document(404)

        controller.showMeetingsHome(folderID: nil)

        #expect(controller.appState.selectedFolderID == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
    }

    @Test("deleteMeeting clears selected detail state without following an unsafe legacy path")
    func deleteMeetingClearsSelection() throws {
        let store = try makeStore()
        let savedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-\(UUID().uuidString).wav")
        try Data("test".utf8).write(to: savedRecordingURL)

        let now = Date()
        try store.insertMeeting(
            title: "Delete Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )

        let controller = makeController(dictationStore: store)
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        controller.appState.selectedMeetingID = meetingID
        controller.appState.selectedMeetingRecord = try store.meeting(id: meetingID)
        controller.appState.meetingsNavigationState = .document(meetingID)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(controller.appState.selectedMeetingID == nil)
        #expect(controller.appState.selectedMeetingRecord == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
        // Legacy files outside the app-owned meeting-recordings root are
        // quarantined, never followed or removed by history deletion.
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
        try? FileManager.default.removeItem(at: savedRecordingURL)
    }

    @Test("deleteMeeting removes saved recording waveform cache")
    func deleteMeetingRemovesSavedRecordingWaveformCache() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let meetingID = try insertMeeting(
            in: store,
            title: "Delete Cache Target",
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
    }

    @Test("deleteMeeting removes saved recording when waveform cache removal fails")
    func deleteMeetingRemovesSavedRecordingWhenWaveformCacheRemovalFails() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.wav")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let cacheDirectory = cacheURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path) }
        let meetingID = try insertMeeting(
            in: store,
            title: "Delete Cache Failure Target",
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("clearMeetingHistory removes saved recordings and waveform cache")
    func clearMeetingHistoryRemovesSavedRecordingsAndWaveformCache() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let strandedCacheURL = RecordingWaveformCacheFiles
            .cacheDirectory(supportDirectory: supportDirectory)
            .appendingPathComponent("stranded.mwf")
        try Data("old-cache".utf8).write(to: strandedCacheURL)
        try insertMeeting(in: store, title: "Clear Target", savedRecordingPath: savedRecordingURL.path)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.clearMeetingHistory()

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: strandedCacheURL.path) == false)
    }

    @Test("clearMeetingHistory proceeds when waveform cache removal fails")
    func clearMeetingHistoryProceedsWhenWaveformCacheRemovalFails() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
            let cacheDirectory = RecordingWaveformCacheFiles.cacheDirectory(supportDirectory: supportDirectory)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let cacheDirectory = cacheURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
        try insertMeeting(in: store, title: "Clear Cache Failure Target", savedRecordingPath: savedRecordingURL.path)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.clearMeetingHistory()

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("deleteMeeting keeps a shared recording while removing the obsolete legacy waveform cache")
    func deleteMeetingKeepsSharedSavedRecordingAndRemovesLegacyWaveformCache() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = supportDirectory.appendingPathComponent("shared.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let firstID = try insertMeeting(in: store, title: "Shared A", savedRecordingPath: savedRecordingURL.path)
        let secondID = try insertMeeting(in: store, title: "Shared B", savedRecordingPath: savedRecordingURL.path)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.deleteMeeting(id: firstID)

        #expect(try store.meeting(id: firstID) == nil)
        #expect(try store.meeting(id: secondID) != nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
    }

    @Test("startup migration preserves every owner of a shared legacy recording")
    func startupMigrationPreservesSharedLegacyRecordingOwners() throws {
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let database = supportDirectory.appendingPathComponent("muesli.sqlite")
        let historyStore = DictationStore(databaseURL: database)
        try historyStore.migrateIfNeeded()
        let legacyRoot = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyURL = legacyRoot.appendingPathComponent("shared.wav")
        try Data("shared-recording".utf8).write(to: legacyURL)
        let firstID = try insertMeeting(in: historyStore, title: "Shared legacy A", savedRecordingPath: legacyURL.path)
        let secondID = try insertMeeting(in: historyStore, title: "Shared legacy B", savedRecordingPath: legacyURL.path)
        let artifactStore = try RecordingArtifactStore(
            databaseURL: database,
            recordingsRootURL: supportDirectory.appendingPathComponent("recordings", isDirectory: true),
            legacyMeetingRootURL: legacyRoot
        )

        try MuesliController.migrateLegacyMeetingRecordings(
            historyStore: historyStore,
            artifactStore: artifactStore
        )

        let loadedFirstReference = try artifactStore.recordingForMeeting(id: firstID)
        let loadedSecondReference = try artifactStore.recordingForMeeting(id: secondID)
        let firstReference = try #require(loadedFirstReference)
        let secondReference = try #require(loadedSecondReference)
        let artifactID = try #require(firstReference.artifactID)
        #expect(secondReference.artifactID == artifactID)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let retainedURL = try artifactStore.playableURL(id: artifactID)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))

        #expect(try historyStore.deleteMeeting(id: firstID) == nil)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(try historyStore.deleteMeeting(id: secondID) == artifactID)
        try artifactStore.finishDurableDeletion(id: artifactID)
        #expect(!FileManager.default.fileExists(atPath: retainedURL.path))
    }

    @Test("orphan sweep removes waveform cache when source recording is gone")
    func orphanSweepRemovesCacheWhenSourceRecordingIsGone() throws {
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let liveRecordingURL = supportDirectory.appendingPathComponent("live.m4a")
        let missingRecordingURL = supportDirectory.appendingPathComponent("missing.m4a")
        try Data("live".utf8).write(to: liveRecordingURL)
        try Data("missing".utf8).write(to: missingRecordingURL)
        let liveCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: liveRecordingURL,
            supportDirectory: supportDirectory
        )
        let missingCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: missingRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("live-cache".utf8).write(to: liveCacheURL)
        try Data("missing-cache".utf8).write(to: missingCacheURL)
        try FileManager.default.removeItem(at: missingRecordingURL)

        let result = RecordingWaveformCacheFiles.sweepOrphanedCachedWaveforms(
            retainedRecordingURLs: [liveRecordingURL, missingRecordingURL],
            supportDirectory: supportDirectory,
            logger: nil
        )

        #expect(result == .completed(removed: 1))
        #expect(FileManager.default.fileExists(atPath: liveCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: missingCacheURL.path) == false)
    }

    @Test("historical waveform cache cleanup runs only once")
    func historicalWaveformCacheCleanupRunsOnlyOnce() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let firstMissingRecordingURL = supportDirectory.appendingPathComponent("first-missing.m4a")
        try Data("first".utf8).write(to: firstMissingRecordingURL)
        let firstCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: firstMissingRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("first-cache".utf8).write(to: firstCacheURL)
        let firstLegacyJSONURL = firstCacheURL.deletingPathExtension().appendingPathExtension("json")
        try Data(#"{"peaks":[0.1],"duration":1.0}"#.utf8).write(to: firstLegacyJSONURL)
        try FileManager.default.removeItem(at: firstMissingRecordingURL)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.cleanupHistoricalMeetingWaveformCacheFilesIfNeeded()

        #expect(FileManager.default.fileExists(atPath: firstCacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: firstLegacyJSONURL.path) == false)
        #expect(configStore.load().waveformCacheOrphanCleanupMigrationApplied)

        let secondMissingRecordingURL = supportDirectory.appendingPathComponent("second-missing.m4a")
        try Data("second".utf8).write(to: secondMissingRecordingURL)
        let secondCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: secondMissingRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("second-cache".utf8).write(to: secondCacheURL)
        let secondLegacyJSONURL = secondCacheURL.deletingPathExtension().appendingPathExtension("json")
        try Data(#"{"peaks":[0.2],"duration":2.0}"#.utf8).write(to: secondLegacyJSONURL)
        try FileManager.default.removeItem(at: secondMissingRecordingURL)
        let nextLaunchController = makeController(dictationStore: store, configStore: configStore)

        nextLaunchController.cleanupHistoricalMeetingWaveformCacheFilesIfNeeded()

        #expect(FileManager.default.fileExists(atPath: secondCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: secondLegacyJSONURL.path))
    }

    @Test("deleteMeeting refuses live meeting rows")
    func deleteMeetingRefusesLiveRows() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        let liveMeeting = try #require(try store.meeting(id: meetingID))
        #expect(controller.canDeleteMeeting(liveMeeting) == false)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) != nil)
    }

    @Test("retranscribe missing recording preserves completed meeting status")
    func retranscribeMissingRecordingPreservesCompletedStatus() async throws {
        let store = try makeStore()
        let missingRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-meeting-recording-\(UUID().uuidString).wav")
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Existing transcript",
            formattedNotes: "## Existing notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: missingRecordingURL.path
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let meeting = try #require(try store.meeting(id: meetingID))

        let result = await withCheckedContinuation { continuation in
            controller.retranscribe(meeting: meeting) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            Issue.record("Expected re-transcription to fail when the retained recording is missing")
        case .failure(let error):
            #expect(error is MeetingRetranscriptionError)
        }

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.status == .completed)
        #expect(updated.rawTranscript == "Existing transcript")
        #expect(updated.formattedNotes == "## Existing notes")
    }

    @Test("retranscribe empty transcript restores original meeting status")
    func retranscribeEmptyTranscriptRestoresOriginalMeetingStatus() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .completed)
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .failed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .failed)
    }

    @Test("retranscribe status is unchanged before processing starts")
    func retranscribeStatusIsUnchangedBeforeProcessingStarts() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: false,
            error: MeetingRetranscriptionError.recordingUnavailable
        ) == nil)
    }

    @Test("retranscribe save failures restore original meeting status")
    func retranscribeSaveFailuresRestoreOriginalMeetingStatus() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.failedToSave(underlying: CocoaError(.fileWriteUnknown))
        ) == .completed)
    }

    @Test("retranscribe processing failures mark meeting failed")
    func retranscribeProcessingFailuresMarkMeetingFailed() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: CocoaError(.fileReadUnknown)
        ) == .failed)
    }

    @Test("cached manual notes are persisted before debounce")
    func cachedManualNotesPersistImmediately() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: meetingID, notes: "Decision before crash")

        let persisted = try #require(try store.meeting(id: meetingID))
        #expect(persisted.manualNotes == "Decision before crash")
    }

    @Test("failed manual note persistence retries on later flush")
    func failedManualNotePersistenceRetriesOnFlush() throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: 1, notes: "Draft survives retry")
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        #expect(meetingID == 1)

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)

        let stored = try #require(try store.meeting(id: meetingID))
        #expect(stored.manualNotes == "Draft survives retry")
    }

    @Test("manual note cache coalesces repeated writes until flush")
    func cachedManualNotesCoalesceRepeatedWrites() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: meetingID, notes: "First durable note")
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "First durable note"))
        controller.cacheMeetingManualNotes(id: meetingID, notes: "Second cached note")
        #expect(!controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let beforeFlush = try #require(try store.meeting(id: meetingID))
        #expect(beforeFlush.manualNotes == "First durable note")

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let afterFlush = try #require(try store.meeting(id: meetingID))
        #expect(afterFlush.manualNotes == "Second cached note")
    }

    @Test("persistCompletedMeetingResult keeps transcript when recording save fails")
    func persistCompletedMeetingResultPreservesMeetingOnRecordingFailure() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .always }

        let invalidRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let result = MeetingSessionResult(
            title: "Customer Review",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(90),
            durationSeconds: 90,
            rawTranscript: "Discussed roadmap and blockers.",
            formattedNotes: "## Summary\nRoadmap reviewed.",
            retainedRecordingURL: invalidRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            recordingSavePolicy: .always
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        #expect(persistenceResult.recordingSaveError != nil)
        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.title == "Customer Review")
        #expect(storedMeeting?.rawTranscript == "Discussed roadmap and blockers.")
        #expect(storedMeeting?.savedRecordingPath == nil)
    }

    @Test("persistCompletedMeetingResult honors prompt recording save decision")
    func persistCompletedMeetingResultHonorsPromptRecordingSaveDecision() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let retainedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retained-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data("recording".utf8).write(to: retainedRecordingURL)

        let result = MeetingSessionResult(
            title: "Prompt Decision",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Prompt decision transcript.",
            formattedNotes: "## Summary\nPrompt decision notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: false
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.rawTranscript == "Prompt decision transcript.")
        #expect(storedMeeting?.savedRecordingPath == nil)
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult honors explicit recording save decision after policy drift")
    func persistCompletedMeetingResultHonorsExplicitRecordingSaveDecisionAfterPolicyDrift() async throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let controller = makeController(
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        let artifactStore = try RecordingArtifactStore(
            databaseURL: store.resolvedDatabaseURL,
            recordingsRootURL: supportDirectory.appendingPathComponent("recordings", isDirectory: true),
            legacyMeetingRootURL: supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        )
        controller.updateConfig {
            $0.meetingRecordingSavePolicy = .never
            $0.meetingRecordingFileFormat = MeetingRecordingFileFormat.wav.rawValue
        }

        let retainedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retained-policy-drift-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data("recording".utf8).write(to: retainedRecordingURL)

        let result = MeetingSessionResult(
            title: "Policy Drift",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Policy drift transcript.",
            formattedNotes: "## Summary\nPolicy drift notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: true
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        let reference = try #require(try artifactStore.recordingForMeeting(id: storedMeeting.id))
        let artifactID = try #require(reference.artifactID)
        let savedRecordingURL = try artifactStore.playableURL(id: artifactID)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
        #expect(savedRecordingURL.path.hasPrefix(supportDirectory.path + "/recordings/"))
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult surfaces prompt policy retained recording failures without decision")
    func persistCompletedMeetingResultSurfacesPromptPolicyRetainedRecordingFailuresWithoutDecision() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let result = MeetingSessionResult(
            title: "Failed Retention",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Retention failure transcript.",
            formattedNotes: "## Summary\nRetention failure notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: CocoaError(.fileWriteUnknown),
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            recordingSavePolicy: .prompt
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(persistenceResult.recordingSaveError != nil)
    }

    @Test("persistCompletedMeetingResult surfaces retained recording failures after explicit save decision")
    func persistCompletedMeetingResultSurfacesRetainedRecordingFailuresAfterExplicitSaveDecision() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let result = MeetingSessionResult(
            title: "Explicit Save Failed Retention",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Explicit save retention failure transcript.",
            formattedNotes: "## Summary\nExplicit save retention failure notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: CocoaError(.fileWriteUnknown),
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: true
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(persistenceResult.recordingSaveError != nil)
    }

    @Test("persistCompletedMeetingResult preserves user-edited live meeting title")
    func persistCompletedMeetingResultPreservesEditedLiveTitle() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        try store.updateMeetingTitle(id: liveID, title: "Investor Follow-up")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed fundraising updates.",
            formattedNotes: "## Summary\nFundraising updates discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Investor Follow-up")
        #expect(storedMeeting.formattedNotes == "## Summary\nFundraising updates discussed.")
    }

    @Test("persistCompletedMeetingResult uses wall-clock duration for normal existing meetings")
    func persistCompletedMeetingResultUsesWallClockDurationForNormalExistingMeetings() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 30,
            rawTranscript: "Discussed regular completion.",
            formattedNotes: "## Summary\nRegular completion.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.durationSeconds == 120)
    }

    @Test("persistCompletedMeetingResult preserves cached live title before debounce")
    func persistCompletedMeetingResultPreservesCachedLiveTitle() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        controller.cacheMeetingTitle(id: liveID, title: "Status Bar Stop Title")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed follow-up items.",
            formattedNotes: "## Summary\nFollow-up items discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Status Bar Stop Title")
        #expect(storedMeeting.formattedNotes == "## Summary\nFollow-up items discussed.")
    }

    @Test("resummary context strips appended written notes section")
    func resummaryContextStripsWrittenNotesSection() {
        let meeting = makeMeeting(
            id: 909,
            title: "Resummarize",
            formattedNotes: "## Summary\n- Decision captured\n\n### Written notes\n\n- User typed this",
            status: .completed,
            manualNotes: "- User typed this"
        )

        let context = MuesliController.notesContextForResummary(meeting)

        #expect(context == "## Summary\n- Decision captured")
    }

    @Test("startup recovery preserves stale live meetings with notes")
    func startupRecoveryPreservesStaleLiveMeetingWithNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Crashed Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Important draft")
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
        #expect(meeting.manualNotes == "Important draft")
    }

    @Test("startup recovery marks empty stale live drafts as failed")
    func startupRecoveryMarksEmptyStaleLiveDraftsFailed() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Empty Draft", calendarEventID: nil, startTime: Date())
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
    }

    @Test("startup recovery uses live transcript checkpoints before failing stale meetings")
    func startupRecoveryUsesLiveTranscriptCheckpoints() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Checkpoint Draft", calendarEventID: nil, startTime: Date())
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "11:45:02", speaker: "Others", startSeconds: 2, endSeconds: 3, text: "The fallback transcript survived.")
        ])
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.notesState == .rawTranscriptFallback)
        #expect(meeting.rawTranscript == "[11:45:02] Others: The fallback transcript survived.")
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
    }

    @Test("showMeetingTemplatesManager preserves current meetings context and presents manager")
    func showMeetingTemplatesManagerPresentsManager() {
        let controller = makeController()

        controller.appState.selectedTab = .settings
        controller.appState.meetingsNavigationState = .document(404)
        controller.appState.isMeetingTemplatesManagerPresented = false

        controller.showMeetingTemplatesManager()

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.meetingsNavigationState == .document(404))
        #expect(controller.appState.isMeetingTemplatesManagerPresented == true)
    }

    @Test("deleteCustomMeetingTemplate resets default template when deleting the active default")
    func deletingDefaultCustomTemplateResetsDefaultToAuto() {
        let controller = makeController()
        let customTemplate = CustomMeetingTemplate(
            id: "tmpl_customer_followup",
            name: "Customer Follow-Up",
            prompt: "## Summary",
            icon: "person.2.fill"
        )

        controller.updateConfig {
            $0.customMeetingTemplates = [customTemplate]
            $0.defaultMeetingTemplateID = customTemplate.id
        }

        controller.deleteCustomMeetingTemplate(id: customTemplate.id)

        #expect(controller.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.appState.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.config.customMeetingTemplates.isEmpty)
    }

    @Test("meeting transcription backend selection is independent from dictation backend")
    func meetingTranscriptionBackendSelectionIsIndependent() {
        let controller = makeController()

        controller.selectBackend(.parakeetEnglish)
        controller.selectMeetingTranscriptionBackend(.whisperLargeTurbo, requireDownloaded: false)

        #expect(controller.appState.selectedBackend == .parakeetEnglish)
        #expect(controller.appState.selectedMeetingTranscriptionBackend == .whisperLargeTurbo)
        #expect(controller.appState.config.sttModel == BackendOption.parakeetEnglish.model)
        #expect(controller.appState.config.meetingTranscriptionModel == BackendOption.whisperLargeTurbo.model)
    }

    @Test("batch final selection survives enabling Nemotron live preview")
    func batchFinalSelectionSurvivesEnablingNemotronLivePreview() {
        let controller = makeController()

        controller.selectMeetingFinalTranscriptBackend(.whisperLargeTurbo, requireDownloaded: false)
        controller.updateConfig {
            $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue
            $0.enableLiveStreamingPartials = true
        }

        #expect(controller.appState.selectedMeetingTranscriptionBackend == .whisperLargeTurbo)
        #expect(controller.appState.config.useLiveMeetingTranscriptAsFinal == false)
        #expect(!controller.appState.config.usesUnifiedNemotronMeetingTranscript)
    }

    @Test("deleting the selected batch final falls back to live Nemotron")
    func deletingSelectedBatchFinalFallsBackToLiveNemotron() {
        let controller = makeController()

        controller.selectMeetingFinalTranscriptBackend(.whisperLargeTurbo, requireDownloaded: false)
        controller.updateConfig {
            $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue
            $0.enableLiveStreamingPartials = true
        }

        controller.refreshMeetingTranscriptionSelectionAfterDeleting(.whisperLargeTurbo)

        #expect(controller.appState.config.useLiveMeetingTranscriptAsFinal)
        #expect(controller.appState.config.usesUnifiedNemotronMeetingTranscript)
    }

    @Test("selecting Gemma dictation replaces conflicting Gemma cleanup")
    func selectingGemmaDictationReplacesGemmaCleanup() {
        let controller = makeController()
        controller.selectPostProcessorBackend(.gemma4LiteRT)

        #expect(controller.appState.selectedPostProcessorBackend == .gemma4LiteRT)

        controller.selectBackend(.gemma4E2BLiteRT)

        #expect(controller.appState.selectedBackend == .gemma4E2BLiteRT)
        #expect(controller.appState.selectedPostProcessorBackend == .local)
        #expect(controller.appState.config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
    }

    @Test("changing the meeting cleanup destination requires renewed consent")
    func changingMeetingCleanupDestinationRequiresRenewedConsent() {
        let controller = makeController()
        controller.selectPostProcessorBackend(.hosted(.ollama))
        controller.updateConfig { $0.ollamaURL = "http://localhost:11434" }
        controller.setMeetingTranscriptCleanupEnabled(true)

        #expect(controller.config.enableMeetingTranscriptCleanup)
        #expect(controller.config.meetingTranscriptCleanupConsentFingerprint != nil)

        controller.updateConfig { $0.ollamaURL = "http://192.168.1.50:11434" }

        #expect(controller.config.enableMeetingTranscriptCleanup == false)
        #expect(controller.config.meetingTranscriptCleanupConsentFingerprint == nil)

        controller.setMeetingTranscriptCleanupEnabled(true)

        #expect(controller.config.enableMeetingTranscriptCleanup)
        #expect(MeetingTranscriptCleanupPolicy.hasCurrentConsent(
            for: .hosted(.ollama),
            config: controller.config
        ))
    }

    @Test("changing the meeting cleanup backend requires renewed consent")
    func changingMeetingCleanupBackendRequiresRenewedConsent() {
        let controller = makeController()
        controller.selectPostProcessorBackend(.hosted(.ollama))
        controller.setMeetingTranscriptCleanupEnabled(true)

        controller.selectPostProcessorBackend(.hosted(.openAI))

        #expect(controller.config.enableMeetingTranscriptCleanup == false)
        #expect(controller.config.meetingTranscriptCleanupConsentFingerprint == nil)
    }

    @Test("changing cleanup destination cancels in-flight chunk uploads")
    func changingCleanupDestinationCancelsInFlightUploads() async throws {
        let (controller, meetingID, probe) = try makeInFlightCleanupController()
        controller.scheduleMeetingTranscriptCleanup(meetingID: meetingID)
        await waitForCleanupSend(probe)
        #expect(await probe.sendCount == 1)

        controller.updateConfig { $0.ollamaURL = "http://192.168.1.50:11434" }
        await waitForCleanupSend(probe, toFinish: true)

        #expect(controller.inFlightMeetingTranscriptCleanupCount == 0)
        #expect(await probe.sendCount == 1)
        #expect(await probe.finishedSendCount == 1)
        #expect(controller.config.enableMeetingTranscriptCleanup == false)
        #expect(controller.config.meetingTranscriptCleanupConsentFingerprint == nil)
    }

    @Test("disabling cleanup cancels in-flight chunk uploads")
    func disablingCleanupCancelsInFlightUploads() async throws {
        let (controller, meetingID, probe) = try makeInFlightCleanupController()
        controller.scheduleMeetingTranscriptCleanup(meetingID: meetingID)
        await waitForCleanupSend(probe)
        #expect(await probe.sendCount == 1)

        controller.setMeetingTranscriptCleanupEnabled(false)
        await waitForCleanupSend(probe, toFinish: true)

        #expect(controller.inFlightMeetingTranscriptCleanupCount == 0)
        #expect(await probe.sendCount == 1)
        #expect(await probe.finishedSendCount == 1)
        #expect(controller.config.enableMeetingTranscriptCleanup == false)
        #expect(controller.config.meetingTranscriptCleanupConsentFingerprint == nil)
    }

    @Test("startup repairs a persisted Gemma dictation and cleanup conflict")
    func startupRepairsPersistedGemmaConflict() {
        let configStore = ConfigStore(supportDirectory: makeSupportDirectory())
        var config = AppConfig()
        config.sttBackend = BackendOption.gemma4E2BLiteRT.backend
        config.sttModel = BackendOption.gemma4E2BLiteRT.model
        config.postProcessorBackend = TranscriptCleanupBackendOption.gemma4LiteRT.backend
        config.enablePostProcessor = true
        configStore.save(config)
        let persistedConfig = configStore.load()
        #expect(persistedConfig.sttBackend == BackendOption.gemma4E2BLiteRT.backend)
        #expect(persistedConfig.sttModel == BackendOption.gemma4E2BLiteRT.model)

        let controller = makeController(configStore: configStore)

        #expect(controller.selectedPostProcessorBackend == .local)
        #expect(controller.config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(!controller.config.enablePostProcessor)
        #expect(controller.selectedBackend == .gemma4E2BLiteRT)
    }

    @Test("updateConfig persists normalized meeting transcription backend")
    func updateConfigPersistsNormalizedMeetingTranscriptionBackend() {
        let controller = makeController()
        let originalConfig = controller.config
        defer {
            controller.updateConfig { config in
                config = originalConfig
            }
        }

        controller.updateConfig {
            $0.sttBackend = BackendOption.parakeetMultilingual.backend
            $0.sttModel = BackendOption.parakeetMultilingual.model
            $0.meetingTranscriptionBackend = BackendOption.nemotron35Multilingual.backend
            $0.meetingTranscriptionModel = BackendOption.nemotron35Multilingual.model
        }

        #expect(controller.appState.selectedMeetingTranscriptionBackend.supportsMeetingTranscription)
        #expect(controller.appState.config.meetingTranscriptionBackend != BackendOption.nemotron35Multilingual.backend)
        #expect(controller.appState.config.meetingTranscriptionModel != BackendOption.nemotron35Multilingual.model)
        #expect(controller.config.meetingTranscriptionBackend == controller.appState.selectedMeetingTranscriptionBackend.backend)
        #expect(controller.config.meetingTranscriptionModel == controller.appState.selectedMeetingTranscriptionBackend.model)
    }

    private func makeMeeting(
        id: Int64,
        title: String,
        formattedNotes: String = "## Summary",
        status: MeetingStatus = .completed,
        manualNotes: String = ""
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: "2026-03-24 10:00",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: formattedNotes,
            wordCount: 42,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }

    private func makeMeetingList(id: Int64, title: String) -> MeetingListRecord {
        MeetingListRecord(
            id: id,
            title: title,
            startTime: "2026-03-24 10:00",
            durationSeconds: 1800,
            folderID: nil,
            savedRecordingPath: nil,
            status: .completed,
            source: .meeting,
            followUpToID: nil,
            preview: "Summary"
        )
    }
}

private actor CancellableMeetingCleanupSenderProbe {
    private(set) var sendCount = 0
    private(set) var finishedSendCount = 0

    func send(_ payload: String) async throws -> TranscriptCleanupResult {
        sendCount += 1
        defer { finishedSendCount += 1 }
        if sendCount == 1 {
            try await Task.sleep(for: .seconds(30))
        }
        return TranscriptCleanupResult(
            rawOutput: payload,
            cleanedOutput: payload,
            model: "test"
        )
    }
}

@Suite("Meeting browser logic")
struct MeetingBrowserLogicTests {

    @Test("available filters expand with older meeting history")
    func availableFiltersExpandWithHistory() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 40, title: "Oldest"),
            makeMeeting(id: 2, daysAgo: 1, title: "Recent")
        ]

        let filters = MeetingBrowserLogic.availableFilters(for: meetings, now: now, calendar: calendar)

        #expect(filters == [.all, .last2Days, .lastWeek, .last2Weeks, .lastMonth, .last3Months])
    }

    @Test("filtering excludes invalid dates and sorts newest first")
    func filteringNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 10, title: "Too old"),
            makeMeeting(id: 2, daysAgo: 2, title: "Recent A"),
            makeMeeting(id: 3, daysAgo: 1, title: "Recent B"),
            makeMeeting(id: 4, rawDate: "not-a-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .lastWeek,
            sort: .newestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [3, 2])
    }

    @Test("all filter keeps invalid dates and oldest-first pushes them to the front")
    func allFilterOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 10, daysAgo: 2, title: "Recent"),
            makeMeeting(id: 11, daysAgo: 8, title: "Older"),
            makeMeeting(id: 12, rawDate: "invalid-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .all,
            sort: .oldestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [12, 11, 10])
    }

    @Test("formatStartTime converts UTC ISO timestamps to the requested timezone")
    func formatStartTimeConvertsUTC() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        guard let date = MeetingBrowserLogic.parseDate("2025-06-15T19:30:45Z") else {
            Issue.record("Expected ISO timestamp to parse")
            return
        }

        let formatted = MeetingBrowserLogic.formatStartTime(
            "2025-06-15T19:30:45Z",
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        #expect(components.year == 2025)
        #expect(components.month == 6)
        #expect(components.day == 15)
        #expect(components.hour == 12)
        #expect(components.minute == 30)
        #expect(formatted.contains("Jun 15, 2025"))
        #expect(formatted.contains("12:30"))
        #expect(formatted.localizedCaseInsensitiveContains("PM"))
    }

    private static func isoDate(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeMeeting(id: Int64, daysAgo: Int, title: String) -> MeetingListRecord {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        return makeMeeting(
            id: id,
            rawDate: Self.isoDate(daysAgo: daysAgo, now: now, calendar: calendar),
            title: title
        )
    }

    private func makeMeeting(id: Int64, rawDate: String, title: String) -> MeetingListRecord {
        MeetingListRecord(
            id: id,
            title: title,
            startTime: rawDate,
            durationSeconds: 1800,
            folderID: nil,
            savedRecordingPath: nil,
            status: .completed,
            source: .meeting,
            followUpToID: nil,
            preview: "Summary"
        )
    }
}

/// The resolver that decides which model produces a meeting's final transcript.
///
/// Its answer is persisted, so a wrong one does not merely mis-route a single meeting —
/// it overwrites the user's stored selection. These cover the streaming-only branch,
/// which is the one that bypasses `resolveDownloaded`'s no-rewrite rule and therefore
/// has to reimplement its download gating rather than skip it.
@MainActor
@Suite("Meeting transcription availability")
struct MeetingTranscriptionAvailabilityTests {

    private func config(meeting backend: BackendOption) -> AppConfig {
        var config = AppConfig()
        config.meetingTranscriptionBackend = backend.backend
        config.meetingTranscriptionModel = backend.model
        return config
    }

    @Test("a streaming-only selection is replaced by a downloaded meeting-capable model")
    func streamingOnlySelectionIsReplaced() throws {
        let resolved = try #require(MuesliController.availableMeetingTranscriptionBackend(
            config: config(meeting: .nemotron35Multilingual),
            dictationBackend: .nemotron35Multilingual,
            downloadedOptions: [.nemotron35Multilingual, .parakeetMultilingual]
        ))
        #expect(resolved.supportsMeetingTranscription)
        #expect(resolved == .parakeetMultilingual)
    }

    /// The regression this branch was fixed for: the dictation backend is meeting-capable
    /// but is not on disk, while a downloaded meeting-capable model is. Preferring the
    /// dictation backend here would persist a model that cannot run.
    @Test("an undownloaded dictation backend loses to a downloaded meeting model")
    func undownloadedDictationFallbackIsNotPreferred() throws {
        let resolved = try #require(MuesliController.availableMeetingTranscriptionBackend(
            config: config(meeting: .nemotron35Multilingual),
            dictationBackend: .whisperLargeTurbo,
            downloadedOptions: [.nemotron35Multilingual, .parakeetMultilingual]
        ))
        #expect(resolved == .parakeetMultilingual, "picked a model that is not downloaded")
    }

    @Test("a downloaded dictation backend is preferred over other meeting models")
    func downloadedDictationFallbackWins() throws {
        let resolved = try #require(MuesliController.availableMeetingTranscriptionBackend(
            config: config(meeting: .nemotron35Multilingual),
            dictationBackend: .whisperLargeTurbo,
            downloadedOptions: [.whisperLargeTurbo, .parakeetMultilingual]
        ))
        #expect(resolved == .whisperLargeTurbo)
    }

    /// Nothing meeting-capable is downloaded at all. Returning the streaming-only
    /// selection would be worse than returning nil: callers treat nil as "fall back to a
    /// known-good default", and that path only ever yields a meeting-capable option.
    @Test("no downloaded meeting model yields no resolution rather than a streaming one")
    func noMeetingCapableDownloadYieldsNil() {
        let resolved = MuesliController.availableMeetingTranscriptionBackend(
            config: config(meeting: .nemotron35Multilingual),
            dictationBackend: .nemotron35Multilingual,
            downloadedOptions: [.nemotron35Multilingual]
        )
        #expect(resolved?.supportsMeetingTranscription ?? true)
    }

    @Test("a meeting-capable selection is kept even when it is not downloaded")
    func capableSelectionSurvivesMissingDownload() throws {
        let resolved = try #require(MuesliController.availableMeetingTranscriptionBackend(
            config: config(meeting: .whisperLargeTurbo),
            dictationBackend: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual]
        ))
        #expect(resolved == .whisperLargeTurbo, "availability must not rewrite a capable choice")
    }
}
