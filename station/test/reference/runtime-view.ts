// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/runtime-view.ts's.
//
// Project only runtime-bearing metadata declared by the client schema. User content and unknown extension fields
// are preserved. Shared by HTTP responses and the reader's digest calculation so unchanged rows stay unchanged.
import { runtimeView } from "../../src/read/runtime-view.ts";

export * from "../../src/read/runtime-view.ts";
export { runtimeView };

export function runtimeList(op: string, value: unknown, runtimes?: string[]): unknown {
  if (!runtimes) return value;
  const types: Record<string,string> = {sessions:"Session",chats:"ChatItem",sharedChats:"ChatItem",threads:"ChatThread"};
  const type = types[op];
  return type ? runtimeView({vec:type},value,new Set(runtimes)) : value;
}
