// The local model and station's tools of test/fake/copilot-model.mjs.
import type { Server } from "node:http";
export function startModel(script: (body: any, n: number) => any): Promise<{ server: Server; url: string; requests: { url: string; body: any }[] }>;
export function startMcp(tools: string[]): Promise<{ server: Server; url: string; calls: { headers: Record<string, string>; message: any }[] }>;
