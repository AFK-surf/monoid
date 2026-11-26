// Pure node:crypto RSA-2048 keypair & self-signed X.509 v3 certificate generator
// plus RSA public-key modulus/exponent extraction for Android TV Remote Protocol v2.
import {
  createHash,
  createSign,
  generateKeyPair,
  randomBytes,
  X509Certificate,
} from "node:crypto";
import { promisify } from "node:util";
import { wall } from "../../ops/fibers.ts";

const generateKeyPairAsync = promisify(generateKeyPair);

// Minimal DER / ASN.1 builders
function derLength(len: number): Buffer {
  if (len < 0x80) return Buffer.from([len]);
  const bytes: number[] = [];
  let n = len;
  while (n > 0) {
    bytes.unshift(n & 0xff);
    n >>>= 8;
  }
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function derTag(tag: number, content: Buffer): Buffer {
  return Buffer.concat([Buffer.from([tag]), derLength(content.length), content]);
}

function derSequence(items: readonly Buffer[]): Buffer {
  return derTag(0x30, Buffer.concat(items));
}

function derSet(items: readonly Buffer[]): Buffer {
  return derTag(0x31, Buffer.concat(items));
}

function derInteger(buf: Buffer): Buffer {
  let i = 0;
  while (i < buf.length - 1 && buf[i] === 0) i++;
  let trimmed = buf.subarray(i);
  if ((trimmed[0]! & 0x80) !== 0) {
    trimmed = Buffer.concat([Buffer.from([0x00]), trimmed]);
  }
  return derTag(0x02, trimmed);
}

function derBitString(buf: Buffer): Buffer {
  return derTag(0x03, Buffer.concat([Buffer.from([0x00]), buf]));
}

function derOid(oid: readonly number[]): Buffer {
  const out: number[] = [oid[0]! * 40 + oid[1]!];
  for (let i = 2; i < oid.length; i++) {
    let v = oid[i]!;
    if (v === 0) {
      out.push(0);
      continue;
    }
    const stack: number[] = [];
    while (v > 0) {
      stack.push(v & 0x7f);
      v >>>= 7;
    }
    for (let j = stack.length - 1; j >= 0; j--) {
      out.push(j === 0 ? stack[j]! : stack[j]! | 0x80);
    }
  }
  return derTag(0x06, Buffer.from(out));
}

function derUtf8(str: string): Buffer {
  return derTag(0x0c, Buffer.from(str, "utf8"));
}

function derNull(): Buffer {
  return Buffer.from([0x05, 0x00]);
}

/// Encode Unix epoch milliseconds as RFC 5280 §4.1.2.5 X.509 Time without calling the JS Date constructor:
/// - 1950..2049 -> UTCTime (tag 0x17, `YYMMDDHHMMSSZ`)
/// - otherwise  -> GeneralizedTime (tag 0x18, `YYYYMMDDHHMMSSZ`)
export function derX509Time(ms: number): Buffer {
  const totalSec = Math.floor(ms / 1000);
  const secOfDay = ((totalSec % 86400) + 86400) % 86400;
  const z = Math.floor(totalSec / 86400) + 719468;
  const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const day = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const month = mp + (mp < 10 ? 3 : -9);
  const year = y + (month <= 2 ? 1 : 0);
  const hour = Math.floor(secOfDay / 3600);
  const minute = Math.floor((secOfDay % 3600) / 60);
  const second = secOfDay % 60;
  const pad2 = (n: number) => String(n).padStart(2, "0");
  const pad4 = (n: number) => String(n).padStart(4, "0");
  const rest = `${pad2(month)}${pad2(day)}${pad2(hour)}${pad2(minute)}${pad2(second)}Z`;
  if (year >= 1950 && year <= 2049) {
    return derTag(0x17, Buffer.from(`${pad2(year % 100)}${rest}`, "ascii"));
  }
  return derTag(0x18, Buffer.from(`${pad4(year)}${rest}`, "ascii"));
}

function derToPem(der: Buffer, label: string): string {
  const b64 = der.toString("base64");
  const lines: string[] = [];
  for (let i = 0; i < b64.length; i += 64) {
    lines.push(b64.slice(i, i + 64));
  }
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

// OIDs
const OID_SHA256_WITH_RSA = [1, 2, 840, 113549, 1, 1, 11];
const OID_COMMON_NAME = [2, 5, 4, 3];
const OID_BASIC_CONSTRAINTS = [2, 5, 29, 19];

/// Generate an RSA-2048 keypair and self-signed X.509 v3 certificate (`CN=still.fail`, 10-year validity, SHA256withRSA).
export async function generateClientCert(opts?: {
  commonName?: string;
  nowMs?: number;
}): Promise<{ certPem: string; keyPem: string }> {
  const cn = opts?.commonName ?? "still.fail";
  const nowMs = opts?.nowMs ?? wall.now();
  const { publicKey, privateKey } = await generateKeyPairAsync("rsa", {
    modulusLength: 2048,
    publicExponent: 0x10001,
  });

  const spkiDer = publicKey.export({ type: "spki", format: "der" }) as Buffer;
  const keyPem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

  const serial = randomBytes(16);
  serial[0] = serial[0]! & 0x7f; // positive integer
  if (serial[0] === 0) serial[0] = 1;

  const algId = derSequence([derOid(OID_SHA256_WITH_RSA), derNull()]);
  const name = derSequence([derSet([derSequence([derOid(OID_COMMON_NAME), derUtf8(cn)])])]);

  // Validity: 1 day before now to 10 years after now
  const oneDayMs = 86_400_000;
  const tenYearsMs = 3650 * oneDayMs;
  const validity = derSequence([
    derX509Time(nowMs - oneDayMs),
    derX509Time(nowMs + tenYearsMs),
  ]);

  // v3 extension: BasicConstraints CA:FALSE
  const basicConstraintsExt = derSequence([
    derOid(OID_BASIC_CONSTRAINTS),
    derTag(0x04, derSequence([])),
  ]);
  const extensions = derTag(0xa3, derSequence([basicConstraintsExt]));

  // version [0] EXPLICIT INTEGER v3 (2)
  const version = derTag(0xa0, derInteger(Buffer.from([0x02])));

  const tbsCertificate = derSequence([
    version,
    derInteger(serial),
    algId,
    name, // issuer
    validity,
    name, // subject
    spkiDer,
    extensions,
  ]);

  const signer = createSign("sha256");
  signer.update(tbsCertificate);
  const signature = signer.sign(privateKey);

  const certDer = derSequence([tbsCertificate, algId, derBitString(signature)]);
  return {
    certPem: derToPem(certDer, "CERTIFICATE"),
    keyPem,
  };
}

/// Strip leading 0x00 bytes from a big-endian unsigned integer buffer (preserving at least 1 byte).
export function stripLeadingZeros(buf: Buffer): Buffer {
  let i = 0;
  while (i < buf.length - 1 && buf[i] === 0) i++;
  return buf.subarray(i);
}

/// Extract unsigned big-endian RSA `modulus` and `exponent` bytes from an X.509 certificate (PEM, DER, or X509Certificate).
export function extractRsaModulusExponent(cert: X509Certificate | string | Buffer): {
  modulus: Buffer;
  exponent: Buffer;
} {
  const x509 = cert instanceof X509Certificate ? cert : new X509Certificate(cert);
  const jwk = x509.publicKey.export({ format: "jwk" });
  if (jwk.kty !== "RSA" || typeof jwk.n !== "string" || typeof jwk.e !== "string") {
    throw new Error("certificate public key is not RSA");
  }
  const modulus = stripLeadingZeros(Buffer.from(jwk.n, "base64url"));
  const exponent = stripLeadingZeros(Buffer.from(jwk.e, "base64url"));
  return { modulus, exponent };
}

/// Lowercase hex SHA-256 fingerprint of a DER or PEM X.509 certificate.
export function certSha256Hex(cert: X509Certificate | string | Buffer): string {
  const x509 = cert instanceof X509Certificate ? cert : new X509Certificate(cert);
  return createHash("sha256").update(x509.raw).digest("hex");
}

/// Compute the 32-byte Android TV Remote v2 pairing secret hash:
/// SHA-256(clientModulus || clientExponent || serverModulus || serverExponent || pinSuffixBytes)
export function computePairingSecretHash(params: {
  clientCert: X509Certificate | string | Buffer;
  serverCert: X509Certificate | string | Buffer;
  pinSuffix: Buffer;
}): Buffer {
  const client = extractRsaModulusExponent(params.clientCert);
  const server = extractRsaModulusExponent(params.serverCert);
  return createHash("sha256")
    .update(client.modulus)
    .update(client.exponent)
    .update(server.modulus)
    .update(server.exponent)
    .update(params.pinSuffix)
    .digest();
}
