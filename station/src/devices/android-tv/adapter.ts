// Unified LocalAndroidTvAdapter combining mDNS/probe discovery, Remote v2 TLS client, and isolated ADB client.
import { randomBytes } from "node:crypto";
import type net from "node:net";
import { AndroidTvAdbClient } from "./adb-client.ts";
import { parseHostSpec, scanAndroidTv } from "./discovery.ts";
import { AndroidTvRemoteClient } from "./remote-client.ts";
import {
  AndroidTvError,
  type AndroidTvAdapter,
  type AndroidTvAdbMode,
  type AndroidTvCandidate,
  type AndroidTvControlAction,
  type AndroidTvCredentials,
  type AndroidTvEnvStatus,
  type AndroidTvPairFinishResult,
  type AndroidTvPairStartResult,
  type AndroidTvProtocol,
} from "./types.ts";

type ActiveAdbPair = {
  host: string;
  adbMode: AndroidTvAdbMode;
  pairPort?: number;
  adbPort: number;
};

export class LocalAndroidTvAdapter implements AndroidTvAdapter {
  readonly #remote: AndroidTvRemoteClient;
  readonly #adb: AndroidTvAdbClient;
  readonly #adbPairs = new Map<string, ActiveAdbPair>();

  constructor(opts: {
    dataDir: string;
    remote?: AndroidTvRemoteClient;
    adb?: AndroidTvAdbClient;
  }) {
    this.#remote = opts.remote ?? new AndroidTvRemoteClient();
    this.#adb = opts.adb ?? new AndroidTvAdbClient({ dataDir: opts.dataDir });
  }

  async envStatus(): Promise<AndroidTvEnvStatus> {
    return { ready: true, adbAvailable: this.#adb.isAvailable() };
  }

  async scan(opts?: { timeoutMs?: number; host?: string }): Promise<AndroidTvCandidate[]> {
    return scanAndroidTv(opts);
  }

  async pairStart(params: {
    identifier: string;
    address?: string;
    protocol: AndroidTvProtocol;
    pairPort?: number;
    adbPort?: number;
    adbMode?: AndroidTvAdbMode;
  }): Promise<AndroidTvPairStartResult> {
    const rawHost = params.address?.trim() || params.identifier.trim();
    const { host, explicitPort } = parseHostSpec(rawHost);
    if (!host) throw new AndroidTvError("invalid_params", "device host/IP is required");

    if (params.protocol === "atv_remote") {
      const pairPort = params.pairPort ?? 6467;
      const started = await this.#remote.pairStart({ host, pairPort, remotePort: 6466 });
      return {
        pairToken: started.pairToken,
        protocol: "atv_remote",
        deviceProvidesPin: true,
        pairPort,
      };
    }

    if (!this.#adb.isAvailable()) {
      throw new AndroidTvError("adb_missing", "adb is not installed on this station");
    }
    const adbPort = params.adbPort ?? explicitPort ?? 5555;
    const adbMode: AndroidTvAdbMode = params.adbMode ?? (params.pairPort !== undefined ? "tls_wireless" : "legacy_tcp");
    const pairToken = `atv_adb_${randomBytes(10).toString("hex")}`;
    this.#adbPairs.set(pairToken, {
      host,
      adbMode,
      ...(params.pairPort !== undefined ? { pairPort: params.pairPort } : {}),
      adbPort,
    });

    // For legacy TCP ADB, trigger `adb connect` right away so the TV displays the RSA authorization dialog!
    if (adbMode === "legacy_tcp") {
      void this.#adb.exec(["connect", `${host}:${adbPort}`]).catch(() => {});
    }

