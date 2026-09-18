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
      MeetingSelectableTextSizingTests
      MeetingChatConversationLoadingTests
      TranscriptionQualityUpgradeComparisonTests
      TranscriptionLanguageRoutingTests
      DictationStoreTests
      SessionTraceStoreTests
      RecordingArtifactStoreTests
      RecordingArtifactPlaybackTests
      LocalDiagnosticsTests
      SessionDiagnosticsPresentationTests
      ComputerUseExecutorTests
      ComputerUseObservationCaptureTests
      ComputerUseObservationTests
      ComputerUsePlannerModelTests
      ComputerUsePlannerRequestTests
      ComputerUsePlannerResponseTests
      ComputerUsePlannerRuntimeTests
      ComputerUseRunDiagnosticsTests
      ComputerUseToolRegistryTests
      ComputerUseTraceFormatterTests
      ImlaCKSyncEngineTests
      ImlaCLITests
      ChatGPTAuthTests
      ChatGPTResponsesTransportTests
      ChatGPTTokenStorageTests
      ComputerUseCursorOverlayTests
      FloatingMeetingPanelStyleTests
      DictationMiniPlacementTests
      OpenRouterAuthTests
      SettingsPermissionRefreshReasonTests
      InteractionPermissionMonitorTests
      AccessibilityPermissionGuideTests
      DictationTestLifecycleTests
      OnboardingFlowTests
      OnboardingProgressTests
      WindowAppearanceTests
      OpenAILogoShapeTests
      StandardMenuShortcutTests
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
      BodhanBackendTests
      BodhanArtifactValidationTests
      BodhanLifecycleTests
      DictationBackendPreparationTests
      ContributionMilestoneTests
    )
    ;;
  dictation-transcription)
    filters=(
      FluidAudioTranscriberTests
      AppleSpeechAnalyzerBackendTests
      BackendCoverageTests
      FillerWordFilterTests
      JaroWinklerTests
      CustomWordMatcherApplyTests
      StreamingDictationControllerTests
      DeltaPasteTests
      TranscriptAccumulationTests
      StreamingDictationControllerLifecycleTests
      DictationAttributionPolicyTests
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
      DictationPasteSpacingPolicyTests
      DictationPasteSpacingTests
      QuilTransformationTests
      QuilAvailabilityGateTests
      QuilDirectAudioTests
      BackendOptionTests
      OpenAIDictationProviderTests
      OpenRouterTranscriptionClientTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      PushToTalkEnablementPolicyTests
      ShortcutFeatureEnablementPolicyTests
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
      AudioAttributionServiceTests
      CameraActivityMonitorTests
      MicrophoneActivityMonitorTests
      MeetingCaptureLifecycleTests
      AudioQueueInputRecorderTests
      FallbackStreamingDictationRecorderTests
      MeetingCaptureShutdownTests
      MeetingMonitoringModePolicyTests
      MeetingAudioRecoveryDeadlinesTests
      MeetingSignalRefreshPolicyTests
      MeetingMicRecoveryCoordinatorTests
      MeetingMicHealthTrackerTests
      MeetingSystemAudioWatchdogTests
      AudioGraphExceptionBridgeTests
      DiagnosticIncidentTests
      DiagnosticIncidentReporterTests
      DictationAudioRouteControllerTests
      MeetingContactIdentityTests
      MeetingContactResolverTests
      MeetingDetectorTests
      MeetingActivityDetectionPolicyTests
      MeetingParticipantStoreTests
      MeetingProcessingStageTests
      MeetingRecordingWriterTests
      MeetingRecordingElapsedClockTests
      MeetingRecordButtonTests
      MeetingPanelBodyCoordinatorTests
      MeetingRecordingPanelGeometryTests
      MeetingRecordingPanelLifecycleTests
      MeetingResumePolicyTests
      MeetingReverseLeakEstimatorTests
      MeetingReverseLeakLockPolicyTests
      MeetingReverseLeakMaskPlannerTests
      MeetingReverseLeakSettingTests
      ReverseLeakLevelMeasurementManualTests
      MeetingReverseLeakSuppressorTests
      MeetingSessionDiagnosticsTests
      MeetingSessionLanguageAuthorityTests
      MeetingSessionReverseLeakHarnessTests
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
      StreamingVadFrameAccumulatorTests
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
      CalendarEventQueryTests
      CalendarMonitorLifecycleTests
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

# The default swiftbuild engine flattens binary-target headers into one
# Products/<cfg>/include/, where CLiteRTLM_mac and FluidAudio's
# NemoTextProcessing module maps collide; build_native_app.sh pins the legacy
# engine for the same reason.
args=(--package-path native/ImlaNative --build-system native)
if [[ "${shard}" == meetings ]]; then
  # Concurrent suites can starve the utility-priority caption tasks on small
  # runners. Serialize test cases, preserving concurrency exercised inside each
  # test, rather than weakening their deadlines or changing production QoS.
  args+=(--no-parallel)
fi
if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
  args+=(--scratch-path "${MUESLI_SWIFTPM_SCRATCH_PATH}")
fi
for filter in "${filters[@]}"; do
  args+=(--filter "${filter}")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
swift test "${args[@]}"
