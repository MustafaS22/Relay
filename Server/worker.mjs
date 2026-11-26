const hex32 = /^[a-f0-9]{64}$/;
const limit = 64 * 1024;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return new Response("Relay tunnel v1");
    const match = /^\/v1\/(host|viewer)\/([a-f0-9]{64})$/.exec(url.pathname);
    if (!match || request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Not found", { status: 404 });
    }
    const [, role, room] = match;
    if (role === "host") {
      const secret = request.headers.get("Authorization")?.replace(/^Bearer /, "");
      if (!secret || !hex32.test(secret)) return new Response("Unauthorized", { status: 401 });
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
      const route = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
      if (route !== room) return new Response("Unauthorized", { status: 401 });
    }
    return env.ROOMS.get(env.ROOMS.idFromName(room)).fetch(request);
  },
};

export class RelayRoom {
  constructor(state) {
    this.state = state;
  }

  fetch(request) {
    const role = new URL(request.url).pathname.split("/")[2];
    const host = this.open("host");
    if (role === "host" && host) return new Response("Host already connected", { status: 409 });
    if (role === "viewer" && !host) return new Response("Host unavailable", { status: 404 });
    if (role === "viewer" && (this.open("viewer") || host.deserializeAttachment()?.session)) {
      return new Response("Viewer already connected", { status: 409 });
    }
    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role });
    if (role === "viewer") {
      const session = crypto.randomUUID();
      host.serializeAttachment({ role: "host", session });
      server.serializeAttachment({ role: "viewer", session });
      host.send("ready");
      server.send("ready");
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  open(role) {
    return this.state.getWebSockets(role).find(socket => socket.readyState === WebSocket.OPEN);
  }

  webSocketMessage(socket, data) {
    const state = socket.deserializeAttachment();
    const peer = this.open(state?.role === "host" ? "viewer" : "host");
    if (!(data instanceof ArrayBuffer) || data.byteLength === 0 || data.byteLength > limit ||
        !state?.session || peer?.deserializeAttachment()?.session !== state.session) {
      socket.close(1008, "Invalid tunnel data");
      return;
    }
    peer.send(data);
  }

  webSocketClose(socket) {
    this.end(socket);
  }

  webSocketError(socket) {
    this.end(socket);
  }

  end(socket) {
    const item = socket.deserializeAttachment();
    if (item?.session) {
      const peer = this.open(item.role === "host" ? "viewer" : "host");
      if (peer?.deserializeAttachment()?.session === item.session) peer.close(1000, "Peer disconnected");
    }
    try { socket.close(1000, "Tunnel closed"); } catch {}
  }
}
