// A file Slack Connect will not take, put in a zip archive of its own so it can be shared there all the same.
//
// In a channel shared with another organization Slack refuses installers and executables (`.apk`, `.exe`, …) with
// `slack_connect_blocked_file_type`, and only once their bytes were uploaded and the share is completed. A zip of
// the one file is taken: its entry is stored as it is (method 0: these are compressed already, or small), its CRC-32
// taken from a gzip of it made on zlib's thread pool, so the station's thread computes nothing over the bytes.
import { promisify } from "node:util";
import { gzip } from "node:zlib";

const gzipped = promisify(gzip);

/// What Slack Connect refuses to share, by the name's last extension (any case): installers and executables.
const BLOCKED = new Set(["apk", "aab", "exe", "msi", "bat", "cmd", "com", "scr", "dmg", "pkg"]);

/// Whether Slack Connect would refuse a file of this name.
export function connectBlocked(name: string): boolean {
  const dot = name.lastIndexOf(".");
  return dot > 0 && BLOCKED.has(name.slice(dot + 1).toLowerCase());
}

/// The name a file goes by inside its archive: its own, without any folder.
function entryName(name: string): string {
  return name.slice(Math.max(name.lastIndexOf("/"), name.lastIndexOf("\\")) + 1) || "file";
}

/// A zip archive of one file, `name` its entry, its bytes stored. Over 4 GiB is not one (Slack takes up to 1 GB).
export async function zipOne(name: string, bytes: Uint8Array): Promise<Uint8Array> {
  if (bytes.length > 0xffff_fffe) throw new Error(`${name}: too large to put in a zip archive`);
  // A gzip's last 8 bytes are its input's CRC-32 and length (RFC 1952), little-endian.
  const gz = await gzipped(bytes, { level: 0 });
  const crc = gz.readUInt32LE(gz.length - 8);
  const path = Buffer.from(entryName(name), "utf8");
  const size = bytes.length;
  // Local file header (30 bytes and the name), the bytes, the central directory's one entry (46 and the name), its end (22).
  const local = Buffer.alloc(30 + path.length);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4); // version needed: 2.0
  local.writeUInt16LE(0x0800, 6); // the name is UTF-8
  local.writeUInt16LE(0, 8); // stored
  local.writeUInt16LE(0, 10); // time: 00:00:00
  local.writeUInt16LE(0x21, 12); // date: 1980-01-01 (no clock: the same file makes the same archive)
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(size, 18);
  local.writeUInt32LE(size, 22);
  local.writeUInt16LE(path.length, 26);
  local.writeUInt16LE(0, 28);
  path.copy(local, 30);
  const central = Buffer.alloc(46 + path.length);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(20, 4); // made by: 2.0
  central.writeUInt16LE(20, 6);
  central.writeUInt16LE(0x0800, 8);
  central.writeUInt16LE(0, 10);
  central.writeUInt16LE(0, 12);
  central.writeUInt16LE(0x21, 14);
  central.writeUInt32LE(crc, 16);
  central.writeUInt32LE(size, 20);
  central.writeUInt32LE(size, 24);
  central.writeUInt16LE(path.length, 28);
  // (extra, comment, disk, attributes: none; its local header at 0)
  path.copy(central, 46);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(central.length, 12);
  end.writeUInt32LE(local.length + size, 16);
  return Buffer.concat([local, bytes, central, end]);
}
