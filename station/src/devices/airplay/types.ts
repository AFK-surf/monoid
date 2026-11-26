// Shared types for AirPlay / Apple TV / HomePod devices attached to a station.
import type { AirPlayProtocol } from "../../../../client/core-ts/src/rig-form.ts";
export { AIRPLAY_PROTOCOLS, type AirPlayProtocol } from "../../../../client/core-ts/src/rig-form.ts";

export type AirPlayPairingRequirement = "mandatory" | "optional" | "notNeeded" | "unsupported" | "disabled";

export type AirPlayCandidateProtocol = {
  protocol: AirPlayProtocol;
  pairing: AirPlayPairingRequirement;
};

export type AirPlayCandidate = {
  identifier: string;
  name: string;
  address: string;
  model: string;
  os?: string;
  protocols: AirPlayCandidateProtocol[];
  alreadyAdded?: boolean;
};

export type AirPlayControlAction =
  | "status"
  | "power"
  | "remote"
  | "apps"
  | "launch"
  | "playing"
  | "seek"
  | "volume"
  | "keyboard"
  | "play_url"
  | "stream_audio";

export const AIRPLAY_CONTROL_ACTIONS: readonly AirPlayControlAction[] = [
  "status",
  "power",
  "remote",
  "apps",
  "launch",
  "playing",
  "seek",
  "volume",
  "keyboard",
  "play_url",
  "stream_audio",
];

export type AirPlayCredentials = Partial<Record<AirPlayProtocol, string>>;

export type AirPlayEnvStatus = {
  ready: boolean;
  python: string | null;
  pyatvVersion: string | null;
  error?: string;
};

export type AirPlayPairStartResult = {
  pairToken: string;
  protocol: AirPlayProtocol;
  deviceProvidesPin: boolean;
};

export type AirPlayPairFinishResult = {
  credentials: string;
  protocol: AirPlayProtocol;
};

export class AirPlayError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "AirPlayError";
    this.code = code;
  }
}

export interface AirPlayAdapter {
  envStatus(): Promise<AirPlayEnvStatus>;
  installEnv(): Promise<{ ok: true; pyatvVersion: string; python: string }>;
  scan(opts?: { timeoutMs?: number; host?: string }): Promise<AirPlayCandidate[]>;
  pairStart(params: { identifier: string; address?: string; protocol: AirPlayProtocol }): Promise<AirPlayPairStartResult>;
  pairFinish(params: { pairToken: string; pin?: string }): Promise<AirPlayPairFinishResult>;
  pairCancel(params: { pairToken: string }): Promise<void>;
  control(params: {
    identifier: string;
    address?: string;
    credentials?: AirPlayCredentials;
    action: AirPlayControlAction;
    args?: Record<string, unknown>;
  }): Promise<unknown>;
  close(): Promise<void>;
}
