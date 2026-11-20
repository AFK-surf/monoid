// A non-JSON answer to an agent's Feishu OpenAPI call (feishu/web.ts gives it, feishu/tool.ts saves it). It is here,
// not in the Feishu part, because remote.ts carries it between stations and the shared code imports no part.

/// A non-JSON answer to an agent's OpenAPI call; only the tool puts it in that session's workspace.
export class FeishuFile {
  readonly bytes: Uint8Array;
  readonly contentType: string;
  readonly disposition: string;
  constructor(bytes: Uint8Array, contentType: string, disposition: string) {
    this.bytes = bytes;
    this.contentType = contentType;
    this.disposition = disposition;
  }
}
