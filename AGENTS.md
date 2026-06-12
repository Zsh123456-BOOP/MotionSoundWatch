# Codex Working Rules For watch app

- Codex owns build/deploy/log collection when needed; the user mainly tests on the real iPhone/Watch and reports results.
- Use the loop: inspect -> smallest useful change -> deploy -> user tests -> pull latest logs -> diagnose -> next change.
- Do not stop at build success when behavior depends on the real device.
- For recognition/trigger bugs, first check `candidate.shouldTrigger`, `trajectoryRejectReason`, score vs DTW, current `runId`, and latest watch-events/logs.
- Do not treat `WCSession.isReachable == false` alone as proof that WatchConnectivity or business sync is broken.
