# Secure transport spike

## Status

The restricted Network.framework TLS WebSocket server interoperates with the URLSession WebSocket client on macOS and an iOS 26.5 simulator. The physical iPhone test has **not passed**: a verified Xcode-signed build launches the test, but the phone returns `NSURLErrorDomain -1009` before TLS verification. Keep the physical transport task in `PLAN.md` open.

This spike cannot start Pi, read Mac directories, or forward arbitrary RPC commands. The diagnostic iOS app is not the Pi Remote product interface.

## Verified behavior

- Eleven shared-package test functions pass, including four handshake tests for typed messages, unsupported versions, message limits, pairing expiration, attempt limits, consumed grants, unpaired devices, nonce replay, and revocation.
- Twenty root test functions pass, including the existing 15 RPC tests and five secure transport tests; the root tests also pass with Thread Sanitizer.
- The secure transport tests verify pairing, authenticated reconnection, refusal of unauthenticated requests, rejection of changed certificates and hostname mismatches, immediate closure of a revoked active connection, rejection of revoked credentials, explicit-port binding, and cancellation of a pending client receive.
- The iOS diagnostic app and test bundle compile for physical iOS with `CODE_SIGNING_ALLOWED=NO`.
- A separately Xcode-signed build with bundle IDs `dev.narumi.PiRemote.TransportSpike` and `dev.narumi.PiRemote.TransportSpikeTests` passes deep signature verification; its bundled private fixture matches the server fixture, and its test binary is newer than the test sources.
- The first physical execution waited for device unlock and timed out before running a test. After unlocking, the iPhone 16 Pro on iOS 26.7.1 ran the test, which failed with network error `-1009`; neither certificate rejection nor pairing has passed on the phone.
- The iPhone 16 Pro simulator on iOS 26.5 passes one end-to-end test covering certificate rejection, unauthorized requests, pairing, consumed-grant rejection, device Keychain storage and retrieval, two authenticated connections, correlated ping responses, and replay rejection.
- The initial simulator run failed because the listener supplied a concrete port twice and returned POSIX error 22; the listener initialization was fixed, an explicit-port regression test was added, and the simulator rerun passed.

The physical iPhone is connected, and `devicectl device info ddiServices` reports DDI 17F113 compatible and usable. Its earlier mount error was `kAMDMobileImageMounterDeviceLocked`; no Xcode/iOS version incompatibility was established.

## Security boundary

- The server binds one explicit private, loopback, or Tailscale IPv4 address; it never binds a wildcard or public address.
- TLS uses a temporary P-256 identity imported into memory only; the client requires the exact out-of-band certificate pin and also evaluates certificate validity and the server hostname.
- No global trust override or App Transport Security exception is used.
- Starting the local test server approves one logical test-device ID and its pinned server identity through a private generated fixture; a 256-bit one-use pairing grant expires within five minutes and allows at most five pairing attempts.
- Pairing returns a separate random device credential over the pinned TLS connection; it does not authenticate the pairing socket.
- Each new socket must authenticate with an HMAC-SHA256 proof over its fresh random challenge and device ID; each socket accepts only one authentication attempt.
- Authenticated operations are limited to a typed, correlated diagnostic ping; revocation is a local server operation, not an unauthenticated network command.
- Messages are limited to 16 KiB, active peers to 16, the authentication deadline to ten seconds, authenticated idle time to 30 seconds, and client operations to ten seconds; deadlines are checked on every request, with idle sockets cleaned up every five seconds.
- The server exits after five minutes; tests close their clients and listeners explicitly.

The test fixture contains private keys and a bootstrap grant. Its directory has private permissions and is ignored by Git. The bootstrap grant is copied into the diagnostic test bundle, so generated build artifacts must also remain private. This is test provisioning, not a production pairing interface or a secret suitable for a shipped app.

