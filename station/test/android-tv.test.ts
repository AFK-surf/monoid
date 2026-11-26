// Unit & integration tests for Android TV / Google TV / Android TV box support:
// - RSA-2048 self-signed X.509 v3 cert generation + modulus/exponent extraction
// - Remote v2 Protobuf codec, TLS :6467 pairing (wrong PIN retry + valid 6-char hex PIN + cert pin) & :6466 control
// - mDNS DNS-SD multi-service packet parsing & merging + manual TCP port probe
// - ADB wireless 6-digit pairing, legacy :5555 unauthorized->device retry, control actions, PNG IHDR screenshot
// - Single-port 4-byte HTTP vs ADB transparent demux on the same local forwarded port
// - commitAnyDeviceAdd (duplicate name preserves pairId) & commitDeviceRebind (target check, empty creds, merge)
// - Encrypted credential storage (0600, AAD, delete) & zero main-thread *Sync calls
import assert from "node:assert/strict";
import { randomBytes, X509Certificate } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import net, { type AddressInfo, createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import tls from "node:tls";
import { StationKey } from "../src/cloud/key.ts";
import { AirPlayPairingManager } from "../src/devices/airplay/pairing.ts";
import type { AirPlayAdapter } from "../src/devices/airplay/types.ts";
import {
  AndroidTvAdbClient,
  escapeAdbInputText,
  parsePngDimensions,
  quoteAndroidShellArg,
} from "../src/devices/android-tv/adb-client.ts";
import { LocalAndroidTvAdapter } from "../src/devices/android-tv/adapter.ts";
import {
  certSha256Hex,
  computePairingSecretHash,
  derX509Time,
  extractRsaModulusExponent,
  generateClientCert,
} from "../src/devices/android-tv/cert.ts";
import {
  buildMdnsQuery,
  mergeMdnsRecords,
  parseMdnsPacket,
  probeAndroidTvHost,
} from "../src/devices/android-tv/discovery.ts";
import {
  AndroidTvPairingManager,
  commitAnyDeviceAdd,
  commitDeviceRebind,
} from "../src/devices/android-tv/pairing.ts";
import {
  decodePairingMessage,
  decodeRemoteMessage,
  encodePairingRequest,
  encodeRemoteConfigure,
  encodeRemoteKeyInject,
  frameMessage,
  FrameReader,
  PAIRING_PROTOCOL_VERSION,
  PAIRING_STATUS_OK,
  pbBytes,
  pbMessage,
  pbString,
  pbVarint,
  resolveAndroidKeyCode,
} from "../src/devices/android-tv/proto.ts";
import { AndroidTvRemoteClient } from "../src/devices/android-tv/remote-client.ts";
import {
  AndroidTvControlServer,
  fetchAndroidTvScreenshot,
  sendAndroidTvAction,
} from "../src/devices/android-tv/server.ts";
import { AndroidTvError, type AndroidTvCredentials } from "../src/devices/android-tv/types.ts";
import { reachDevice } from "../src/devices/connect.ts";
import { DeviceCredentialStore } from "../src/devices/credentials.ts";
import { DeviceRegistry } from "../src/devices/registry.ts";
import { Forwards } from "../src/mesh/peer-forward.ts";
import { syncCalls } from "./main-thread-sync.ts";

const PAT = { sub: "pat", email: "pat@example.com", name: "Pat" };

function buildValidPng(width: number, height: number): Buffer {
  const magic = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdrData = Buffer.alloc(13);
  ihdrData.writeUInt32BE(width, 0);
  ihdrData.writeUInt32BE(height, 4);
  ihdrData[8] = 8; // bit depth
  ihdrData[9] = 2; // RGB
  const ihdrLen = Buffer.alloc(4);
  ihdrLen.writeUInt32BE(13, 0);
  const ihdrType = Buffer.from("IHDR", "ascii");
  const crc = Buffer.alloc(4);
  const iend = Buffer.from([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);
  return Buffer.concat([magic, ihdrLen, ihdrType, ihdrData, crc, iend]);
}

function encodeDnsName(name: string): Buffer {
  const parts = name.replace(/\.$/, "").split(".").filter(Boolean);
  return Buffer.concat([...parts.flatMap((p) => [Buffer.from([p.length]), Buffer.from(p, "utf8")]), Buffer.from([0])]);
}

function dnsRecord(name: string, type: number, rdata: Buffer): Buffer {
  const tail = Buffer.alloc(10);
  tail.writeUInt16BE(type, 0);
  tail.writeUInt16BE(1, 2); // IN
  tail.writeUInt32BE(120, 4); // TTL
  tail.writeUInt16BE(rdata.length, 8);
  return Buffer.concat([encodeDnsName(name), tail, rdata]);
}

test("android-tv cert: generates valid RSA-2048 X.509 v3 cert, RFC 5280 UTCTime/GeneralizedTime, and extracts modulus/exponent", async () => {
  // RFC 5280 §4.1.2.5: 1950-2049 -> UTCTime (0x17), 2050+ -> GeneralizedTime (0x18)
  const ms2026 = Date.UTC(2026, 10, 26, 12, 0, 0);
  const ms2055 = Date.UTC(2055, 5, 15, 8, 30, 0);
  const t2026 = derX509Time(ms2026);
  const t2055 = derX509Time(ms2055);
  assert.equal(t2026[0], 0x17);
  assert.equal(t2026.subarray(2).toString("ascii"), "261126120000Z");
  assert.equal(t2055[0], 0x18);
  assert.equal(t2055.subarray(2).toString("ascii"), "20550615083000Z");

  const cert2026 = await generateClientCert({ commonName: "still.fail", nowMs: ms2026 });
  assert.match(cert2026.certPem, /-----BEGIN CERTIFICATE-----/);
  assert.match(cert2026.keyPem, /-----BEGIN PRIVATE KEY-----/);
  const x509 = new X509Certificate(cert2026.certPem);
  assert.equal(x509.subject, "CN=still.fail");
  assert.equal(x509.issuer, "CN=still.fail");
  assert.equal(x509.verify(x509.publicKey), true);
  assert.match(x509.validFrom, /2026/);
  assert.match(x509.validTo, /2036/);
  const { modulus, exponent } = extractRsaModulusExponent(x509);
  assert.equal(modulus.length, 256); // 2048-bit RSA modulus, no leading 0x00
  assert.notEqual(modulus[0], 0);
  assert.deepEqual(exponent, Buffer.from([0x01, 0x00, 0x01]));
  assert.match(certSha256Hex(x509), /^[0-9a-f]{64}$/);

  const cert2055 = await generateClientCert({ commonName: "still.fail", nowMs: ms2055 });
  const x509Future = new X509Certificate(cert2055.certPem);
  assert.equal(x509Future.verify(x509Future.publicKey), true);
  assert.match(x509Future.validFrom, /2055/);
  assert.match(x509Future.validTo, /2065/);
});

test("android-tv proto: varint framing, pairing/remote codec, and keycode mapping", () => {
  const req = encodePairingRequest("still.fail", "still.fail");
  const decodedReq = decodePairingMessage(req);
  assert.equal(decodedReq.protocolVersion, PAIRING_PROTOCOL_VERSION);
  assert.equal(decodedReq.status, PAIRING_STATUS_OK);
  assert.equal(decodedReq.kind, "pairing_request");
  assert.equal(decodedReq.serviceName, "still.fail");

  const framed = Buffer.concat([frameMessage(encodeRemoteConfigure({ model: "Shield" })), frameMessage(encodeRemoteKeyInject(23, 3))]);
  const reader = new FrameReader();
  const frames: Buffer[] = [];
  // Feed 1 byte at a time to test incremental framing
  for (let i = 0; i < framed.length; i++) {
    frames.push(...reader.push(framed.subarray(i, i + 1)));
  }
  assert.equal(frames.length, 2);
  const m0 = decodeRemoteMessage(frames[0]!);
  assert.equal(m0.kind, "remote_configure");
  if (m0.kind === "remote_configure") assert.equal(m0.model, "Shield");
  const m1 = decodeRemoteMessage(frames[1]!);
  assert.equal(m1.kind, "remote_key_inject");
  if (m1.kind === "remote_key_inject") {
    assert.equal(m1.keyCode, 23);
    assert.equal(m1.direction, 3);
  }

  assert.equal(resolveAndroidKeyCode("up"), 19);
  assert.equal(resolveAndroidKeyCode("select"), 23);
  assert.equal(resolveAndroidKeyCode("home"), 3);
  assert.equal(resolveAndroidKeyCode("power_on"), 224);
  assert.equal(resolveAndroidKeyCode("9"), 16);
  assert.equal(resolveAndroidKeyCode("26"), 26);
  assert.equal(resolveAndroidKeyCode("not_a_key"), null);
});

test("android-tv Remote v2: mock TLS :6467 pairing (wrong PIN retry -> valid PIN) and :6466 control with cert pinning", async () => {
  const serverCert = await generateClientCert({ commonName: "Shield TV" });
  const serverX509 = new X509Certificate(serverCert.certPem);
  const pinSuffix = Buffer.from([0x3f, 0x9c]);
  let expectedPin = "";

  // Mock Pairing server (:6467)
  const pairServer = tls.createServer(
    { key: serverCert.keyPem, cert: serverCert.certPem, requestCert: true, rejectUnauthorized: false },
    (sock) => {
      const reader = new FrameReader();
      sock.on("data", (chunk: Buffer) => {
        for (const frame of reader.push(chunk)) {
          const msg = decodePairingMessage(frame);
          if (msg.kind === "pairing_request") {
            const ack = Buffer.concat([
              pbVarint(1, 2),
              pbVarint(2, 200),
              pbMessage(11, [pbString(1, "NVIDIA Shield TV")]),
            ]);
            sock.write(frameMessage(ack));
          } else if (msg.kind === "pairing_option") {
            const opt = Buffer.concat([
              pbVarint(1, 2),
              pbVarint(2, 200),
              pbMessage(20, [pbVarint(3, 2)]),
            ]);
            sock.write(frameMessage(opt));
          } else if (msg.kind === "pairing_configuration") {
            const peer = sock.getPeerCertificate(false);
            const hash = computePairingSecretHash({
              clientCert: peer.raw,
              serverCert: serverX509,
              pinSuffix,
            });
            expectedPin = Buffer.from([hash[0]!, pinSuffix[0]!, pinSuffix[1]!]).toString("hex").toUpperCase();
            const ack = Buffer.concat([pbVarint(1, 2), pbVarint(2, 200), pbMessage(31, [])]);
            sock.write(frameMessage(ack));
          } else if (msg.kind === "pairing_secret") {
            const peer = sock.getPeerCertificate(false);
            const hash = computePairingSecretHash({
              clientCert: peer.raw,
              serverCert: serverX509,
              pinSuffix,
            });
            const ok = msg.secret !== undefined && msg.secret.equals(hash);
            const ack = Buffer.concat([
              pbVarint(1, 2),
              pbVarint(2, ok ? 200 : 402),
              pbMessage(41, [pbBytes(1, hash)]),
            ]);
            sock.write(frameMessage(ack));
          }
        }
      });
    },
  );
  await new Promise<void>((r) => pairServer.listen(0, "127.0.0.1", r));
  const pairPort = (pairServer.address() as AddressInfo).port;

  // Mock Remote server (:6466)
  const receivedActions: string[] = [];
  const remoteServer = tls.createServer(
    { key: serverCert.keyPem, cert: serverCert.certPem, requestCert: true, rejectUnauthorized: false },
    (sock) => {
      const reader = new FrameReader();
      // Server initiates with remote_configure + ping + remote_set_active + remote_start + volume
      sock.write(frameMessage(encodeRemoteConfigure({ model: "NVIDIA Shield TV", vendor: "NVIDIA" })));
      sock.on("data", (chunk: Buffer) => {
        for (const frame of reader.push(chunk)) {
          const msg = decodeRemoteMessage(frame);
          if (msg.kind === "remote_configure") {
            sock.write(frameMessage(pbMessage(8, [pbVarint(1, 77)]))); // ping request
            sock.write(frameMessage(pbMessage(2, [pbVarint(1, 622)]))); // set_active
          } else if (msg.kind === "remote_ping_response") {
            receivedActions.push(`pong:${msg.val1}`);
          } else if (msg.kind === "remote_set_active") {
            sock.write(frameMessage(pbMessage(40, [pbVarint(1, 1)]))); // started=true
            sock.write(frameMessage(pbMessage(50, [pbString(3, "Shield"), pbVarint(6, 15), pbVarint(7, 9), pbVarint(8, 0)])));
          } else if (msg.kind === "remote_key_inject") {
            receivedActions.push(`key:${msg.keyCode}:${msg.direction}`);
          } else if (msg.kind === "remote_app_link_launch_request") {
            receivedActions.push(`launch:${msg.appLink}`);
          } else if (msg.kind === "remote_ime_batch_edit") {
            receivedActions.push(`ime:${msg.text ?? ""}`);
          }
        }
      });
    },
  );
  await new Promise<void>((r) => remoteServer.listen(0, "127.0.0.1", r));
  const remotePort = (remoteServer.address() as AddressInfo).port;

  const client = new AndroidTvRemoteClient();
  try {
    const started = await client.pairStart({ host: "127.0.0.1", pairPort, remotePort });
    assert.equal(started.serverName, "NVIDIA Shield TV");
    assert.match(expectedPin, /^[0-9A-F]{6}$/);

    // Wrong PIN checksum fails without killing the session
    const wrongFirstByte = ((parseInt(expectedPin.slice(0, 2), 16) ^ 0xff) & 0xff).toString(16).toUpperCase().padStart(2, "0");
    await assert.rejects(
      client.pairFinish({ pairToken: started.pairToken, pin: `${wrongFirstByte}${expectedPin.slice(2)}` }),
      (e: unknown) => e instanceof AndroidTvError && e.code === "invalid_pin",
    );

    // Correct PIN succeeds and returns pinned server cert SHA-256
    const finished = await client.pairFinish({ pairToken: started.pairToken, pin: expectedPin });
    assert.equal(finished.credentials.serverCertSha256, certSha256Hex(serverX509));
    assert.equal(finished.model, "NVIDIA Shield TV");

    // Control with mismatched fingerprint fails with auth_failed
    await assert.rejects(
      client.control({
        host: "127.0.0.1",
        remotePort,
        credentials: { ...finished.credentials, serverCertSha256: "00".repeat(32) },
        action: "status",
      }),
      (e: unknown) => e instanceof AndroidTvError && e.code === "auth_failed",
    );

    // Control with valid credentials executes status, remote, launch, keyboard, and handles ping->pong
    const status = (await client.control({ host: "127.0.0.1", remotePort, credentials: finished.credentials, action: "status" })) as any;
    assert.equal(status.online, true);
    assert.equal(status.power, "on");
    assert.equal(status.volume, 9);
    assert.equal(status.volumeMax, 15);
    assert.ok(receivedActions.includes("pong:77"));

    await client.control({ host: "127.0.0.1", remotePort, credentials: finished.credentials, action: "remote", args: { key: "select", press: "double" } });
    await client.control({ host: "127.0.0.1", remotePort, credentials: finished.credentials, action: "launch", args: { app: "https://www.youtube.com/tv" } });
    await client.control({ host: "127.0.0.1", remotePort, credentials: finished.credentials, action: "keyboard", args: { text: "hello tv" } });

    // Wait a tick for server socket data handlers to drain
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(receivedActions.filter((x) => x === "key:23:3").length >= 2);
    assert.ok(receivedActions.includes("launch:https://www.youtube.com/tv"));
    assert.ok(receivedActions.includes("ime:hello tv"));
  } finally {
    await client.close();
    await new Promise<void>((r) => pairServer.close(() => r()));
    await new Promise<void>((r) => remoteServer.close(() => r()));
  }
});

test("android-tv discovery: merges multi-service mDNS records by IP and probes manual host ports", async () => {
  const q = buildMdnsQuery(["_androidtvremote2._tcp.local", "_adb-tls-connect._tcp.local"]);
  assert.equal(q.readUInt16BE(4), 2);

  // Build synthetic mDNS response with Remote v2 + ADB TLS connect + ADB TLS pairing for 192.168.1.52
  const hdr = Buffer.alloc(12);
  hdr.writeUInt16BE(0x8400, 2); // response
  hdr.writeUInt16BE(8, 6); // 8 answer records
  const srvRdata = (port: number, target: string) => {
    const pre = Buffer.alloc(6);
    pre.writeUInt16BE(port, 4);
    return Buffer.concat([pre, encodeDnsName(target)]);
  };
  const txtRdata = (entries: string[]) => Buffer.concat(entries.map((e) => Buffer.concat([Buffer.from([e.length]), Buffer.from(e, "utf8")])));
  const pkt = Buffer.concat([
    hdr,
    dnsRecord("_androidtvremote2._tcp.local", 12, encodeDnsName("ShieldTV._androidtvremote2._tcp.local")),
    dnsRecord("ShieldTV._androidtvremote2._tcp.local", 33, srvRdata(6466, "shield.local")),
    dnsRecord("ShieldTV._androidtvremote2._tcp.local", 16, txtRdata(["name=Living Room Shield", "md=NVIDIA Shield TV"])),
    dnsRecord("_adb-tls-connect._tcp.local", 12, encodeDnsName("adb-123._adb-tls-connect._tcp.local")),
    dnsRecord("adb-123._adb-tls-connect._tcp.local", 33, srvRdata(41234, "shield.local")),
    dnsRecord("_adb-tls-pairing._tcp.local", 12, encodeDnsName("pair-123._adb-tls-pairing._tcp.local")),
    dnsRecord("pair-123._adb-tls-pairing._tcp.local", 33, srvRdata(37123, "shield.local")),
    dnsRecord("shield.local", 1, Buffer.from([192, 168, 1, 52])),
  ]);

  const parsed = parseMdnsPacket(pkt);
  const candidates = mergeMdnsRecords([parsed]);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0]!.address, "192.168.1.52");
  assert.equal(candidates[0]!.name, "Living Room Shield");
  assert.equal(candidates[0]!.model, "NVIDIA Shield TV");
  assert.equal(candidates[0]!.remotePort, 6466);
  assert.equal(candidates[0]!.adbPort, 41234);
  assert.equal(candidates[0]!.adbPairPort, 37123);
  assert.deepEqual(candidates[0]!.protocols.map((p) => p.protocol), ["atv_remote", "adb"]);

  // Manual TCP probe against local ephemeral servers
  const sRemote = createTcpServer((s) => s.end());
  const sAdb = createTcpServer((s) => s.end());
  await new Promise<void>((r) => sRemote.listen(0, "127.0.0.1", r));
  await new Promise<void>((r) => sAdb.listen(0, "127.0.0.1", r));
  try {
    const rPort = (sRemote.address() as AddressInfo).port;
    const aPort = (sAdb.address() as AddressInfo).port;
    const probed = await probeAndroidTvHost(`127.0.0.1:${aPort}`, { remotePairPort: rPort, timeoutMs: 1000 });
    assert.equal(probed.length, 1);
    assert.equal(probed[0]!.address, "127.0.0.1");
    assert.equal(probed[0]!.adbPort, aPort);
    assert.deepEqual(probed[0]!.protocols.map((p) => p.protocol), ["atv_remote", "adb"]);
  } finally {
    await new Promise<void>((r) => sRemote.close(() => r()));
    await new Promise<void>((r) => sAdb.close(() => r()));
  }
});

