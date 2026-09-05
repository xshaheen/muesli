import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingReverseLeakLockPolicy")
struct MeetingReverseLeakLockPolicyTests {
    @Test("three consecutive agreeing estimates lock")
    func threeAgreeingEstimatesLock() {
        var policy = MeetingReverseLeakLockPolicy()

        #expect(policy.observe(lagFrames: 25) == .candidate)
        #expect(!policy.isLocked)
        #expect(policy.candidateCount == 1)
        #expect(policy.observe(lagFrames: 26) == .candidate)
        #expect(policy.candidateCount == 2)
        #expect(policy.observe(lagFrames: 25) == .locked)

        #expect(policy.isLocked)
        #expect(policy.lockedLagFrames == 25)
        #expect(policy.candidateCount == 0)
    }

    @Test("a candidate outside one grid step restarts the chain")
    func disagreeingCandidateRestartsChain() {
        var policy = MeetingReverseLeakLockPolicy()

        #expect(policy.observe(lagFrames: 25) == .candidate)
        #expect(policy.observe(lagFrames: 25) == .candidate)
        #expect(policy.observe(lagFrames: 40) == .candidate)
        #expect(policy.candidateCount == 1)
        #expect(policy.observe(lagFrames: 40) == .candidate)
        #expect(policy.observe(lagFrames: 41) == .locked)
        #expect(policy.lockedLagFrames == 40)
    }

    @Test("a rejected estimate breaks the candidate chain")
    func rejectedEstimateBreaksChain() {
        var policy = MeetingReverseLeakLockPolicy()

        #expect(policy.observe(lagFrames: 25) == .candidate)
        #expect(policy.observe(lagFrames: 25) == .candidate)
        policy.observeRejected()
        #expect(policy.candidateCount == 0)
        #expect(policy.observe(lagFrames: 25) == .candidate)
        #expect(!policy.isLocked)
    }

    @Test("a fourth disagreeing estimate does not unlock")
    func disagreeingEstimateKeepsLock() {
        var policy = locked(at: 25)

        #expect(policy.observe(lagFrames: 40) == .relockCandidate)
        #expect(policy.isLocked)
        #expect(policy.lockedLagFrames == 25)
        #expect(policy.relockCandidateCount == 1)

        // An estimate that agrees with the lock again ends the disagreement.
        #expect(policy.observe(lagFrames: 26) == .agreesWithLock)
        #expect(policy.relockCandidateCount == 0)
        #expect(policy.lockedLagFrames == 25)
    }

    @Test("five consecutive mutually agreeing disagreements re-lock")
    func fiveAgreeingDisagreementsRelock() {
        var policy = locked(at: 25)

        #expect(policy.observe(lagFrames: 40) == .relockCandidate)
        #expect(policy.observe(lagFrames: 41) == .relockCandidate)
        #expect(policy.observe(lagFrames: 40) == .relockCandidate)
        #expect(policy.observe(lagFrames: 39) == .relockCandidate)
        #expect(policy.lockedLagFrames == 25)
        #expect(policy.observe(lagFrames: 40) == .relocked)

        #expect(policy.isLocked)
        #expect(policy.lockedLagFrames == 40)
        #expect(policy.relockCandidateCount == 0)
    }

    @Test("disagreements that do not agree with each other never re-lock")
    func scatteredDisagreementsDoNotRelock() {
        var policy = locked(at: 25)

        for lag in [40, 60, 41, 80, 42, 43, 42] {
            #expect(policy.observe(lagFrames: lag) == .relockCandidate)
        }
        #expect(policy.lockedLagFrames == 25)
        // 42, 43, 42 are within one step of the chain anchor 42; two more would re-lock.
        #expect(policy.relockCandidateCount == 3)
        // Two steps away from the anchor restarts the chain.
        #expect(policy.observe(lagFrames: 44) == .relockCandidate)
        #expect(policy.relockCandidateCount == 1)
    }

    @Test("a rejected estimate breaks the re-lock chain but keeps the lock")
    func rejectedEstimateBreaksRelockChain() {
        var policy = locked(at: 25)

        _ = policy.observe(lagFrames: 40)
        _ = policy.observe(lagFrames: 40)
        policy.observeRejected()
        #expect(policy.relockCandidateCount == 0)
        #expect(policy.isLocked)
        #expect(policy.lockedLagFrames == 25)
    }

    @Test("reset clears the lock, the candidate chain and the re-lock chain")
    func resetClearsEverything() {
        var policy = locked(at: 25)
        _ = policy.observe(lagFrames: 40)

        policy.reset()

        #expect(!policy.isLocked)
        #expect(policy.lockedLagFrames == nil)
        #expect(policy.candidateCount == 0)
        #expect(policy.relockCandidateCount == 0)

        // A fresh lock needs three agreeing estimates again.
        #expect(policy.observe(lagFrames: 40) == .candidate)
        #expect(policy.observe(lagFrames: 40) == .candidate)
        #expect(policy.observe(lagFrames: 40) == .locked)
    }

    @Test("estimates inside the gate tolerance count as agreeing with the lock")
    func toleranceAroundLock() {
        var policy = locked(at: 25)

        #expect(MeetingReverseLeakLockPolicy.lockToleranceFrames == 3)
        #expect(policy.observe(lagFrames: 28) == .agreesWithLock)
        #expect(policy.observe(lagFrames: 22) == .agreesWithLock)
        #expect(policy.observe(lagFrames: 29) == .relockCandidate)
    }

    private func locked(at lagFrames: Int) -> MeetingReverseLeakLockPolicy {
        var policy = MeetingReverseLeakLockPolicy()
        for _ in 0..<MeetingReverseLeakLockPolicy.lockAgreementCount {
            _ = policy.observe(lagFrames: lagFrames)
        }
        precondition(policy.lockedLagFrames == lagFrames)
        return policy
    }
}
