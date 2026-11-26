# Internet relay

This Cloudflare Worker pairs two outbound WebSocket connections and forwards the original TLS bytes. It accepts an authenticated host and one viewer per room. Only a Mac’s locally trusted viewing keys can authorize a remote stream. Pairing remains local. Disconnecting either side closes the room session.

## Deploy

With Node.js and a Cloudflare account, run these commands from this directory.

```sh
npx wrangler login
npx wrangler deploy
```

Use the HTTPS deployment URL in **Relay → Settings → Internet Relay** on the Mac. `GET /health` returns `Relay tunnel v1`. Start on the same Wi-Fi and connect once so the viewer receives the settings. Set your Cloudflare account’s billing and usage limits before making the relay available to others. Video throughput and session duration affect usage.

The service handles opaque TLS chunks up to 64 KiB. The room identifier is the SHA-256 hash of a 256-bit Mac secret, which the host sends as a bearer credential over HTTPS. Keep Cloudflare request tracing off or redact route paths and authorization headers when configuring logs. The durable object stores connection metadata only.
