#!/usr/bin/env bash
set -euo pipefail

list_filters=false
if [[ "${1:-}" == "--list-filters" ]]; then
  list_filters=true
  shard="${2:-}"
else
  shard="${1:-}"
fi

if [[ -z "${shard}" ]]; then
  echo "usage: $0 [--list-filters] <core|dictation-transcription|meetings>" >&2
  exit 2
fi

case "${shard}" in
  core)
    filters=(
      ConfigStoreTests
      LanguageProfileSettingsModelTests
      LanguageProfileTests
      LanguageSelectionPresentationTests
      FluidAudioUpgradeCharacterizationTests
      MeetingTranscriptionAvailabilityTests
      TranscriptionQualityUpgradeComparisonTests
      TranscriptionLanguageRoutingTests
      DictationStoreTests
      SessionTraceStoreTests
      RecordingArtifactStoreTests
      RecordingArtifactPlaybackTests
      LocalDiagnosticsTests
      SessionDiagnosticsPresentationTests
      MuesliCKSyncEngineTests
      MuesliCLITests
      ChatGPTAuthTests
      ChatGPTTokenStorageTests
      ComputerUseCursorOverlayTests
      FloatingMeetingPanelStyleTests
      DictationMiniPlacementTests
      OpenAILogoShapeTests
      MeetingChunkCollectorTests
      AppConfigTests
      DictationStyleResolverTests
      DictationStyleSettingsTests
      DictationStyleRulesetCodecTests
      CGPointCodableTests
      UpdateFailureGuidanceTests
      SidebarHitAreaTests
      WordCountTests
      ChatGPTResponsesMessagesTests
      ChatGPTResponsesTruncationTests
      FloatingIndicatorStyleTests
      LegacyIndicatorConfigurationTests
      FloatingMeetingChatTests
      MarkdownRichTextEditorTests
      CustomWordDictionaryTests
      ModelDownloadCoordinatorTests
      IndicASRBackendTests
    )
    ;;
  dictation-transcription)
    filters=(
      FluidAudioTranscriberTests
      BackendCoverageTests
      FillerWordFilterTests
      JaroWinklerTests
      CustomWordMatcherApplyTests
      StreamingDictationControllerTests
      DeltaPasteTests
      TranscriptAccumulationTests
      StreamingDictationControllerLifecycleTests
      NemotronDictationModePolicyTests
      Nemotron35StreamStateTests
      Nemotron35BackendMetadataTests
      Nemotron35LanguageTests
      WhisperKitLanguageTests
      SpeechSegmentTests
      SpeechTranscriptionResultTests
      TranscriptionCoordinatorTests
      TranscriptionEngineArtifactsFilterTests
      DiarizerRuntimePolicyTests
      DiarizerPreloadDiagnosticsTests
      DiarizerPreloadCoordinationTests
      PasteControllerTests
      BackendOptionTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      InteractiveAudioSessionOwnershipTests
      DictationStateTests
      HotkeyConfigTests
      DictationStateIdleTests
      DictationCorrectionMonitorTests
      DictationLifecycleFeedbackTests
      DictationMiniIndicatorTests
      DictationTerminalFeedbackEligibilityTests
      DictationStyleSessionTests
      AsrVocabularyPromptTests
      WhisperBiasingManualReproTests
      TranscriptionResultCleanupTests
      DictationTranscriptionStageDiagnosticsTests
      DictationCleanupPolicyTests
      DictationStyleObservabilityTests
      TranscriptionBackendResidencyPolicyTests
      TranscriptCleanupRequestBodyTests
      PostProcessorIdleUnloadPolicyTests
      ModelDeletionExecutorTests
      Nemotron35ModelStoreTests
      HostedDictationCleanupDeadlineTests
      OrderedDictationJobQueueTests
      SessionTraceRuntimeTests
      SessionTracePerformanceTests
      TranscriptionQualityFixtureContractTests
      TranscriptionQualityScoringTests
      TranscriptionCorpusStoreTests
      TranscriptionQualityRunnerTests
      TranscriptionQualityHarnessTests
      TranscriptionQualityDecisionTests
      TranscriptionQualityReceiptTests
      TranscriptionQualityRunFixtureContractTests
    )
    ;;
  meetings)
    filters=(
      AudioGraphExceptionBridgeTests
      DiagnosticIncidentTests
      DiagnosticIncidentReporterTests
      DictationAudioRouteControllerTests
      MeetingDetectorTests
      MeetingActivityDetectionPolicyTests
      MeetingRecordingWriterTests
      MeetingRecordingElapsedClockTests
      MeetingRecordButtonTests
      MeetingPanelBodyCoordinatorTests
      MeetingRecordingPanelGeometryTests
      MeetingRecordingPanelLifecycleTests
      MeetingResumePolicyTests
      MeetingSessionDiagnosticsTests
      MeetingStreamingPartialSessionTests
      MeetingFollowUpPolicyTests
      MeetingFollowUpThreadTests
      MeetingFollowUpSummaryPromptTests
      MeetingSummaryClientTests
      MeetingsNavigationTests
      MeetingDetailResponsiveLayoutTests
      MeetingDurationLimitTests
      MeetingFallbackClassificationTests
      MeetingFinalizationRollbackTests
      MeetingRawTranscriptAccumulatorTests
      MeetingTextInteractionTests
      MeetingBrowserLogicTests
      MeetingNotesInlineMarkdownTests
      TranscriptFormatterTests
      MeetingSummaryBackendTests
      MeetingResummarizationPolicyTests
      MeetingTemplateResolutionTests
      MeetingTemplatesDefaultFallbackTests
      RouteAwareMeetingMicRecorderTests
      StreamingMicRecorderConfigChangeTests
      SystemAudioRecorderTests
      MeetingMicFailoverAttemptTrackerTests
      MeetingMicFailoverPolicyTests
      MeetingMicSessionRouteStateTests
      MeetingChatClientTests
      MeetingChatConversationTests
      MeetingChatRecipesTests
      MeetingChatSourceTests
      MeetingCleanupPromptTests
      MeetingTranscriptAccessorTests
      MeetingTranscriptCleanupTests
      DisabledCalendarFilterTests
      GoogleCalendarTests
      NaturalTextDirectionTests
    )
    ;;
  *)
    echo "unknown shard: ${shard}" >&2
    exit 2
    ;;
esac

if [[ "${list_filters}" == true ]]; then
  printf '%s\n' "${filters[@]}"
  exit 0
fi

args=(--package-path native/MuesliNative)
if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
  args+=(--scratch-path "${MUESLI_SWIFTPM_SCRATCH_PATH}")
fi
for filter in "${filters[@]}"; do
  args+=(--filter "${filter}")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
swift test "${args[@]}"
