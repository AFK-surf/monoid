// Thin typed wrapper over DeviceCredentialStore for AirPlay credentials (backward compatible export).
import { DeviceCredentialStore } from "../credentials.ts";
import type { AirPlayCredentials } from "./types.ts";

export class AirPlayCredentialStore extends DeviceCredentialStore<AirPlayCredentials> {}
