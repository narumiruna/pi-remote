# Native image output verification

## Result

Bounded raster image output now works through the production host and client. The native conversation and history views can open image output without a terminal or an external image URL. This does not complete the full Pi compatibility review.

The simulator reads a synthetic PNG with the installed Pi read tool, retrieves its exact original bytes through authenticated transport, decodes it natively and retrieves it again after host restart. All 27 app tests pass with zero failures or skips on both local LAN and Tailscale. Eight compact-interface tests pass, including image preview, the Full resolution switch, Done and image-sheet removal after background return. Reviewed captures show the image and controls at accessibility-extra-large text.

## Data and security

- Image blocks become opaque `OutputImageReference` values. Snapshots and replay contain references, not dedicated image payloads.
- `outputImage` is a typed read-only action. It requires the selected session and normal device authentication. It does not accept a path, URL or arbitrary Pi command.
- Each session activation, fork or clone clears the image cache. Old-session requests fail with conflict; old image IDs used in the new session expire.
- The host cache holds at most 32 images and 8 MiB of original data. Identical format/data pairs reuse a reference. Fetching an image updates its retention order. Eviction returns an explicit expired error, never unrelated bytes.
- History entry previews can create fresh references from companion-owned session files. They retain existing session, file-identity, record-size and expiry checks. Hidden custom/system content does not become visible image output.
- The host removes provider-supplied reference fields before creating its own IDs. It checks base64 data, supported raster type, byte size and dimensions. The client checks the raster format, size and dimensions again before decoding.
- No image is fetched from the internet or saved by the viewer. Pi's existing managed session file remains the durable source. Images and decoding work do not enter routine logs.
- The image sheet is privacy-sensitive. Background protection removes its presenter; late or cancelled loads cannot repopulate the removed view. A simulator background/activate check verifies that the sheet does not return automatically.

## Limits

PNG, JPEG, WebP and GIF are accepted when ImageIO recognizes the declared type. The original image must be at most 2 MiB, 20,000 pixels per side and 40 million pixels. Invalid or oversized blocks show a specific error instead of a broken image control. At most sixteen references appear per message or history preview; omitted content is marked as truncated.

The normal preview is downsampled to at most 2,048 pixels on its longest side. Full resolution decodes the original dimensions within the same limits. Zoom and two-axis scrolling inspect the image. Animated images show their first frame and an explicit first-frame label; animation is not implemented. Unsupported formats and animation remain limits in the compatibility review, not approved feature exclusions.

An evicted image can be recovered by reloading History and reading its entry again. Reconnection alone does not make an expired cache reference valid. A host restart regenerates references from persisted Pi history rather than reusing old IDs.

## Checks

- Six image-cache unit tests cover opaque references, stripping binary/spoofed fields, exact-byte retrieval, deduplication, PNG/JPEG/GIF validation, malformed data, mismatched formats, oversized data/dimensions, count/byte eviction, retention order, tool rows and per-message limits.
- A host-history test reads a saved image entry, retrieves its bytes, changes sessions and verifies both image and history reference isolation.
- Production TLS tests retrieve images on loopback, LAN and Tailscale, reject unknown/wrong-session IDs, preserve valid retrieval across listener outage/recovery and reject retrieval after revocation.
- Two shared tests verify reference/preview transport and ensure unannotated content does not invent a capability. Existing legacy-message decoding still passes with absent optional image fields.
- Two iOS decoder tests verify a 3,000-pixel source at both 2,048-pixel preview and original resolution, plus invalid MIME/data, dimensions and size.
- The real-Pi simulator coding flow reads `image.png` before writing the exact Swift fixture result. The image bytes equal the source PNG, decode to 32 × 32 pixels and remain retrievable after host restart.
- The compact UI fixture opens a colored image, enables the actual Full resolution switch, checks its value, closes with a 44-point Done control and verifies sheet removal after background/activate.

All 69 root tests pass normally and with Thread Sanitizer. All 23 shared tests, two Mac-model tests, 27 product simulator tests and eight interface tests pass. Unsigned Mac, iOS simulator and iOS device-SDK builds pass. This is laptop/simulator evidence, not hardware, off-site or release evidence.

## Failure record

The first byte-eviction fixture generated seven compressed images totaling less than 8 MiB, so eviction was correctly absent. The test now verifies that eight fixtures exceed the byte budget before asserting eviction. An initial shared test used `uuidString` as a function; correcting the property access fixed compilation.

The initial image-sheet Done toolbar control exposed only a 36-point accessibility target despite an inner frame. Done now uses a keyboard-safe bottom inset with a full-width 44-point label. The title is inline and the image fits both viewport dimensions before zooming. A weak initial switch check could pass while the switch remained off; it now activates the visible switch rather than the combined label's center and verifies its value. Image content remains visible during resolution changes to prevent layout movement under the control. The focused test and the complete eight-test suite pass after these corrections.

## Local evidence

- `/tmp/pi-remote-output-root-final.log`
- `/tmp/pi-remote-output-tsan.log`
- `/tmp/pi-remote-output-core.log`
- `/tmp/pi-remote-output-product.log` and `/tmp/pi-remote-output-product-summary.json` (Tailscale)
- `/tmp/pi-remote-output-lan-product.log` and `/tmp/pi-remote-output-lan-summary.json`
- `/tmp/pi-remote-output-ui-verified.log` and `/tmp/pi-remote-output-ui-verified-summary.json`
- `/tmp/pi-remote-output-ui-verified-attachments/` (reviewed capture)
- `/tmp/pi-remote-output-mac-final.log` and `/tmp/pi-remote-output-device-final.log`

The test commands remain in [native app verification](native-apps.md#automated-checks), [simulator coding setup](workflow-verification.md#simulator-coding-and-recovery) and [interface review](interface-verification.md#repeat-the-review). No images or binary result artifacts are committed.
