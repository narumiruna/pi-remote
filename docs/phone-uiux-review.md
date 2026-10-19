# iPhone UI/UX review corrections

## Behavior

The five findings from the iPhone 17 Pro review are resolved:

1. The fault recovery button exposes one named accessibility element with a rectangular hit region of at least 44 × 44 points. Tapping the fault opens recovery instructions; Dismiss remains separate.
2. Send is disabled and dimmed when the draft contains only whitespace and has no image. `PhoneModel.send` also rejects that input before uncertain-outcome confirmation or request dispatch. Image-only prompts remain valid. Valid prompt text is sent without trimming, and the draft remains until acknowledgement.
3. A Space's **New session** says **Review or change this folder**. **New session options** says **Current folder · Optional parent link**. The first route reviews the folder before Start Pi Here. The second retains same-directory creation, optional ancestry and explicit confirmation. Neither route starts Pi when opened.
4. iPhone Session controls put Model, Thinking level and explicit cycling first. Version and Pi changelog are under initially collapsed **Details** at the end of the form. Capability checks remain in force. Mac Pi/Desktop controls retain their existing order.
5. Steering/Follow-up is above the prompt row, not beside the editor. At standard text sizes it shares a row with the extension summary. Accessibility text sizes keep notices and the selector on separate rows. The prompt, attachment, Stop and Send controls retain their own row.

No protocol, pairing, transport or host lifecycle contract changes are included.

## Verification

All simulator checks use iPhone 17 Pro, iOS 26.5, device `6622EB8D-23E3-4E92-9262-21CF896CD300`.

- Nine focused product tests pass: five `PhoneSendTests` and four `SessionControlsTests`. They cover empty/Unicode-whitespace input, uncertain outcomes, original prompt text, image-only input, pending acknowledgements, edited drafts, model-first order, capability gates, disabled actions and Details retention during work.
- Twenty distinct UI checks pass across the accepted batches below. They cover the original dark accessibility audit, recovery instructions, empty and image-only Send, keyboard layout at standard and accessibility text sizes, delivery selection, Stop, draft retention, tool disclosures, offline recovery, Forget cancellation, close/reopen, Spaces, folder validation, ancestry consent, model-first controls and Details/changelog navigation.
- The standard-size working keyboard check retains at least 200 points and 60% of the available history area. It requires at least 220 points of prompt width and 44-point control heights.
- Unsigned Mac and iOS simulator product builds pass. `git diff --check` and independent source review pass.
- Reviewed captures show the wider prompt, standard/large-text delivery rows, recovery target, Spaces actions, model-first controls and expanded/collapsed Details.

Accepted local artifacts:

- `/tmp/pi-ios-uiux-fix-model-5.xcresult`: all nine product checks pass.
- `/tmp/pi-ios-uiux-fix-ui-3.xcresult`: nine accepted UI checks pass. Its additional Details test failed because a Button-only query could not match iOS's expanded DisclosureTriangle; the corrected type-independent query passes in batch 4.
- `/tmp/pi-ios-uiux-fix-ui-4.xcresult`: all five UI checks pass.
- `/tmp/pi-ios-uiux-fix-ui-5.xcresult`: all seven UI checks pass, including the repeated standard keyboard check. The union of batches 3–5 contains twenty distinct passing checks.
- `/tmp/pi-ios-uiux-fix-mac-final.log` and `/tmp/pi-ios-uiux-fix-ios-final.log`: product builds.
- `/tmp/pi-ios-uiux-fix-ui-{3,4,5}-captures/`: local captures and manifests. No captures or binary test artifacts are committed.

Earlier attempts are not acceptance evidence. The initial two-row composer reduced the history share below its existing 60% check; sharing the standard-size notice row fixes it. The first model-test build needed an explicit MainActor closure. Hosted Details checks initially counted inactive recycled UIKit cells after collapse; the corrected visibility checks use paged screenshot/OCR, with native controls for explicit actions. Xcode also emitted debugger-version and intermittent diagnostic-collection warnings. Counts above come from result bundles, not warning-free logs. These are focused batches, not a full-suite pass.

## Repeat focused checks

Run from the repository root. Keep the developer-directory override local to these commands.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-ios-uiux-fix-product -parallel-testing-enabled NO \
  -only-testing:PiRemoteTests/PhoneSendTests \
  -only-testing:PiRemoteTests/SessionControlsTests CODE_SIGNING_ALLOWED=NO test
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteInterface \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-ios-uiux-review-build -parallel-testing-enabled NO \
  -only-testing:PiRemoteInterfaceTests/InterfaceTests/testDarkErrorsAndSessionControlsRemainReadable \
  -only-testing:PiRemoteInterfaceTests/InterfaceTests/testPhoneControlsPrioritizeModelAndKeepDetailsExplicit \
  -only-testing:PiRemoteInterfaceTests/PhoneRecoveryInterfaceTests/testCompactWorkingComposerKeepsTranscriptVisibleWithKeyboard \
  -only-testing:PiRemoteInterfaceTests/PhoneRecoveryInterfaceTests/testLargeTextKeepsDeliveryAndNoticesAboveThePrompt \
  CODE_SIGNING_ALLOWED=NO test
```

Product build commands remain in [native app verification](native-apps.md#automated-checks).

## Limits

UI checks use the dedicated fixture with production iPhone views and injected local data. They do not establish live provider operation, real pairing, hardware authentication, physical-device support, off-site networking or full VoiceOver/Dynamic Type acceptance. No user's Mac app or Pi process was restarted. Mac presentation has build coverage, not a new Mac UI acceptance run.