test("android-tv ADB: wireless pair, legacy unauthorized->device retry, control actions, and PNG IHDR screenshot", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-atv-adb-"));
  const pngBytes = buildValidPng(1920, 1080);
  assert.deepEqual(parsePngDimensions(pngBytes), { width: 1920, height: 1080 });
  assert.throws(() => parsePngDimensions(Buffer.from("not a png")), /valid PNG/);

  // Shell quoting & input text hardening (prevents & truncation, ;/$() injection, and newline command split)
  assert.equal(quoteAndroidShellArg("https://youtu.be/x?v=1&t=30;id"), "'https://youtu.be/x?v=1&t=30;id'");
  assert.equal(quoteAndroidShellArg("a'b"), "'a'\\''b'");
  assert.throws(
    () => quoteAndroidShellArg("https://example.com/\nid"),
    (e: unknown) => e instanceof AndroidTvError && e.code === "invalid_params",
  );
  assert.equal(escapeAdbInputText("hello world; rm -rf /"), "hello%sworld\\;%srm%s-rf%s/");
  const escapedMultiline = escapeAdbInputText("hello\nid\r\n&'$(whoami)'");
  assert.doesNotMatch(escapedMultiline, /[\r\n]/);
  assert.equal(escapedMultiline, "hello%sid%s\\&\\'\\$\\(whoami\\)\\'");
  assert.throws(
    () => escapeAdbInputText("bad\x00input"),
    (e: unknown) => e instanceof AndroidTvError && e.code === "invalid_params",
  );

  let legacyAuthCount = 0;
  const adbLog: string[][] = [];
  const adb = new AndroidTvAdbClient({
    dataDir: dir,
    exec: async (args) => {
      adbLog.push(args);
      if (args[0] === "pair") {
        if (args[2] !== "123456") return { code: 1, stdout: Buffer.from("Failed: Wrong password"), stderr: Buffer.alloc(0) };
        return { code: 0, stdout: Buffer.from("Successfully paired to 192.168.1.52:37123"), stderr: Buffer.alloc(0) };
      }
      if (args[0] === "connect") {
        return { code: 0, stdout: Buffer.from(`connected to ${args[1]}`), stderr: Buffer.alloc(0) };
      }
      if (args[2] === "get-state") {
        if (args[1] === "192.168.1.52:5555") {
          legacyAuthCount++;
          if (legacyAuthCount === 1) return { code: 1, stdout: Buffer.alloc(0), stderr: Buffer.from("error: device unauthorized.") };
        }
        return { code: 0, stdout: Buffer.from("device\n"), stderr: Buffer.alloc(0) };
      }
      if (args[2] === "exec-out" && args[3] === "screencap") {
        return { code: 0, stdout: pngBytes, stderr: Buffer.alloc(0) };
      }
      if (args[2] === "shell") {
        const cmd = args.slice(3).join(" ");
        if (cmd === "getprop ro.product.model") return { code: 0, stdout: Buffer.from("Xiaomi Mi Box S\n"), stderr: Buffer.alloc(0) };
        if (cmd === "getprop ro.product.manufacturer") return { code: 0, stdout: Buffer.from("Xiaomi\n"), stderr: Buffer.alloc(0) };
        if (cmd === "getprop ro.build.version.release") return { code: 0, stdout: Buffer.from("12\n"), stderr: Buffer.alloc(0) };
        if (cmd === "dumpsys power") return { code: 0, stdout: Buffer.from("mWakefulness=Awake\n"), stderr: Buffer.alloc(0) };
        if (cmd === "dumpsys window displays") return { code: 0, stdout: Buffer.from("mCurrentFocus=Window{1 u0 com.google.android.youtube.tv/Main}\n"), stderr: Buffer.alloc(0) };
        if (cmd.startsWith("cmd media_session volume")) return { code: 0, stdout: Buffer.from("volume is 8 in range [0..15]\n"), stderr: Buffer.alloc(0) };
        if (cmd === "pm list packages -3") return { code: 0, stdout: Buffer.from("package:com.netflix.ninja\npackage:com.google.android.youtube.tv\n"), stderr: Buffer.alloc(0) };
        return { code: 0, stdout: Buffer.from("ok\n"), stderr: Buffer.alloc(0) };
      }
      return { code: 0, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) };
    },
  });

  try {
    // Wireless pairing
    await assert.rejects(
      adb.pairWireless({ host: "192.168.1.52", pairPort: 37123, pin: "12ab56", connectPort: 41234 }),
      (e: unknown) => e instanceof AndroidTvError && e.code === "invalid_pin",
    );
    const wireless = await adb.pairWireless({ host: "192.168.1.52", pairPort: 37123, pin: "123456", connectPort: 41234 });
    assert.equal(wireless.credentials.serial, "192.168.1.52:41234");
    assert.equal(wireless.credentials.mode, "tls_wireless");
    assert.equal(wireless.model, "Xiaomi Mi Box S");

    // Legacy :5555 unauthorized first -> authorized on retry
    await assert.rejects(
      adb.connectLegacy("192.168.1.52", 5555),
      (e: unknown) => e instanceof AndroidTvError && e.code === "adb_unauthorized",
    );
    const legacy = await adb.connectLegacy("192.168.1.52", 5555);
    assert.equal(legacy.credentials.serial, "192.168.1.52:5555");

    // Control actions & screenshot
    const status = (await adb.control("192.168.1.52:5555", "status")) as any;
    assert.equal(status.model, "Xiaomi Mi Box S");
    assert.equal(status.power, "on");
    assert.equal(status.foregroundApp, "com.google.android.youtube.tv");
    assert.equal(status.volume, 8);

    const apps = (await adb.control("192.168.1.52:5555", "apps")) as any;
    assert.deepEqual(apps.apps.map((a: any) => a.id), ["com.netflix.ninja", "com.google.android.youtube.tv"]);

    await adb.control("192.168.1.52:5555", "launch", { app: "com.netflix.ninja" });
    assert.ok(adbLog.some((a) => a.includes("android.intent.category.LEANBACK_LAUNCHER")));

    // URL launch & play_url must single-quote URLs containing & and ; and reject control chars
    const trickyUrl = "https://youtu.be/x?v=1&t=30;id";
    await adb.control("192.168.1.52:5555", "launch", { app: trickyUrl });
    assert.ok(adbLog.some((a) => a.includes("am") && a.includes(`'${trickyUrl}'`)));
    await adb.control("192.168.1.52:5555", "play_url", { url: trickyUrl });
    assert.ok(adbLog.filter((a) => a.includes("am") && a.includes(`'${trickyUrl}'`)).length >= 2);
    await assert.rejects(
      adb.control("192.168.1.52:5555", "play_url", { url: "https://example.com/\nid" }),
      (e: unknown) => e instanceof AndroidTvError && e.code === "invalid_params",
    );

    const shot = await adb.screenshot("192.168.1.52:5555");
    assert.equal(shot.width, 1920);
    assert.equal(shot.height, 1080);
    assert.equal(shot.png.length, pngBytes.length);
  } finally {
    await adb.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("android-tv single-port 4-byte demux: HTTP /action + /screenshot AND raw ADB 000chost:version on the exact same port", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-atv-demux-"));
  const pngBytes = buildValidPng(1280, 720);
  const key = new StationKey(randomBytes(32));
  const creds = new DeviceCredentialStore<Record<string, unknown>>(dir, key);
  const devId = "0123456789abcdef";
  const stored: AndroidTvCredentials = {
    adb: { host: "192.168.1.52", port: 5555, mode: "legacy_tcp", serial: "192.168.1.52:5555" },
  };
  await creds.set("ws", devId, stored);

  // Mock isolated ADB server speaking real ADB protocol (`000chost:version` -> `OKAY00040029`)
  const mockAdbServer = createTcpServer((sock) => {
    let acc = "";
    sock.on("data", (c: Buffer) => {
      acc += c.toString("ascii");
      if (acc === "000chost:version") {
        sock.write("OKAY00040029");
        sock.end();
      }
    });
  });
  await new Promise<void>((r) => mockAdbServer.listen(0, "127.0.0.1", r));
  const mockAdbPort = (mockAdbServer.address() as AddressInfo).port;

  const adbClient = new AndroidTvAdbClient({
    dataDir: dir,
    exec: async (args) => {
      if (args[2] === "get-state") return { code: 0, stdout: Buffer.from("device\n"), stderr: Buffer.alloc(0) };
      if (args[2] === "exec-out" && args[3] === "screencap") return { code: 0, stdout: pngBytes, stderr: Buffer.alloc(0) };
      return { code: 0, stdout: Buffer.from("ok\n"), stderr: Buffer.alloc(0) };
    },
    openRaw: () =>
      new Promise<net.Socket>((resolve, reject) => {
        const s = net.connect({ host: "127.0.0.1", port: mockAdbPort, allowHalfOpen: true });
        s.once("error", reject);
        s.once("connect", () => {
          s.pause();
          resolve(s);
        });
      }),
  });
  const adapter = new LocalAndroidTvAdapter({ dataDir: dir, adb: adbClient });
  const server = new AndroidTvControlServer(adapter, creds);
  const forwards = new Forwards({ route: () => null, resolve: (s) => ({ id: s, name: s }) });

  try {
    const dev = { id: devId, ws: "ws", name: "Shield TV", kind: "android_tv" as const, target: "192.168.1.52", protocols: ["adb" as const] };
    const v = await forwards.openDevice("s1", "self", {
      id: devId,
      name: "Shield TV",
      here: () => reachDevice(dev, undefined, server),
      admit: null,
    }, true);
    const port = Number(v.local.split(":")[1]);

    // 1. HTTP POST /action over the forwarded port
    const actionRes = (await sendAndroidTvAction(port, "remote", { key: "home" })) as any;
    assert.equal(actionRes.ok, true);
    assert.equal(actionRes.keyCode, 3);

    // 2. HTTP POST /screenshot over the same forwarded port
    const shotPath = join(dir, "tv-shot.png");
    const shotRes = await fetchAndroidTvScreenshot(port, shotPath);
    assert.equal(shotRes.ok, true);
    assert.equal(shotRes.width, 1280);
    assert.equal(shotRes.height, 720);
    assert.equal(shotRes.bytes, pngBytes.length);
    assert.ok(readFileSync(shotPath).equals(pngBytes));

    // 3. Raw ADB frame `000chost:version` over the EXACT SAME forwarded port (sent in 2 chunks to verify buffering!)
    const adbReply = await new Promise<string>((resolve, reject) => {
      const s = net.connect({ host: "127.0.0.1", port });
      let out = "";
      s.on("data", (c: Buffer) => (out += c.toString("ascii")));
      s.once("error", reject);
      s.once("end", () => resolve(out));
      s.once("connect", () => {
        s.write("00");
        s.write("0chost:version");
      });
    });
    assert.equal(adbReply, "OKAY00040029");
  } finally {
    await forwards.close();
    server.close();
    await adapter.close();
    await new Promise<void>((r) => mockAdbServer.close(() => r()));
    rmSync(dir, { recursive: true, force: true });
  }
});

