// Shared types for Android TV / Google TV / Android TV box devices attached to a station.
import type { AndroidTvProtocol } from "../../../../client/core-ts/src/rig-form.ts";
export { ANDROID_TV_PROTOCOLS, type AndroidTvProtocol } from "../../../../client/core-ts/src/rig-form.ts";

export type AndroidTvAdbMode = "legacy_tcp" | "tls_wireless";

export type AndroidTvCandidateProtocol = {
  protocol: AndroidTvProtocol;
  pairing: "mandatory" | "optional" | "notNeeded";
  port?: number;
  pairPort?: number;
  adbMode?: AndroidTvAdbMode;
};

export type AndroidTvCandidate = {
  identifier: string;
  name: string;
  address: string;
  model: string;
  remotePort?: number;
  adbPort?: number;
  adbPairPort?: number;
  protocols: AndroidTvCandidateProtocol[];
  alreadyAdded?: boolean;
};

export type AndroidTvControlAction =
  | "status"
  | "power"
  | "remote"
  | "apps"
  | "launch"
  | "playing"
  | "volume"
  | "keyboard"
  | "play_url"
  | "screenshot";

export const ANDROID_TV_CONTROL_ACTIONS: readonly AndroidTvControlAction[] = [
  "status",
  "power",
  "remote",
  "apps",
  "launch",
  "playing",
  "volume",
  "keyboard",
  "play_url",
  "screenshot",
];

export type AndroidTvRemoteCredentials = {
  certPem: string;
  keyPem: string;
  serverCertSha256?: string;
  host: string;
  remotePort: number;
  pairPort: number;
};

export type AndroidTvAdbCredentials = {
  host: string;
  port: number;
  mode: AndroidTvAdbMode;
  serial: string;
};

export type AndroidTvCredentials = {
  atv_remote?: AndroidTvRemoteCredentials;
  adb?: AndroidTvAdbCredentials;
};

export type AndroidTvEnvStatus = {
  ready: true;
  adbAvailable: boolean;
};

export type AndroidTvPairStartResult = {
  pairToken: string;
  protocol: AndroidTvProtocol;
  deviceProvidesPin: boolean;
  adbMode?: AndroidTvAdbMode;
  pairPort?: number;
  adbPort?: number;
};

export type AndroidTvPairFinishResult = {
  protocol: AndroidTvProtocol;
  credentials: AndroidTvRemoteCredentials | AndroidTvAdbCredentials;
  model?: string;
};

export class AndroidTvError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "AndroidTvError";
    this.code = code;
  }
}

export interface AndroidTvAdapter {
  envStatus(): Promise<AndroidTvEnvStatus>;
  scan(opts?: { timeoutMs?: number; host?: string }): Promise<AndroidTvCandidate[]>;
  pairStart(params: {
    identifier: string;
    address?: string;
    protocol: AndroidTvProtocol;
    pairPort?: number;
    adbPort?: number;
    adbMode?: AndroidTvAdbMode;
  }): Promise<AndroidTvPairStartResult>;
  pairFinish(params: {
    pairToken: string;
    pin?: string;
    pairPort?: number;
    adbPort?: number;
  }): Promise<AndroidTvPairFinishResult>;
  pairCancel(params: { pairToken: string }): Promise<void>;
  control(params: {
    target: string;
    credentials?: AndroidTvCredentials;
    protocols?: readonly AndroidTvProtocol[];
    action: AndroidTvControlAction;
    args?: Record<string, unknown>;
  }): Promise<unknown>;
  screenshot(params: {
    target: string;
    credentials?: AndroidTvCredentials;
    protocols?: readonly AndroidTvProtocol[];
  }): Promise<{ png: Buffer; width: number; height: number }>;
  ensureAdbConnected(params: {
    target: string;
    credentials?: AndroidTvCredentials;
  }): Promise<{ serial: string }>;
  openRawAdbConnection(): Promise<import("node:net").Socket>;
  close(): Promise<void>;
}
