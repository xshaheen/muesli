import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting transcript cleanup")
struct MeetingTranscriptCleanupTests {

    private let diarized = """
    [10:00:00] Speaker 1: احنا محتاجين نعمل البرايمريكية على الجدول ده
    [10:00:12] Speaker 2: تمام وبعدين نعمل بلود اس ثري للملفات
    [10:00:25] Speaker 1: والعلاقة هتبقى وأنتو مين
    """

    private let resumed = """
    [09:00:00] Speaker 1: before the break

    — Resumed —

    [10:00:00] Speaker 1: after the break
    """

    /// A single line past the chunk budget, so it has to be split on its sentence
    /// boundaries -- the path where the spacing between sentences lives in the
    /// joiner rather than in any unit's text.
    private let overflowing = String(repeating: "First sentence. Second sentence. ", count: 80)
        + "Fix البرايمريكية here."

    /// Echoes each unit back unchanged, which is what a perfectly behaved model
    /// would do for text that needed no repair.
    private func echoSender(truncated: Bool = false) -> (String) async throws -> TranscriptCleanupResult {
        { payload in
            TranscriptCleanupResult(
                rawOutput: payload,
                cleanedOutput: payload,
                model: "test",
                wasTruncated: truncated
            )
        }
    }

    private func sender(
        transform: @escaping ([String]) -> String
    ) -> (String) async throws -> TranscriptCleanupResult {
        { payload in
            let lines = payload.components(separatedBy: "\n")
            let output = transform(lines)
            return TranscriptCleanupResult(rawOutput: output, cleanedOutput: output, model: "test")
        }
    }

    // MARK: - Splitting and reassembly

    @Test("reassembling untouched units reproduces the input exactly")
    func reassemblyIsLossless() {
        // Everything else rests on this: if the round trip is not an identity, a
        // "successful" cleanup silently reshapes the transcript.
        for transcript in [diarized, resumed, "one long unprefixed block of speech", overflowing] {
            let units = MeetingTranscriptChunker.units(in: transcript, budget: 2_400)
            #expect(MeetingTranscriptChunker.reassemble(units) == transcript)
        }
    }

    @Test("a line that fits the budget is never split")
    func linesStayWholeWhenTheyFit() {
        let units = MeetingTranscriptChunker.units(in: diarized, budget: 2_400)

        #expect(units.count == 3)
        #expect(units.allSatisfy { $0.text.hasPrefix("[") })
    }

    @Test("an oversized unprefixed block is split rather than skipped or sent whole")
    func oversizedLineIsSplit() {
        // An import whose diarization was unavailable arrives as one long line.
        // "Never split within a line" is unsatisfiable there.
        let block = String(repeating: "كلمة ", count: 400)
        let units = MeetingTranscriptChunker.units(in: block, budget: 200)

        #expect(units.count > 1)
        #expect(units.allSatisfy { $0.text.count <= 200 })
        #expect(MeetingTranscriptChunker.reassemble(units) == block)
    }

    @Test("unpunctuated text falls back to whitespace splitting")
    func unpunctuatedTextSplitsOnWhitespace() {
        // ASR output routinely has no sentence punctuation to split on.
        let block = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let units = MeetingTranscriptChunker.units(in: block, budget: 120)

        #expect(units.count > 1)
        #expect(units.allSatisfy { $0.text.count <= 120 })
        #expect(MeetingTranscriptChunker.reassemble(units) == block)
    }

    @Test("a single token longer than the budget never splits mid-grapheme")
    func oversizedTokenSplitsOnGraphemeBoundaries() {
        // Arabic combining marks must stay attached to their base letter, or the
        // text is corrupted before the model ever sees it.
        let token = String(repeating: "بً", count: 100)
        let units = MeetingTranscriptChunker.units(in: token, budget: 30)

        #expect(units.count > 1)
        #expect(MeetingTranscriptChunker.reassemble(units) == token)
    }

    @Test("blank lines and the resume separator are kept as structure")
    func resumeSeparatorIsStructural() {
        let units = MeetingTranscriptChunker.units(in: resumed, budget: 2_400)
        let structural = units.filter { !$0.isRewritable }

        // Two blank lines flanking the separator, plus the separator itself.
        #expect(structural.count == 3)
        #expect(structural.contains { $0.text.contains("Resumed") })
    }

    // MARK: - Happy path