test("android-tv pairing manager, commitAnyDeviceAdd (duplicate name keeps pairId), commitDeviceRebind, and encrypted credentials", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-atv-pair-"));
  const key = new StationKey(randomBytes(32));
  const creds = new DeviceCredentialStore<Record<string, unknown>>(dir, key);
  const registry = new DeviceRegistry(new DatabaseSync(":memory:"));

  // Stub AirPlay manager (unused in android_tv path)
  const stubAirPlayAdapter = {} as AirPlayAdapter;
  const airplayPairing = new AirPlayPairingManager(stubAirPlayAdapter);

  // Stub Android TV adapter
  let tokSeq = 1;
  const tokens = new Map<string, "atv_remote" | "adb">();
  const atvPairing = new AndroidTvPairingManager({
    envStatus: async () => ({ ready: true, adbAvailable: true }),
    scan: async () => [],
    pairStart: async (p) => {
      const tok = `tok-${tokSeq++}`;
      tokens.set(tok, p.protocol);
      return { pairToken: tok, protocol: p.protocol, deviceProvidesPin: true };
    },
    pairFinish: async (p) => {
      const proto = tokens.get(p.pairToken);
      if (!proto) throw new AndroidTvError("invalid_pair_token", "missing");
      if (proto === "atv_remote") {
        if (p.pin !== "A3F19C") throw new AndroidTvError("invalid_pin", "wrong");
        tokens.delete(p.pairToken);
        return {
          protocol: "atv_remote",
          model: "NVIDIA Shield TV",
          credentials: { certPem: "CERT", keyPem: "KEY", host: "192.168.1.52", remotePort: 6466, pairPort: 6467 },
        };
      }
      tokens.delete(p.pairToken);
      return {
        protocol: "adb",
        credentials: { host: "192.168.1.52", port: 5555, mode: "legacy_tcp", serial: "192.168.1.52:5555" },
      };
    },
    pairCancel: async (p) => { tokens.delete(p.pairToken); },
    control: async () => ({}),
    screenshot: async () => ({ png: buildValidPng(10, 10), width: 10, height: 10 }),
    ensureAdbConnected: async () => ({ serial: "192.168.1.52:5555" }),
    openRawAdbConnection: async () => { throw new Error("unused"); },
    close: async () => {},
  });

  try {
    // Add an existing device to test duplicate-name collision
    assert.ok(typeof registry.add("ws", PAT, { name: "Shield TV", kind: "tcp", target: "10.0.0.2:80" }, 1) !== "string");

    // Step 1: pair atv_remote only
    const s1 = await atvPairing.start({ ws: "ws", identifier: "192.168.1.52", protocols: ["atv_remote"] });
    assert.equal(s1.done, false);
    assert.ok(s1.pairId.startsWith("atv_"));
    // Wrong PIN keeps pairToken alive
    await assert.rejects(atvPairing.finish("ws", s1.pairId, { pin: "000000" }), /wrong/);
    const s2 = await atvPairing.finish("ws", s1.pairId, { pin: "A3F19C" });
    assert.equal(s2.done, true);

    // Duplicate name fails, MUST preserve pairId for retry
    const dup = await commitAnyDeviceAdd(registry, { airplay: airplayPairing, androidTv: atvPairing }, creds, "ws", PAT, {
      name: "Shield TV",
      kind: "android_tv",
      target: "192.168.1.52",
      pairId: s1.pairId,
    }, 10);
    assert.equal(dup.ok, false);
    assert.ok(atvPairing.peekCredentials("ws", s1.pairId) !== null);

    // Renamed retry succeeds and consumes pairId
    const added = await commitAnyDeviceAdd(registry, { airplay: airplayPairing, androidTv: atvPairing }, creds, "ws", PAT, {
      name: "Living Room Shield",
      kind: "android_tv",
      target: "192.168.1.52",
      pairId: s1.pairId,
    }, 11);
    assert.equal(added.ok, true);
    if (!added.ok) return;
    assert.equal(added.device.model, "NVIDIA Shield TV");
    assert.deepEqual(added.device.protocols, ["atv_remote"]);
    assert.equal(added.device.paired, true);
    assert.equal(atvPairing.peekCredentials("ws", s1.pairId), null);

    // Verify encrypted credential file permissions (0600) and AAD binding
    const encFile = join(dir, "devices", "credentials", `${added.device.id}.enc`);
    assert.ok(existsSync(encFile));
    if (process.platform !== "win32") {
      assert.equal(statSync(encFile).mode & 0o777, 0o600);
    }
    await assert.rejects(creds.get("wrong-ws", added.device.id));

    // Rebind with mismatched target fails
    const badStart = await atvPairing.start({ ws: "ws", identifier: "192.168.1.99", protocols: ["adb"] });
    await atvPairing.finish("ws", badStart.pairId, {});
    const badRebind = await commitDeviceRebind(registry, { airplay: airplayPairing, androidTv: atvPairing }, creds, "ws", added.device.id, badStart.pairId);
    assert.equal(badRebind.ok, false);

    // Rebind with empty credentials (skipped) fails
    const emptyStart = await atvPairing.start({ ws: "ws", identifier: "192.168.1.52", protocols: ["adb"] });
    await atvPairing.finish("ws", emptyStart.pairId, { skip: true });
    const emptyRebind = await commitDeviceRebind(registry, { airplay: airplayPairing, androidTv: atvPairing }, creds, "ws", added.device.id, emptyStart.pairId);
    assert.equal(emptyRebind.ok, false);

    // Rebind adding ADB merges credentials & protocols
    const addAdb = await atvPairing.start({ ws: "ws", identifier: "192.168.1.52", protocols: ["adb"] });
    await atvPairing.finish("ws", addAdb.pairId, {});
    const rebound = await commitDeviceRebind(registry, { airplay: airplayPairing, androidTv: atvPairing }, creds, "ws", added.device.id, addAdb.pairId);
    assert.equal(rebound.ok, true);
    if (rebound.ok) {
      assert.deepEqual(rebound.device.protocols, ["atv_remote", "adb"]);
    }
    const mergedCreds = (await creds.get("ws", added.device.id)) as AndroidTvCredentials;
    assert.ok(mergedCreds.atv_remote);
    assert.ok(mergedCreds.adb);

    // Delete wipes credential file
    await creds.delete("ws", added.device.id);
    assert.equal(existsSync(encFile), false);
  } finally {
    await atvPairing.close();
    await airplayPairing.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("android-tv cert generation and encrypted credential I/O perform zero main-thread *Sync calls", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-atv-sync-"));
  const key = new StationKey(randomBytes(32));
  const creds = new DeviceCredentialStore<Record<string, unknown>>(dir, key);
  try {
    const calls = await syncCalls(async () => {
      const cert = await generateClientCert();
      await creds.set("ws", "0123456789abcdef", { atv_remote: { certPem: cert.certPem, keyPem: cert.keyPem, host: "192.168.1.52", remotePort: 6466, pairPort: 6467 } });
      await creds.get("ws", "0123456789abcdef");
      await creds.delete("ws", "0123456789abcdef");
    });
    assert.deepEqual(calls, []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
