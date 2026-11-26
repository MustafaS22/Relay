# Relay validation

## Development checklist

- [x] Phase 1 — Native Xcode targets, entitlements, schemes and shared package
- [x] Phase 2 — ScreenCaptureKit capture, display discovery, permission and preview implementation
- [x] Phase 3 — Hardware H.264 encode and decode, configuration and keyframe recovery
- [x] Phase 4 — Bonjour, certificate pinning, pairing, trust and TLS loopback
- [x] Phase 5 — iPhone viewer, display and quality selection, zoom and pan
- [x] Phase 6 — Reconnection, backpressure, adaptive quality and trust management implementation
- [x] Phase 7 — Native interfaces, app icons, menu bar and launch-at-login implementation
- [x] Phase 8 — Internet relay transport for paired viewers. Hosted transport passed. Physical streaming acceptance is pending.

## Verified

- Xcode 27.2 built both Apple Silicon macOS and iPhoneOS targets. The development-signed Mac app launched. The iOS build installed and displayed its device list on an iPhone 18 Pro simulator.
- The original ten tests passed on Apple Silicon, including TLS loopback, mismatched certificate rejection, a hardware H.264 encode/decode round trip, keyframe recovery after a sequence gap, pairing code expiration and attempt limits, and rejection of invalid messages and replayed identity proofs.

## Relay 1.1 release checks

- Twelve tests passed, including local-to-saved-address route selection, address validation, and compatibility with the existing authorization message.
- The signed Mac DMG verified with arm64 and x86_64 slices. The signed IPA verified with iPhone and iPad device families and a provisioning profile for the registered iPhone 16.
- Physical iPad installation requires signing with a provisioning profile that includes that iPad.

## Hosted relay checks

- Cloudflare deployment responded to `GET /health` over public HTTPS.
- The native Swift bridges negotiated Relay's pinned TLS through the live WebSocket Worker and exchanged a framed request and reply. This exercised the transport without capturing a display.
- The universal macOS 1.2.1 DMG verified with the relay URL preconfigured. The existing 1.2 mobile IPA supports that URL through its paired connection.

## Physical Mac, iPhone, and iPad

Physical device and internet streaming acceptance remains open. Use this checklist for the first device run.

- [ ] Build, sign, install and launch Relay on both devices.
- [ ] Grant Screen Recording and Local Network access. Confirm that the Mac preview reflects a real display.
- [ ] Discover the Mac on the same Wi-Fi. Verify QR pairing, fingerprint entry, code retry, expiration and Mac approval.
- [ ] Open and switch between Mac applications and Spaces. Verify the desktop, menu bar, Dock and cursor.
- [ ] Rotate the phone, switch displays and presets, and verify zoom, pan and Actual Pixels.
- [ ] Disconnect an external display and change display resolution while watching. Verify fallback and stream recovery.
- [ ] Interrupt Wi-Fi and restore it. Verify reconnect, accurate frozen-frame status and renewed authorization when configured.
- [ ] Pause and resume on both devices. Verify sharing can continue after the Mac window closes.
- [ ] Lock the Mac and separately test sleep. Confirm capture ends immediately and sharing resumes on unlock only when it was previously enabled.
- [ ] Stop sharing from the Mac and confirm frames stop. Revoke an iPhone’s trust and confirm it cannot reconnect without pairing again.
- [ ] Measure latency, frame rate and bitrate on the actual network. Sustained frame-rate, latency and battery targets are pending.

- [ ] Reconnect as an already paired device with automatic approval enabled. Verify there is no Relay prompt. Toggle the approval setting off and verify an approval request is shown instead.
- [ ] Pair an iPad. Test portrait, landscape, full-screen scaling, and switching displays.
- [ ] Put the Mac and viewer on separate networks. Confirm that the deployed HTTPS relay reaches the already paired Mac without a new code or approval.
- [ ] On an Intel Mac, verify ScreenCaptureKit and hardware H.264 encoding on the target model.
