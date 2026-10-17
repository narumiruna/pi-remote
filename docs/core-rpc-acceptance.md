<a id="core-rpc-acceptance-checkpoint"></a>

# Upstream Pi core RPC acceptance checkpoint

## Result

The current host, client and native controls pass the local checks below against Pi 1.3.0. **The plan is not complete:** the approved upstream Pi core `bash`/`abort_bash` controls and `bash_execution_update` output still need implementation and verification. No terminal-only or individual-extension integration is required.

This checkpoint predates the later Mac UI and manual folder-path changes. Its full product/interface counts and source hashes apply to that earlier revision, not the later changes. See [separate UI/path verification](mac-interface.md).

## Verified results

| Check | Result | Evidence |
| --- | --- | --- |
| Root packages | 135 tests pass normally and with Thread Sanitizer | `/tmp/pi-remote-final-root-135-no-parallel.log`, `/tmp/pi-remote-final-root-tsan-135-no-parallel.log` |
| Shared package | 50 tests pass normally and with Thread Sanitizer | `/tmp/pi-remote-acceptance-{shared,shared-tsan}.log` |
| Installed Pi, without inference | All seven probes pass normally and with Thread Sanitizer | `/tmp/pi-remote-final2-<Target>-{normal,tsan}.log`; targets listed below |
| Real provider workflow | Image input, streaming, branching, restoration, queues, Stop and custom-instruction compaction pass | `/tmp/pi-remote-final3-provider.log` |
| Mac model | 3 tests pass; no failures or skips | `/tmp/pi-remote-final3-mac-tests-summary.json`, `/tmp/pi-remote-final3-mac-tests.xcresult` |
| Product simulator on LAN | 31 tests pass; no failures or skips; host PASS | Product artifacts below |
| Product simulator on Tailscale | 31 tests pass; no failures or skips; host PASS | Product artifacts below |
| Compact interface | All 27 current tests pass in 14 accepted batches; no failures or skips in that set | Interface artifacts below |
| Unsigned app builds | Mac, iOS simulator and iOS device SDK pass | `/tmp/pi-remote-final3-{mac,simulator,device}-build.log` |

The seven installed-Pi targets are `NativeWorkflowCheck`, `NativeResourceCheck`, `NativeFailureCheck`, `NativeRetryCheck`, `NativeUIStateCheck`, `NativeSessionLifecycleCheck` and `NativeInspectionCheck`. These cover generic dialogs, resources, missing credentials, retry, standard UI state, same-child lifecycle and authoritative inspection. Generated extensions are isolated test fixtures, not product dependencies or adapters.

The operation inventory contains all 33 command headings from installed `rpc-commands.md`, all 24 upstream Pi core event types and all nine standard extension UI methods. The [coverage table](native-compatibility.md) separates verified mappings from the remaining approved shell implementation and verification. Inventory alone is not complete acceptance.

