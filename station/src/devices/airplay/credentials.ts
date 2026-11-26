// Encrypted at-rest storage for AirPlay pairing credentials:
// <data>/devices/credentials/<deviceId>.enc, encrypted with AES-256-GCM using a key
// derived from the station's Ed25519 seed via HKDF-SHA256, with AAD bound to `${ws}\0${deviceId}`.
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DEVICE_ID } from "../../../../client/core-ts/src/rig-form.ts";
import type { StationKey } from "../../cloud/key.ts";
import { platform } from "../../platform/index.ts";
import type { AirPlayCredentials } from "./types.ts";

const HKDF_INFO = Buffer.from("stillfail-device-credentials/v1", "utf8");

type Envelope = {
  v: 1;
  salt: string;
  iv: string;
  tag: string;
  ciphertext: string;
};

export class AirPlayCredentialStore {
  readonly #dir: string;
  readonly #seed: Buffer;

  constructor(dataDir: string, key: Pick<StationKey, "seed">) {
    this.#dir = join(dataDir, "devices", "credentials");
    this.#seed = key.seed;
  }

  #fileFor(deviceId: string): string {
    if (!DEVICE_ID.test(deviceId)) throw new Error("invalid device id");
    return join(this.#dir, `${deviceId}.enc`);
  }

  #deriveKey(salt: Buffer): Buffer {
    return Buffer.from(hkdfSync("sha256", this.#seed, salt, HKDF_INFO, 32));
  }

  #aad(ws: string, deviceId: string): Buffer {
    return Buffer.from(`${ws}\0${deviceId}`, "utf8");
  }

  async get(ws: string, deviceId: string): Promise<AirPlayCredentials | null> {
    const file = this.#fileFor(deviceId);
    let raw: string;
    try {
      raw = await readFile(file, "utf8");
    } catch (err) {
      if ((err as NodeJS.ErrnoException)?.code === "ENOENT") return null;
      throw err;
    }
    const env = JSON.parse(raw) as Envelope;
    if (env === null || typeof env !== "object" || env.v !== 1 || typeof env.salt !== "string" || typeof env.iv !== "string" || typeof env.tag !== "string" || typeof env.ciphertext !== "string") {
      throw new Error("corrupt device credentials envelope");
    }
    const salt = Buffer.from(env.salt, "base64");
    const iv = Buffer.from(env.iv, "base64");
    const tag = Buffer.from(env.tag, "base64");
    const ciphertext = Buffer.from(env.ciphertext, "base64");
    const key = this.#deriveKey(salt);
    const decipher = createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAAD(this.#aad(ws, deviceId));
    decipher.setAuthTag(tag);
    const plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
    const parsed = JSON.parse(plain);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("corrupt device credentials payload");
    }
    return parsed as AirPlayCredentials;
  }

  async set(ws: string, deviceId: string, creds: AirPlayCredentials): Promise<void> {
    const file = this.#fileFor(deviceId);
    await mkdir(this.#dir, { recursive: true, mode: 0o700 });
    if (platform.os !== "windows") await chmod(this.#dir, 0o700).catch(() => {});
    const salt = randomBytes(16);
    const iv = randomBytes(12);
    const key = this.#deriveKey(salt);
    const cipher = createCipheriv("aes-256-gcm", key, iv);
    cipher.setAAD(this.#aad(ws, deviceId));
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(creds), "utf8"), cipher.final()]);
    const tag = cipher.getAuthTag();
    const env: Envelope = {
      v: 1,
      salt: salt.toString("base64"),
      iv: iv.toString("base64"),
      tag: tag.toString("base64"),
      ciphertext: ciphertext.toString("base64"),
    };
    const tmp = `${file}.tmp-${randomBytes(6).toString("hex")}`;
    try {
      await writeFile(tmp, JSON.stringify(env), { mode: 0o600 });
      if (platform.os !== "windows") await chmod(tmp, 0o600).catch(() => {});
      await rename(tmp, file);
    } catch (err) {
      await unlink(tmp).catch(() => {});
      throw err;
    }
  }

  async delete(_ws: string, deviceId: string): Promise<void> {
    const file = this.#fileFor(deviceId);
    try {
      await unlink(file);
    } catch (err) {
      if ((err as NodeJS.ErrnoException)?.code !== "ENOENT") throw err;
    }
  }
}
