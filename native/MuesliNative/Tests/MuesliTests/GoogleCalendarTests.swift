import Testing
import EventKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Google Calendar integration")
@MainActor
struct GoogleCalendarTests {

    // MARK: - Credentials parsing

    @Test("loads credentials from valid JSON")
    func loadsValidCredentials() throws {
        let json = """
        {"client_id": "test-id.apps.googleusercontent.com", "client_secret": "test-secret"}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-creds-\(UUID()).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let clientId = parsed["client_id"] as? String
        let clientSecret = parsed["client_secret"] as? String

        #expect(clientId == "test-id.apps.googleusercontent.com")
        #expect(clientSecret == "test-secret")
    }

    @Test("verified defaults to false when missing from JSON")
    func verifiedDefaultsFalse() throws {
        let json = """
        {"client_id": "id", "client_secret": "secret"}
        """
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let verified = parsed["verified"] as? Bool ?? false
        #expect(verified == false)
    }

    @Test("verified reads true from JSON")
    func verifiedReadsTrue() throws {
        let json = """
        {"client_id": "id", "client_secret": "secret", "verified": true}
        """
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let verified = parsed["verified"] as? Bool ?? false
        #expect(verified == true)
    }

    // MARK: - Authentication retry

    @Test("calendar list forces token refresh after a 401")
    func calendarListForcesTokenRefreshAfter401() async throws {
        let oldToken = "old-list-\(UUID().uuidString)"
        let newToken = "new-list-\(UUID().uuidString)"
        let auth = StubGoogleCalendarAuth(validToken: oldToken, refreshedToken: newToken)
        let recorder = GoogleCalendarRequestRecorder()

        GoogleCalendarURLProtocol.register(tokens: [oldToken, newToken]) { request in
            recorder.append(request)
            let statusCode = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldToken)"
                ? 401
                : 200
            let body = statusCode == 200
                ? #"{"items":[{"id":"primary","summary":"Primary","primary":true}]}"#.data(using: .utf8)!
                : Data()
            return try Self.response(statusCode: statusCode, request: request, body: body)
        }
        defer { GoogleCalendarURLProtocol.remove(tokens: [oldToken, newToken]) }

        let client = GoogleCalendarClient(auth: auth, session: Self.stubbedSession())
        let calendars = try await client.fetchCalendarList()

        #expect(calendars.map(\.id) == ["primary"])
        #expect(auth.validAccessTokenCallCount == 1)
        #expect(auth.forceRefreshAccessTokenCallCount == 1)
        #expect(recorder.authorizationHeaders == ["Bearer \(oldToken)", "Bearer \(newToken)"])
    }

    @Test("event fetch forces token refresh after a 401")
    func eventFetchForcesTokenRefreshAfter401() async throws {
        let oldToken = "old-events-\(UUID().uuidString)"
        let newToken = "new-events-\(UUID().uuidString)"
        let auth = StubGoogleCalendarAuth(validToken: oldToken, refreshedToken: newToken)
        let recorder = GoogleCalendarRequestRecorder()

        GoogleCalendarURLProtocol.register(tokens: [oldToken, newToken]) { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            if path.hasSuffix("/users/me/calendarList") {
                let body = #"{"items":[{"id":"primary","summary":"Primary","primary":true}]}"#.data(using: .utf8)!
                return try Self.response(statusCode: 200, request: request, body: body)
            }

            let statusCode = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldToken)"
                ? 401
                : 200
            let body = statusCode == 200
                ? #"{"items":[],"nextSyncToken":"sync-1"}"#.data(using: .utf8)!
                : Data()
            return try Self.response(statusCode: statusCode, request: request, body: body)
        }
        defer { GoogleCalendarURLProtocol.remove(tokens: [oldToken, newToken]) }

        let client = GoogleCalendarClient(auth: auth, session: Self.stubbedSession())
        let result = try await client.fetchUpcomingEvents(
            daysAhead: 1,
            now: date("2026-04-10T10:00:00Z")
        )

        #expect(result.events.isEmpty)
        #expect(result.wasComplete)
        #expect(auth.validAccessTokenCallCount == 2)
        #expect(auth.forceRefreshAccessTokenCallCount == 1)
        #expect(recorder.authorizationHeaders == [
            "Bearer \(oldToken)",
            "Bearer \(oldToken)",
            "Bearer \(newToken)",
        ])
    }

    // MARK: - Event JSON parsing

    @Test("parses timed event from Google Calendar API response")
    func parsesTimedEvent() {
        let item: [String: Any] = [
            "id": "event123",
            "summary": "Sprint Planning",
            "start": ["dateTime": "2026-04-10T14:00:00+05:30"],
            "end": ["dateTime": "2026-04-10T15:00:00+05:30"],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event != nil)
        #expect(event?.id == "event123")
        #expect(event?.title == "Sprint Planning")
        #expect(event?.isAllDay == false)
        #expect(event?.source == .googleCalendar)
    }

    @Test("does not import people from the unreleased direct Google integration")
    func directGoogleEventsDoNotCarryPeople() throws {
        let item: [String: Any] = [
            "id": "event-with-people",
            "summary": "Sprint Planning",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
            "organizer": [
                "email": "alice@example.test",
                "displayName": "Alice Example",
            ],
            "attendees": [
                ["email": "alice@example.test", "displayName": "Alice Example"],
                ["email": "bob@example.test", "displayName": "Bob Example"],
                ["email": "room@example.test", "displayName": "Conference Room", "resource": true],
            ],
        ]

        let event = try #require(GoogleCalendarClient().parseEvent(item, calendarID: "primary"))

        #expect(event.attendees.isEmpty)
    }

    @Test("parses all-day event from Google Calendar API response")
    func parsesAllDayEvent() {
        let item: [String: Any] = [
            "id": "allday1",
            "summary": "Company Holiday",
            "start": ["date": "2026-04-10"],
            "end": ["date": "2026-04-11"],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event != nil)
        #expect(event?.isAllDay == true)
        #expect(event?.title == "Company Holiday")
    }

    @Test("returns nil for event missing summary")
    func returnsNilMissingSummary() {
        let item: [String: Any] = [
            "id": "no-title",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]

        #expect(GoogleCalendarClient().parseEvent(item, calendarID: "primary") == nil)
    }

    @Test("returns nil for event missing id")
    func returnsNilMissingId() {
        let item: [String: Any] = [
            "summary": "Test",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]

        #expect(GoogleCalendarClient().parseEvent(item, calendarID: "primary") == nil)
    }

    // MARK: - Meeting URL extraction

    @Test("parses hangoutLink from Google Calendar event")
    func parsesHangoutLink() {
        let item: [String: Any] = [
            "id": "meet1",
            "summary": "Team Sync",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
            "hangoutLink": "https://meet.google.com/abc-defg-hij",
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.meetingURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("parses conferenceData video entryPoint from Google Calendar event")
    func parsesConferenceDataURL() {
        let item: [String: Any] = [
            "id": "zoom1",
            "summary": "Client Call",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
            "conferenceData": [
                "entryPoints": [
                    ["entryPointType": "video", "uri": "https://us02web.zoom.us/j/123456789"],
                ],
            ],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.meetingURL?.absoluteString == "https://us02web.zoom.us/j/123456789")
    }

    @Test("meetingURL is nil when no conference link present")
    func noMeetingURLWhenAbsent() {
        let item: [String: Any] = [
            "id": "plain1",
            "summary": "Lunch",
            "start": ["dateTime": "2026-04-10T12:00:00Z"],
            "end": ["dateTime": "2026-04-10T13:00:00Z"],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.meetingURL == nil)
    }

    @Test("CalendarMonitor extracts Zoom URL from text")
    func extractsZoomURL() {
        let url = CalendarMonitor.findMeetingURL(in: "Join at https://us02web.zoom.us/j/123456789?pwd=abc please")
        #expect(url?.host?.contains("zoom.us") == true)
    }

    @Test("CalendarMonitor extracts Google Meet URL from text")
    func extractsGoogleMeetURL() {
        let url = CalendarMonitor.findMeetingURL(in: "https://meet.google.com/abc-defg-hij")
        #expect(url?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("CalendarMonitor extracts Slack huddle URL from text")
    func extractsSlackHuddleURL() {
        let url = CalendarMonitor.findMeetingURL(in: "Join the standup huddle: https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU thanks")
        #expect(url?.absoluteString == "https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU")
    }

    @Test("CalendarMonitor returns nil for non-huddle Slack URL")
    func slackNonHuddleURLNotMatched() {
        let url = CalendarMonitor.findMeetingURL(in: "Open the channel: https://app.slack.com/client/T026CMCFV4H/C026SCN0LAU")
        #expect(url == nil)
    }

    @Test("MeetingPlatform.detect recognizes Slack huddle URL")
    func detectSlackHuddle() {
        let url = URL(string: "https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU")!
        #expect(MeetingPlatform.detect(from: url) == .slack)
    }

    @Test("MeetingPlatform.detect ignores non-huddle Slack URL")
    func detectSlackNonHuddleReturnsNil() {
        let url = URL(string: "https://app.slack.com/client/T026CMCFV4H/C026SCN0LAU")!
        #expect(MeetingPlatform.detect(from: url) == nil)
    }

    @Test("CalendarMonitor extracts huddle URL with query parameters")
    func extractsSlackHuddleURLWithQueryParams() {
        let url = CalendarMonitor.findMeetingURL(in: "Standup: https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU?x=1")
        #expect(url?.absoluteString == "https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU?x=1")
    }

    @Test("Google event picks up huddle URL from description")
    func googleEventHuddleFromDescription() throws {
        let item: [String: Any] = [
            "id": "huddle1",
            "summary": "Standup",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T14:30:00Z"],
            "description": "Join: https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU",
        ]
        let event = try #require(GoogleCalendarClient().parseEvent(item, calendarID: "primary"))
        #expect(event.meetingURL?.absoluteString == "https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU")
    }

    @Test("Google event picks up huddle URL from location")
    func googleEventHuddleFromLocation() throws {
        let item: [String: Any] = [
            "id": "huddle2",
            "summary": "Standup",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T14:30:00Z"],
            "location": "https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU",
        ]
        let event = try #require(GoogleCalendarClient().parseEvent(item, calendarID: "primary"))
        #expect(event.meetingURL?.absoluteString == "https://app.slack.com/huddle/T026CMCFV4H/D026SCN0LAU")
    }

    @Test("Google event ignores non-huddle Slack URL in description")
    func googleEventNonHuddleSlackIgnored() throws {
        let item: [String: Any] = [
            "id": "notmeeting1",
            "summary": "Async update",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T14:30:00Z"],
            "description": "Discuss in https://app.slack.com/client/T026CMCFV4H/C026SCN0LAU",
        ]
        let event = try #require(GoogleCalendarClient().parseEvent(item, calendarID: "primary"))
        #expect(event.meetingURL == nil)
    }

    @Test("CalendarMonitor returns nil for text without meeting URLs")
    func returnsNilForNonMeetingText() {
        let url = CalendarMonitor.findMeetingURL(in: "Conference room 3B on the second floor")
        #expect(url == nil)
    }

    // MARK: - EventKit occurrence identity

    @Test("EventKit one-off event identity survives rescheduling")
    func eventKitOneOffIdentitySurvivesRescheduling() {
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        let originalStart = date("2026-04-10T14:00:00Z")
        event.startDate = originalStart
        event.endDate = originalStart.addingTimeInterval(30 * 60)

        let originalReference = CalendarMonitor.occurrenceReference(
            for: event,
            eventID: "one-off-event",
            startDate: originalStart
        )

        let movedStart = originalStart.addingTimeInterval(90 * 60)
        event.startDate = movedStart
        event.endDate = movedStart.addingTimeInterval(30 * 60)
        let movedReference = CalendarMonitor.occurrenceReference(
            for: event,
            eventID: "one-off-event",
            startDate: movedStart
        )

        #expect(originalReference.seriesID == nil)
        #expect(movedReference.seriesID == nil)
        #expect(originalReference.identityKey == movedReference.identityKey)
    }

    @Test("EventKit recurrence uses the server-stable series identifier")
    func eventKitRecurrenceUsesExternalSeriesIdentifier() throws {
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        let start = date("2026-04-10T14:00:00Z")
        event.startDate = start
        event.endDate = start.addingTimeInterval(30 * 60)
        event.addRecurrenceRule(
            EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        )

        let externalIdentifier = try #require(event.calendarItemExternalIdentifier)
        let reference = CalendarMonitor.occurrenceReference(
            for: event,
            eventID: "store-local-event-id",
            startDate: start
        )

        #expect(reference.seriesID == externalIdentifier)
        #expect(reference.seriesID != reference.eventID)
        #expect(reference.originalStartTime == event.occurrenceDate)
    }

    // MARK: - Merge & dedup

    @Test("merges EventKit and Google events without duplicates")
    func mergesWithoutDuplicates() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Standup", startDate: date("2026-04-10T09:00:00Z"), endDate: date("2026-04-10T09:15:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Design Review", startDate: date("2026-04-10T10:00:00Z"), endDate: date("2026-04-10T11:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 2)
        #expect(merged[0].title == "Standup")
        #expect(merged[1].title == "Design Review")
    }

    @Test("deduplicates events with same title and close start time")
    func deduplicatesByTitleAndTime() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Sprint Planning", startDate: date("2026-04-10T14:00:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Sprint Planning", startDate: date("2026-04-10T14:02:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 1)
        #expect(merged[0].source == .eventKit)
    }

    @Test("keeps events with same title but different times")
    func keepsSameTitleDifferentTimes() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Standup", startDate: date("2026-04-10T09:00:00Z"), endDate: date("2026-04-10T09:15:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Standup", startDate: date("2026-04-11T09:00:00Z"), endDate: date("2026-04-11T09:15:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 2)
    }

    @Test("merged events are sorted by start date")
    func mergedSortedByStartDate() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Late", startDate: date("2026-04-10T16:00:00Z"), endDate: date("2026-04-10T17:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Early", startDate: date("2026-04-10T08:00:00Z"), endDate: date("2026-04-10T09:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged[0].title == "Early")
        #expect(merged[1].title == "Late")
    }

    // MARK: - Cached meeting detection event selection

    @Test("cached meeting detection ignores recently ended events")
    func cachedDetectionIgnoresRecentlyEndedEvents() {
        let now = date("2026-04-10T10:08:00Z")
        let events = [
            UnifiedCalendarEvent(id: "ended", title: "Already done", startDate: date("2026-04-10T09:50:00Z"), endDate: date("2026-04-10T10:00:00Z"), isAllDay: false, source: .eventKit),
        ]

        let selected = selectCurrentOrNearbyCachedCalendarEvent(from: events, now: now)
        #expect(selected == nil)
    }

    @Test("cached meeting detection prefers active over upcoming events")
    func cachedDetectionPrefersActiveEvent() {
        let now = date("2026-04-10T10:02:00Z")
        let events = [
            UnifiedCalendarEvent(id: "upcoming", title: "Next call", startDate: date("2026-04-10T10:04:00Z"), endDate: date("2026-04-10T10:30:00Z"), isAllDay: false, source: .googleCalendar),
            UnifiedCalendarEvent(id: "active", title: "Current call", startDate: date("2026-04-10T09:55:00Z"), endDate: date("2026-04-10T10:20:00Z"), isAllDay: false, source: .eventKit),
        ]

        let selected = selectCurrentOrNearbyCachedCalendarEvent(from: events, now: now)
        #expect(selected?.id == "active")
        #expect(selected?.title == "Current call")
    }

    @Test("cached meeting detection can select imminent future events")
    func cachedDetectionSelectsImminentFutureEvent() {
        let now = date("2026-04-10T10:00:00Z")
        let events = [
            UnifiedCalendarEvent(id: "later", title: "Later call", startDate: date("2026-04-10T10:20:00Z"), endDate: date("2026-04-10T11:00:00Z"), isAllDay: false, source: .eventKit),
            UnifiedCalendarEvent(id: "soon", title: "Soon call", startDate: date("2026-04-10T10:03:00Z"), endDate: date("2026-04-10T10:30:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let selected = selectCurrentOrNearbyCachedCalendarEvent(from: events, now: now)
        #expect(selected?.id == "soon")
        #expect(selected?.title == "Soon call")
    }

    // MARK: - parseCalendarListEntry

    @Test("parses a calendarList entry with summary, primary flag, and color")
    func parsesCalendarListEntry() {
        let entry: [String: Any] = [
            "id": "primary",
            "summary": "spencer@dockstreet.com",
            "primary": true,
            "backgroundColor": "#9fe1e7",
        ]
        let summary = GoogleCalendarClient.parseCalendarListEntry(entry)
        #expect(summary?.id == "primary")
        #expect(summary?.summary == "spencer@dockstreet.com")
        #expect(summary?.isPrimary == true)
        #expect(summary?.colorHex == "9fe1e7")
    }

    @Test("calendarList entry prefers summaryOverride when present")
    func calendarListPrefersOverride() {
        let entry: [String: Any] = [
            "id": "team@dockstreet.com",
            "summary": "team@dockstreet.com",
            "summaryOverride": "Team Standup",
        ]
        let summary = GoogleCalendarClient.parseCalendarListEntry(entry)
        #expect(summary?.summary == "Team Standup")
        #expect(summary?.isPrimary == false)
    }

    @Test("calendarList entry returns nil when id missing")
    func calendarListNilWithoutID() {
        let entry: [String: Any] = ["summary": "no id"]
        #expect(GoogleCalendarClient.parseCalendarListEntry(entry) == nil)
    }

    @Test("parsed event records the calendarID")
    func parsedEventCarriesCalendarID() {
        let item: [String: Any] = [
            "id": "ev1",
            "summary": "Sync",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]
        let event = GoogleCalendarClient().parseEvent(item, calendarID: "team@dockstreet.com")
        #expect(event?.calendarID == "team@dockstreet.com")
    }

    @Test("parsed recurring event keeps its immutable occurrence identity")
    func parsedRecurringEventCarriesOriginalStartTime() throws {
        let item: [String: Any] = [
            "id": "series_20260410T140000Z",
            "recurringEventId": "series",
            "summary": "Daily sync",
            "originalStartTime": ["dateTime": "2026-04-10T14:00:00Z"],
            "start": ["dateTime": "2026-04-10T15:30:00Z"],
            "end": ["dateTime": "2026-04-10T16:00:00Z"],
        ]

        let event = try #require(
            GoogleCalendarClient().parseEvent(item, calendarID: "team@dockstreet.com")
        )
        let occurrence = try #require(event.calendarOccurrence)

        #expect(occurrence.provider == .googleCalendar)
        #expect(occurrence.calendarID == "team@dockstreet.com")
        #expect(occurrence.eventID == "series_20260410T140000Z")
        #expect(occurrence.seriesID == "series")
        #expect(occurrence.originalStartTime == date("2026-04-10T14:00:00Z"))
        #expect(event.startDate == date("2026-04-10T15:30:00Z"))
    }

    @Test("calendar placeholders reconcile before start, preserve removals, and allow the next recurrence")
    func calendarPlaceholderOccurrenceDeduplication() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-calendar-occurrence-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let firstStart = date("2026-04-10T14:00:00Z")
        let firstOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "work",
            eventID: "shared-series-id",
            seriesID: "shared-series-id",
            originalStartTime: firstStart
        )
        let attendee = try #require(CalendarAttendee(
            identifier: "alice@example.test",
            displayName: "Alice Example",
            emailAddress: "alice@example.test"
        ))
        let firstEvent = UnifiedCalendarEvent(
            id: "shared-series-id",
            title: "Daily sync",
            startDate: firstStart,
            endDate: firstStart.addingTimeInterval(30 * 60),
            isAllDay: false,
            source: .eventKit,
            calendarID: "work",
            calendarOccurrence: firstOccurrence,
            attendees: [attendee]
        )
        controller.createMeetingFromCalendarEvent(firstEvent, folderID: nil)
        controller.createMeetingFromCalendarEvent(firstEvent, folderID: nil)

        let nextStart = firstStart.addingTimeInterval(24 * 60 * 60)
        let nextOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "work",
            eventID: "shared-series-id",
            seriesID: "shared-series-id",
            originalStartTime: nextStart
        )
        let nextEvent = UnifiedCalendarEvent(
            id: "shared-series-id",
            title: "Daily sync",
            startDate: nextStart,
            endDate: nextStart.addingTimeInterval(30 * 60),
            isAllDay: false,
            source: .eventKit,
            calendarID: "work",
            calendarOccurrence: nextOccurrence
        )
        controller.createMeetingFromCalendarEvent(nextEvent, folderID: nil)

        let meetings = try store.recentMeetings(limit: 10)
        #expect(meetings.count == 2)
        #expect(Set(meetings.compactMap(\.calendarOccurrence?.identityKey)) == Set([
            firstOccurrence.identityKey,
            nextOccurrence.identityKey,
        ]))
        let firstMeeting = try #require(meetings.first(where: {
            $0.calendarOccurrence?.identityKey == firstOccurrence.identityKey
        }))
        let firstMeetingParticipants = try await controller.meetingParticipants(meetingID: firstMeeting.id)
        #expect(firstMeetingParticipants.map(\.displayName) == [
            "Alice Example",
        ])

        let participant = try #require(firstMeetingParticipants.first)
        try await controller.removeMeetingParticipant(
            meetingID: firstMeeting.id,
            participantIdentifier: participant.participantIdentifier
        )
        let folderID = try store.createFolder(name: "Filed calendar meetings")
        controller.createMeetingFromCalendarEvent(firstEvent, folderID: folderID)

        #expect(try await controller.meetingParticipants(meetingID: firstMeeting.id).isEmpty)
        #expect(try store.meeting(id: firstMeeting.id)?.folderID == folderID)

        let bob = try #require(CalendarAttendee(
            identifier: "bob@example.test",
            displayName: "Bob Example",
            emailAddress: "bob@example.test"
        ))
        let refreshedEvent = UnifiedCalendarEvent(
            id: firstEvent.id,
            title: firstEvent.title,
            startDate: firstEvent.startDate,
            endDate: firstEvent.endDate,
            isAllDay: false,
            source: .eventKit,
            calendarID: firstEvent.calendarID,
            calendarOccurrence: firstOccurrence,
            attendees: [attendee, bob]
        )
        await controller.reconcilePendingEventKitCalendarAttendees(
            events: [refreshedEvent],
            now: firstStart.addingTimeInterval(-60)
        )
        #expect(try await controller.meetingParticipants(meetingID: firstMeeting.id).map(\.displayName) == [
            "Bob Example",
        ])

        let carol = try #require(CalendarAttendee(
            identifier: "carol@example.test",
            displayName: "Carol Example",
            emailAddress: "carol@example.test"
        ))
        var afterStartEvent = refreshedEvent
        afterStartEvent.attendees = [carol]
        await controller.reconcilePendingEventKitCalendarAttendees(
            events: [afterStartEvent],
            now: firstStart
        )
        #expect(try await controller.meetingParticipants(meetingID: firstMeeting.id).map(\.displayName) == [
            "Bob Example",
        ])
    }

    @Test("event sync cache resets when upcoming window changes")
    func eventSyncCacheResetsWhenWindowChanges() {
        let client = GoogleCalendarClient()

        #expect(client.resetEventSyncIfNeededForWindow(daysAhead: 1))
        #expect(!client.resetEventSyncIfNeededForWindow(daysAhead: 1))
        #expect(client.resetEventSyncIfNeededForWindow(daysAhead: 3))

        client.resetSync()
        #expect(client.resetEventSyncIfNeededForWindow(daysAhead: 3))
    }

    @Test("event sync cache resets when upcoming window advances to a new local day")
    func eventSyncCacheResetsWhenWindowDayChanges() {
        let client = GoogleCalendarClient()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        #expect(client.resetEventSyncIfNeededForWindow(
            daysAhead: 3,
            now: date("2026-04-10T21:00:00Z"),
            calendar: calendar
        ))
        #expect(!client.resetEventSyncIfNeededForWindow(
            daysAhead: 3,
            now: date("2026-04-10T23:00:00Z"),
            calendar: calendar
        ))
        #expect(client.resetEventSyncIfNeededForWindow(
            daysAhead: 3,
            now: date("2026-04-11T00:01:00Z"),
            calendar: calendar
        ))
    }

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleCalendarURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static func response(
        statusCode: Int,
        request: URLRequest,
        body: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, body)
    }

}

@MainActor
private final class StubGoogleCalendarAuth: GoogleCalendarAuthenticating {
    private let validToken: String
    private let refreshedToken: String

    private(set) var validAccessTokenCallCount = 0
    private(set) var forceRefreshAccessTokenCallCount = 0

    init(validToken: String, refreshedToken: String) {
        self.validToken = validToken
        self.refreshedToken = refreshedToken
    }

    func validAccessToken() async throws -> String {
        validAccessTokenCallCount += 1
        return validToken
    }

    func forceRefreshAccessToken() async throws -> String {
        forceRefreshAccessTokenCallCount += 1
        return refreshedToken
    }
}

private final class GoogleCalendarRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var authorizationHeaders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
    }
}

private final class GoogleCalendarURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let registry = HandlerRegistry()

    static func register(tokens: [String], handler: @escaping Handler) {
        registry.register(tokens: tokens, handler: handler)
    }

    static func remove(tokens: [String]) {
        registry.remove(tokens: tokens)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let authorization = request.value(forHTTPHeaderField: "Authorization"),
            authorization.hasPrefix("Bearer "),
            let handler = Self.registry.handler(for: String(authorization.dropFirst("Bearer ".count)))
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private final class HandlerRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]

        func register(tokens: [String], handler: @escaping Handler) {
            lock.lock()
            for token in tokens {
                handlers[token] = handler
            }
            lock.unlock()
        }

        func remove(tokens: [String]) {
            lock.lock()
            for token in tokens {
                handlers.removeValue(forKey: token)
            }
            lock.unlock()
        }

        func handler(for token: String) -> Handler? {
            lock.lock()
            defer { lock.unlock() }
            return handlers[token]
        }
    }
}