Run complete root suites with explicit serial test scheduling:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --no-parallel --scratch-path /tmp/pi-remote-core-semantics-root
swift test --no-parallel --sanitize=thread --scratch-path /tmp/pi-remote-core-semantics-tsan
```

Tests still exercise concurrency explicitly inside their bodies. Default concurrent execution of the full suite exhausted fixture startup capacity and caused timing failures. These failed runs are not counted as acceptance. The utility cancellation test now waits for a live descendant marker, verifies sufficient remaining fixture lifetime, and measures cancellation-to-completion against the existing three-second bound. Neither the cancellation deadline nor production process scheduling was weakened.

## Delegated product E2E

A separate Herdr Pi agent ran the complete production app suite on iPhone 17 Pro simulator `6622EB8D-23E3-4E92-9262-21CF896CD300`, using the explicit local provider fixture. LAN used `10.0.0.100`; Tailscale used `100.88.112.104`. Both runs exercised authenticated local transport, pairing, selected-directory coding, reconnection, Stop and host restarts.

Parent inspection confirmed both 31-test summaries, both host PASS logs and the cleanup records. All 93 recorded product/build/test source hashes match the current files. Agent settings were unchanged. The fixture directory was removed, both listener ports closed, and all six recorded child PID/start identities disappeared for each network.

Artifacts: `/tmp/pi-remote-worker-product-handled-final-20261017T062213Z-30399/`:

- `{lan,tailscale}/summary.json`
- `{lan,tailscale}/product.xcresult`
- `{lan,tailscale}/host.log`
- `source-{before,after}.sha256`, `settings-check.txt`
- `final-cleanup-check.txt`, `final-owner-scan.txt`

The parent also recorded final implementation/configuration hashes in `/tmp/pi-remote-final-source.json`.

## Delegated compact interface audit

A second Herdr Pi agent ran all 27 current interface tests on iPhone SE (3rd generation) simulator `B0BF2720-C60E-4B7F-B57B-CE16F9B8A443`, iOS 26.5, at `accessibility-extra-large`. The final accepted set contains 14 passing batches, not one uninterrupted suite. Parent inspection matched the accepted IDs to every current interface test and checked every accepted summary. All 27 pass, with no failures or skips in that set.

The 39 reviewed captures include keyboard actions, compaction consent, optional parent selection, populated tree labels/timestamps, full text/image previews and fork eligibility. Linked UI and fixture source hashes stayed unchanged. Only test navigation changed during this audit; service-only host changes were recorded separately. The fixture app and runner were removed, and no owned build process remained.

Artifacts: `/tmp/pi-remote-worker-interface-final-hXEQ2M/`:

- `REPORT.md`, `combined-summary.json`, `verified-tests.json`
- `accepted-results.json`, per-batch summaries and result bundles
- `earlier-failures.json`, `verification-notes.json`
- `ui-source-digests.json`, `source-{before,after}.json`
- `capture-index.json`, `captures/`, `review/`
- `owned-process-check.json`, `cleanup.log`

Earlier attempts had 12 failed executions across ten bundles. Files-picker navigation assumed the folder was on the first page; populated inspection used stale virtualized rows or selected the wrong preview action. Tests now use List mode, resolve current rows, scroll in the correct direction and require fully visible targets. Semantic and hit-region assertions remain. Earlier failures are retained, not counted as passes.

## Regression records

- The older workflow probe assumed New replaced the process. It timed out on the newly preserved standard `session_before_switch` confirmation. The test now waits for that exact synthetic dialog and explicitly confirms it. Product code does not approve automatically.
- The Mac model fixture returned an empty object for `new_session`. The Pi Remote host correctly rejected it. The fixture now returns the standard cancellation field and new session state; all three Mac tests pass without weakening assertions.
- A cancelled shutdown caller previously collapsed cleanup waits. Cleanup now runs independently of caller cancellation with bounded graceful, termination and kill stages. The regression passes normally and with Thread Sanitizer; no owned child remains after success.
- A handled metadata-only prompt could incorrectly mark a still-unwritten empty session as populated. The host restores its prior empty-file expectation only for a confirmed handled, idle, unchanged session without a persisted file. A dedicated regression and the real `/rpc-prefill` workflow pass normally and with Thread Sanitizer. Unknown accepted outcomes remain protected against replay.
- [Lifecycle regressions](session-lifecycle.md#verified-checkpoint) cover empty ancestry, an unwritten fork and persisted custom messages. [Event checks](core-event-verification.md) record recovery and refresh races.

## Limits

These checks establish local simulator and laptop behavior only. They do not establish signed installation, physical unlock or camera behavior, off-site reliability, a supported runtime-version range or distribution readiness. iOS 18 and macOS 15 remain build deployment settings, not tested hardware floors. Pi 1.3.0 is the only tested development runtime.

Provider credentials remain on the Mac. Pairing approval, certificate pinning, hostname/validity checks, revocation, directory validation and no-prompt-replay rules remain unchanged. No arbitrary raw RPC or shell controls were added in this checkpoint. The user subsequently approved native upstream Pi core shell controls, but not an embedded terminal or PTY; implementation and verification remain open.
