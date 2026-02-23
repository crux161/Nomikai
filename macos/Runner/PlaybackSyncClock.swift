import Foundation

final class PlaybackSyncClock {
  private let stateQueue = DispatchQueue(label: "com.nomikai.sankaku.playback_sync_clock")
  private let targetLatencyUs: UInt64

  private var anchorRemotePtsUs: UInt64?
  private var anchorLocalMonotonicUs: UInt64?

  init(targetLatencyUs: UInt64 = 100_000) {
    self.targetLatencyUs = targetLatencyUs
  }

  func anchorIfNeeded(remotePtsUs: UInt64, source: String) {
    guard remotePtsUs > 0 else { return }

    stateQueue.sync {
      guard anchorRemotePtsUs == nil || anchorLocalMonotonicUs == nil else {
        return
      }

      anchorRemotePtsUs = remotePtsUs
      anchorLocalMonotonicUs = Self.monotonicNowUs()
      NSLog(
        "PlaybackSyncClock: anchored at remote_pts_us=%llu source=%@ target_latency_us=%llu",
        remotePtsUs,
        source,
        targetLatencyUs
      )
    }
  }

  func playablePtsUpperBoundUs() -> UInt64? {
    stateQueue.sync {
      guard
        let anchorRemotePtsUs,
        let anchorLocalMonotonicUs
      else {
        return nil
      }

      let nowUs = Self.monotonicNowUs()
      let elapsedUs = nowUs >= anchorLocalMonotonicUs ? nowUs - anchorLocalMonotonicUs : 0

      return anchorRemotePtsUs
        .addingReportingOverflow(elapsedUs).partialValue
        .addingReportingOverflow(targetLatencyUs).partialValue
    }
  }

  func isAnchored() -> Bool {
    stateQueue.sync { anchorRemotePtsUs != nil && anchorLocalMonotonicUs != nil }
  }

  private static func monotonicNowUs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000
  }
}