    return {
      pairToken,
      protocol: "adb",
      deviceProvidesPin: adbMode === "tls_wireless",
      adbMode,
      ...(params.pairPort !== undefined ? { pairPort: params.pairPort } : {}),
      adbPort,
    };
  }

  async pairFinish(params: {
    pairToken: string;
    pin?: string;
    pairPort?: number;
    adbPort?: number;
  }): Promise<AndroidTvPairFinishResult> {
    if (params.pairToken.startsWith("atv_rem_")) {
      const res = await this.#remote.pairFinish({ pairToken: params.pairToken, pin: params.pin ?? "" });
      return {
        protocol: "atv_remote",
        credentials: res.credentials,
        ...(res.model ? { model: res.model } : {}),
      };
    }

    const adbPair = this.#adbPairs.get(params.pairToken);
    if (!adbPair) {
      throw new AndroidTvError("invalid_pair_token", "ADB pairing session not found or expired");
    }

    if (adbPair.adbMode === "tls_wireless") {
      const pairPort = params.pairPort ?? adbPair.pairPort;
      if (!pairPort) {
        throw new AndroidTvError("invalid_params", "pairPort is required for wireless ADB pairing");
      }
      const connectPort = params.adbPort ?? adbPair.adbPort;
      const res = await this.#adb.pairWireless({
        host: adbPair.host,
        pairPort,
        pin: params.pin ?? "",
        connectPort,
      });
      this.#adbPairs.delete(params.pairToken);
      return {
        protocol: "adb",
        credentials: res.credentials,
        ...(res.model ? { model: res.model } : {}),
      };
    }

    // Legacy TCP ADB: verify that the user clicked "Always allow" on the TV screen.
    // If still unauthorized, keep the pairToken alive so the user can retry after clicking Allow!
    const port = params.adbPort ?? adbPair.adbPort;
    const res = await this.#adb.connectLegacy(adbPair.host, port);
    this.#adbPairs.delete(params.pairToken);
    return {
      protocol: "adb",
      credentials: res.credentials,
      ...(res.model ? { model: res.model } : {}),
    };
  }

  async pairCancel(params: { pairToken: string }): Promise<void> {
    if (params.pairToken.startsWith("atv_rem_")) {
      await this.#remote.pairCancel(params.pairToken);
      return;
    }
    this.#adbPairs.delete(params.pairToken);
  }

  #resolveAdbHostPort(target: string, credentials?: AndroidTvCredentials): { host: string; port: number } {
    if (credentials?.adb) {
      return { host: credentials.adb.host, port: credentials.adb.port };
    }
    const { host, explicitPort } = parseHostSpec(target);
    return { host, port: explicitPort ?? 5555 };
  }

  async ensureAdbConnected(params: {
    target: string;
    credentials?: AndroidTvCredentials;
  }): Promise<{ serial: string }> {
    const { host, port } = this.#resolveAdbHostPort(params.target, params.credentials);
    const serial = await this.#adb.ensureConnected(host, port);
    return { serial };
  }

  async openRawAdbConnection(): Promise<net.Socket> {
    return this.#adb.openRawConnection();
  }

  async screenshot(params: {
    target: string;
    credentials?: AndroidTvCredentials;
    protocols?: readonly AndroidTvProtocol[];
  }): Promise<{ png: Buffer; width: number; height: number }> {
    const hasAdb = Boolean(params.credentials?.adb) || Boolean(params.protocols?.includes("adb"));
    if (!hasAdb) {
      throw new AndroidTvError("not_supported", "screenshot requires the adb protocol to be paired on this Android TV");
    }
    const { serial } = await this.ensureAdbConnected({ target: params.target, credentials: params.credentials });
    return this.#adb.screenshot(serial);
  }

  async control(params: {
    target: string;
    credentials?: AndroidTvCredentials;
    protocols?: readonly AndroidTvProtocol[];
    action: AndroidTvControlAction;
    args?: Record<string, unknown>;
  }): Promise<unknown> {
    const hasRemote = Boolean(params.credentials?.atv_remote);
    const hasAdb = Boolean(params.credentials?.adb) || Boolean(params.protocols?.includes("adb"));
    const adbOnlyActions: readonly AndroidTvControlAction[] = ["apps", "playing", "screenshot"];

    // Prefer ADB for adb-only actions or when Remote v2 is not paired.
    if (adbOnlyActions.includes(params.action)) {
      if (!hasAdb) {
        throw new AndroidTvError("not_supported", `action '${params.action}' requires ADB protocol on this Android TV`);
      }
      const { serial } = await this.ensureAdbConnected({ target: params.target, credentials: params.credentials });
      return this.#adb.control(serial, params.action, params.args);
    }

    // For `launch` with a package name (not a URL), prefer ADB if available.
    if (params.action === "launch") {
      const app = typeof params.args?.app === "string" ? params.args.app.trim() : "";
      const isUrl = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(app);
      if (!isUrl && hasAdb) {
        const { serial } = await this.ensureAdbConnected({ target: params.target, credentials: params.credentials });
        return this.#adb.control(serial, params.action, params.args);
      }
    }

    // Prefer Remote v2 for low-latency D-pad/power/keyboard/volume/app_link when paired, falling back to ADB.
    if (hasRemote && params.credentials?.atv_remote) {
      const { host } = parseHostSpec(params.target);
      try {
        return await this.#remote.control({
          host: host || params.credentials.atv_remote.host,
          remotePort: params.credentials.atv_remote.remotePort,
          credentials: params.credentials.atv_remote,
          action: params.action,
          args: params.args,
        });
      } catch (err) {
        if (err instanceof AndroidTvError && err.code === "not_supported" && hasAdb) {
          const { serial } = await this.ensureAdbConnected({ target: params.target, credentials: params.credentials });
          return this.#adb.control(serial, params.action, params.args);
        }
        throw err;
      }
    }

    if (hasAdb) {
      const { serial } = await this.ensureAdbConnected({ target: params.target, credentials: params.credentials });
      return this.#adb.control(serial, params.action, params.args);
    }

    throw new AndroidTvError("auth_failed", "Android TV has no paired protocols (pair atv_remote or adb first)");
  }

  async close(): Promise<void> {
    this.#adbPairs.clear();
    await Promise.all([this.#remote.close(), this.#adb.close()]);
  }
}