Host credentials are intentionally ephemeral; restarting the test server discards them and starts a new locally approved test window. Durable host Keychain storage, user-facing identity confirmation, Face ID gating, app restart recovery, and production credential rotation remain unimplemented. The iOS diagnostic credential uses `WhenUnlockedThisDeviceOnly`, is not synchronized, and is removed after the test; this does not prove the planned Face ID policy.

## Reproduce the local checks

From the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path Packages/PiRemoteCore
swift test
swift test --sanitize=thread
```

The integration tests generate temporary identities with `openssl`, use loopback listeners, and remove their fixture directories after completion.

## Prepare the iOS test host

Prerequisites: Xcode, XcodeGen, `openssl`, a local IPv4 address assigned to the Mac, and an unlocked test device for physical tests; verification used XcodeGen 2.46.0 and OpenSSL 3.6.4.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run TransportServerSpike prepare "$PWD/.transport-fixture" <mac-private-ipv4> 7943
xcodegen generate --spec Spikes/TransportDevice/project.yml
```

The generator refuses to overwrite an existing fixture directory. Certificates last one day. If a fixture expires, replace only the generated `.transport-fixture/` directory deliberately, then rebuild the test bundle; never reuse a stale pin with a new identity.

Build for the chosen destination before starting the server:

```sh
xcodebuild -project Spikes/TransportDevice/TransportDeviceSpike.xcodeproj \
  -scheme TransportDeviceSpike -destination '<destination>' \
  -derivedDataPath /tmp/pi-remote-transport-build \
  DEVELOPMENT_TEAM=<development-team> -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration build-for-testing
```

A physical destination uses `platform=iOS,id=<device-udid>`. Simulator builds use `platform=iOS Simulator,id=<simulator-id>` and `CODE_SIGN_IDENTITY=-` instead of the development team and provisioning flags. The simulator test was run on a dedicated iPhone 16 Pro simulator with iOS 26.5.

If background signing fails but Xcode can build in the user's normal session, reuse that signed build rather than changing key access rules. Verify its signature, bundle IDs, source freshness, and private fixture before running its test manifest:

```sh
codesign --verify --deep --strict '<signed-app-path>'
xcodebuild -xctestrun '<signed-products-path>/<test-manifest>.xctestrun' \
  -destination 'platform=iOS,arch=arm64,id=<device-udid>' \
  -parallel-testing-enabled NO test-without-building
```

Start the restricted server before the test command, and do not regenerate the Xcode project while the user is configuring signing in it. Keep the iPhone unlocked and awake; allow local-network access and connect it to the Mac's Wi-Fi for the local test.

Then start the restricted server in one terminal:

```sh
swift run TransportServerSpike serve "$PWD/.transport-fixture"
```

Wait for its listening message before running the tests in another terminal:

```sh
xcodebuild -project Spikes/TransportDevice/TransportDeviceSpike.xcodeproj \
  -scheme TransportDeviceSpike -destination '<same-destination>' \
  -derivedDataPath /tmp/pi-remote-transport-build \
  -parallel-testing-enabled NO test-without-building
```

Use the same build/signing settings as the build step. Allow the diagnostic app's local-network permission when requested. Start a fresh server for each test run because the pairing grant is consumed. Do not weaken trust checks to make a failed run pass.

## Remaining blockers

1. The physical phone returns `NSURLErrorDomain -1009` before TLS verification. The signed app includes its local-network usage description, but Wi-Fi reachability and the user's local-network permission still need confirmation; the failure does not establish a certificate problem. Background signing remains unavailable, but the verified foreground-signed build is usable through `test-without-building`.
2. Mac Tailscale is running, but the iPhone peer is offline. A physical off-site test still needs the iPhone online through Tailscale from a different network, with a new fixture pinned to the selected Tailscale address.
3. GitHub authentication still returns HTTP 401, so pull request creation remains blocked even though Git-over-SSH push works.

No physical pairing, off-site access, product interface, or complete-plan acceptance is claimed from simulator results.
