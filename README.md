# Relay

Relay streams a Mac or MacBook display to an iPhone or iPad over local Wi-Fi or the internet. The Mac uses ScreenCaptureKit and hardware H.264 encoding. The viewer uses VideoToolbox and AVFoundation. The Mac build supports Apple Silicon and Intel Macs with macOS 14 or later and hardware H.264 encoding. The mobile build requires iOS or iPadOS 17 or later.

## Build and install

1. Open `Relay.xcodeproj` in Xcode 16 or newer. The project uses a local Swift package and has no third-party dependencies.
2. Under **Signing & Capabilities**, choose your development team for both `RelayMac` and `RelayIOS`. Keep automatic signing enabled. If the iOS bundle identifier is unavailable to your team, choose a unique identifier.
3. Run **RelayMac → My Mac**. Select **Request Permission** and allow Relay under **System Settings → Privacy & Security → Screen & System Audio Recording**. Quit and rerun Relay if macOS requires a restart. Select **Show Preview** to check that capture works.
4. Connect and unlock your iPhone or iPad. Accept **Trust This Computer** if prompted and enable **Developer Mode** in **Settings → Privacy & Security** if Xcode requests it. Select **RelayIOS → your device** and run. Accept Relay’s **Local Network** prompt when it opens. If a development certificate prompt appears on the device, follow the instructions in **Settings → General → VPN & Device Management**.
5. Put both devices on the same Wi-Fi network. An Ethernet-connected Mac on the same LAN also works with Bonjour where the router permits it.

The same Relay IPA contains both iPhone and iPad support. A development IPA installs on devices listed in its Apple provisioning profile. A physical iPad must be registered before it can install that signed file.

Run shared tests on the Mac with `swift test --package-path RelayCore`. The suite uses a local TCP socket and the Mac’s hardware H.264 encoder and decoder. It works without granting screen capture permission.

## Pair and view

1. In Relay on the Mac, select **Start Sharing**, then **Pair a Device…**.
2. Scan the QR code shown by Relay with your iPhone or iPad camera and open the link. Alternatively, select the Mac in Relay on your viewer and enter the full fingerprint shown on the Mac.
3. Enter the temporary six-digit code now displayed on the Mac. Approve the device in the Mac’s pairing panel.
4. The device opens the live viewer. Rotate the device, pinch to zoom, drag to pan, or double-tap to toggle zoom. Tap once to hide or show controls. Use the display and quality menus to change the stream.
5. Stop sharing in the Mac window or menu bar. To remove a device’s authorization, select **Revoke** beside its name. Paired devices automatically pass Relay approval while sharing is enabled. To require approval each time, turn off **Allow paired devices without asking** in Mac Settings.

If Bonjour is unavailable, choose **Connect by IP Address** on your viewer. Use the Mac’s IP address from its Network settings and the fingerprint shown in Relay. The listener uses TCP port **47221**.

## Wi-Fi and internet viewing

For local viewing, put the Mac and iPhone or iPad on the same Wi-Fi and tap the Mac in Relay. Ethernet works on the same LAN if the network passes Bonjour. This path connects directly to the Mac.

For a different Wi-Fi network or mobile data, Relay uses an HTTPS WebSocket relay. Both devices make outbound connections. The relay forwards the original TLS connection between the devices and sees encrypted payloads. It never receives the Mac's TLS private key or a viewer’s pairing key.

1. Deploy the Cloudflare Worker in [Server](Server/README.md).
2. On the Mac, enter the deployed HTTPS URL in **Relay → Settings → Internet Relay** and start sharing.
3. Open the paired Mac once while both devices are on the same Wi-Fi. Relay learns the internet connection details during that authenticated session. No new pairing code is needed.
4. On another network, open that same Mac in Relay. Keep the Mac awake, unlocked, and sharing.

Relay approval is separate from macOS Screen Recording and iOS/iPadOS Local Network access. The operating system controls when it asks for those permissions.

## Architecture and security

- **RelayMac** owns the session, display picker and permissions, menu bar and optional launch at login. ScreenCaptureKit supplies pixel buffers. A serial capture queue sends them to a bounded hardware encoder. The Mac’s preview uses the same encoded output when enabled.
- **RelayCore** provides TLS over Network.framework, versioned length-prefixed control and frame messages, Keychain storage, challenge signing and decode helpers. The Mac generates a per-installation P-256 TLS identity. The viewer verifies its SHA-256 fingerprint, truncated to 128 bits, using the QR code or fingerprint entered directly from the Mac. Only then does it submit the six-digit code.
- **RelayIOS** browses Bonjour, stores pinned Macs in Keychain and proves possession of its own P-256 key against a fresh challenge on each connection. Pairing codes expire after two minutes, allow three guesses and are followed by explicit Mac approval. A trusted viewer still needs the Mac’s sharing switch enabled. Closing the Mac window leaves the menu bar controls available. Lock, sleep, permission loss and Stop Sharing terminate capture and connections.
- Frame receipts cap the number of frames sent ahead of the decoder. A sequence gap discards dependent frames until a new keyframe. Congestion can lower bitrate and resolution. Video and control data share one TLS 1.3 TCP connection. Relay stores credentials and preferences locally and keeps video frames in memory only.

| Preset | Short-edge target | Frame-rate cap | Starting bitrate |
| --- | ---: | ---: | ---: |
| Data Saver | 480 pixels | 15 fps | 0.75 Mbps |
| Balanced | 720 pixels | 30 fps | 2.2 Mbps |
| High | 1080 pixels | 30 fps | 4.5 Mbps |
| Ultra | 1080 pixels | 60 fps | 8 Mbps |
| Native | Display pixels, capped to 4096 on the long edge | 60 fps | 16 Mbps |

Capture rates vary with on-screen activity. The viewer labels latency as an estimate and displays a round-trip-time-based uncertainty. It measures from the Mac capture callback to enqueue on the iPhone. It excludes display scanout and may be affected by asymmetric network delay.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Preview unavailable | Check Screen & System Audio Recording permission and reopen the Mac app. |
| Mac missing | Turn on sharing or open the pairing panel. Check that both devices are on the same LAN and that your Wi-Fi permits device-to-device traffic. For discovery failures, try the Mac’s IP address. |
| Local Network denied | Allow Relay in the iPhone’s **Settings → Privacy & Security → Local Network**, then reopen it. |
| Connection times out | Wake and unlock the Mac, check that sharing is on and allow Relay in the Mac firewall. Across networks, check the Internet Relay URL on Mac and make one direct connection to update the saved details. |
| Fingerprint rejected | Use the fingerprint currently shown by the Mac. If the Mac was reinstalled or its Keychain reset, forget the old Mac on the viewer and pair again. |
| Paused or frozen picture | Check for a viewing request on the Mac. If the connection drops, Relay retries paired Macs with backoff. After Mac lock or sleep, unlock it before reconnecting. |
| Blank protected window | macOS can exclude protected content. |

## Scope and release status

Relay supports one viewer at a time. Macs and MacBooks host streams. iPhones and iPads view them. Cross-network use needs a deployed internet relay. HEVC, audio, and remote input are outside this build.

See [development and physical-device validation](Documentation/Validation.md) for the verified checks and remaining release gate.