    @Test("a clean round trip stores repaired text")
    func repairedTextIsReturned() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: sender { lines in
                lines.map { $0.replacingOccurrences(of: "البرايمريكية", with: "primary key") }
                    .joined(separator: "\n")
            }
        )

        let result = try? #require(cleaned)
        #expect(result?.contains("primary key") == true)
        #expect(result?.contains("[10:00:00] Speaker 1:") == true)
    }

    @Test("a resumed meeting is cleaned rather than rejected wholesale")
    func resumedMeetingCleans() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: resumed,
            send: sender { lines in
                lines.map { $0.replacingOccurrences(of: "after the break", with: "after the break.") }
                    .joined(separator: "\n")
            }
        )

        #expect(cleaned?.contains("— Resumed —") == true)
        #expect(cleaned?.contains("after the break.") == true)
    }

    @Test("an unprefixed import is cleaned, not treated as unmodifiable")
    func unprefixedImportCleans() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: "احنا عايزين نعمل البرايمريكية دلوقتي علشان الجدول يبقى مظبوط",
            send: sender { lines in
                lines.map { $0.replacingOccurrences(of: "البرايمريكية", with: "primary key") }
                    .joined(separator: "\n")
            }
        )

        #expect(cleaned?.contains("primary key") == true)
    }

    @Test("a split line keeps the spaces between its sentences")
    func splitLineKeepsSentenceSpacing() async {
        // Every unit is trimmed on the way back -- by the model, and again by the
        // parser. Any spacing held inside a unit's text is therefore spacing that
        // does not return, which would close up every sentence boundary of a line
        // long enough to be split.
        #expect(overflowing.count > MeetingTranscriptCleanup.chunkBudget)
        let expected = overflowing.replacingOccurrences(of: "البرايمريكية", with: "primary key")

        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: overflowing,
            send: sender { lines in
                lines.map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "البرايمريكية", with: "primary key")
                }.joined(separator: "\n")
            }
        )

        #expect(cleaned == expected)
    }

    // MARK: - Rejection

    @Test("a provider that hit its output cap is rejected")
    func truncatedResponseRejected() async {
        // The one failure structural checks cannot see: unit count, markers, and
        // prefixes all survive a cap hit part-way through the final sentence.
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: echoSender(truncated: true)
        )

        #expect(cleaned == nil)
    }

    @Test("a dropped line is rejected even when the response looks plausible")
    func droppedUnitRejected() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: sender { lines in
                // Drop the final marker and its text.
                lines.dropLast(2).joined(separator: "\n")
            }
        )

        #expect(cleaned == nil)
    }

    @Test("merging two units into one is rejected")
    func mergedUnitsRejected() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: sender { lines in
                lines.filter { $0 != MeetingTranscriptCleanupPrompt.marker(for: 1) }
                    .joined(separator: "\n")
            }
        )

        #expect(cleaned == nil)
    }

    @Test("changing a timestamp or speaker label is rejected")
    func alteredPrefixRejected() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: sender { lines in
                lines.map { $0.replacingOccurrences(of: "[10:00:12] Speaker 2:", with: "[10:00:12] Ahmed:") }
                    .joined(separator: "\n")
            }
        )

        #expect(cleaned == nil)
    }

    @Test("rewriting the resume separator is rejected")
    func alteredSeparatorRejected() async {
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: resumed,
            send: sender { lines in
                lines.map { $0.replacingOccurrences(of: "— Resumed —", with: "-- resumed --") }
                    .joined(separator: "\n")
            }
        )

        #expect(cleaned == nil)
    }

    @Test("a unit that comes back as a fragment is rejected")
    func contractedUnitRejected() async {
        // A model can stop after the first clause, keep the prefix, keep the marker,
        // and report a clean finish. Only the length floor catches it.
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: sender { lines in
                lines.map { line in
                    line.hasPrefix("[10:00:00]") ? "[10:00:00] Speaker 1: احنا" : line
                }.joined(separator: "\n")
            }
        )

        #expect(cleaned == nil)
    }

    @Test("legitimate repair that lengthens a unit is accepted")
    func expandedUnitAccepted() async {
        // Arabic phonetic spelling becoming an English term is longer, not shorter.
        // A floor that rejected growth would reject the entire point of the feature.
        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: diarized,
            send: sender { lines in
                lines.map {
                    $0.replacingOccurrences(of: "بلود اس ثري", with: "upload to Amazon S3 storage")
                }.joined(separator: "\n")
            }
        )

        #expect(cleaned?.contains("upload to Amazon S3 storage") == true)
    }

    @Test("a failure in the last chunk discards the earlier good ones")
    func lastChunkFailureDiscardsEverything() async {
        // A transcript repaired up to the failure point and raw after it reads as
        // correct, which is exactly why it must not be stored.
        let long = (0..<40).map { "[10:\(String(format: "%02d", $0)):00] Speaker 1: " + String(repeating: "كلمة ", count: 40) }
            .joined(separator: "\n")
        var call = 0
        let cleaned = await MeetingTranscriptCleanup.clean(transcript: long) { payload in
            call += 1
            if call > 1 {
                throw TranscriptCleanupError.emptyResponse("test")
            }
            return TranscriptCleanupResult(rawOutput: payload, cleanedOutput: payload, model: "test")
        }

        #expect(call > 1, "the transcript should span more than one chunk")
        #expect(cleaned == nil)
    }

    @Test("revoked authorization prevents subsequent chunk sends")
    func revokedAuthorizationStopsChunking() async {
        let transcript = (0..<40).map {
            "[10:\(String(format: "%02d", $0)):00] Speaker 1: "
                + String(repeating: "word ", count: 40)
        }.joined(separator: "\n")
        let probe = MeetingCleanupAuthorizationProbe()

        let cleaned = await MeetingTranscriptCleanup.clean(
            transcript: transcript,
            isAuthorized: { await probe.isAuthorized },
            send: { payload in await probe.sendAndRevoke(payload) }
        )

        #expect(await probe.sendCount == 1)
        #expect(cleaned == nil)
    }

    @Test("a throwing backend yields nothing rather than propagating")
    func throwingBackendYieldsNil() async {
        let cleaned = await MeetingTranscriptCleanup.clean(transcript: diarized) { _ in
            throw TranscriptCleanupError.missingConfiguration("no backend")
        }

        #expect(cleaned == nil)
    }

    @Test("an empty response is not a cleaned transcript")
    func emptyResponseRejected() async {
        let cleaned = await MeetingTranscriptCleanup.clean(transcript: diarized) { _ in
            TranscriptCleanupResult(rawOutput: "", cleanedOutput: "", model: "test")
        }

        #expect(cleaned == nil)
    }

    @Test("an empty transcript is never sent anywhere")
    func emptyTranscriptSkipped() async {
        var called = false
        let cleaned = await MeetingTranscriptCleanup.clean(transcript: "   \n  ") { _ in
            called = true
            return TranscriptCleanupResult(rawOutput: "", cleanedOutput: "", model: "test")
        }

        #expect(called == false)
        #expect(cleaned == nil)
    }

    // MARK: - Gating

    private func bilingualConfig() throws -> AppConfig {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .english]
        )
        return config
    }

    @Test("cleanup is skipped for a monolingual meeting selection")
    func monolingualSelectionSkipsCleanup() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.english])
        config.openAIAPIKey = "sk-test"
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend

        #expect(MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: MeetingCleanupTransport.backend(for: config),
            isChatGPTAuthenticated: false
        ) == false)
    }

    @Test("cleanup runs for a bilingual selection on a configured summary backend")
    func bilingualSelectionEnablesCleanup() throws {
        var config = try bilingualConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = "sk-test"

        #expect(MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: MeetingCleanupTransport.backend(for: config),
            isChatGPTAuthenticated: false
        ))
    }

    @Test("cleanup is skipped for the on-device post-processors")
    func ineligibleBackendSkipsCleanup() throws {
        let config = try bilingualConfig()

        #expect(MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: .local,
            isChatGPTAuthenticated: false
        ) == false)
    }

    @Test("cleanup is skipped when the summary backend has no credentials")
    func unconfiguredBackendSkipsCleanup() throws {
        var config = try bilingualConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = ""

        let enabled = MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: MeetingCleanupTransport.backend(for: config),
            isChatGPTAuthenticated: false
        )

        #expect(enabled == (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil))
    }

    @Test("cleanup follows the summary backend, not the dictation post-processor")
    func gateFollowsSummaryBackend() throws {
        var config = try bilingualConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend
        // The dictation post-processor stays on-device; it must not decide meetings.
        config.postProcessorBackend = TranscriptCleanupBackendOption.local.backend

        #expect(MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: MeetingCleanupTransport.backend(for: config),
            isChatGPTAuthenticated: true
        ))
    }
}

private actor MeetingCleanupAuthorizationProbe {
    private var authorized = true
    private(set) var sendCount = 0

    var isAuthorized: Bool { authorized }

    func sendAndRevoke(_ payload: String) -> TranscriptCleanupResult {
        sendCount += 1
        authorized = false
        return TranscriptCleanupResult(
            rawOutput: payload,
            cleanedOutput: payload,
            model: "test"
        )
    }
}
