// A station file that must be JSON: never include its contents in an error (it may hold credentials).
import { readFileSync } from "node:fs";
import { stationLang, tr } from "./i18n.ts";

export class InvalidJsonFile extends Error {
  constructor(path: string) {
    super(tr(stationLang(), "station.files.invalidJson", { path, program: process.execPath }));
  }
}

export function readJsonFile(path: string): any {
  const text = readFileSync(path, "utf8");
  return parseJsonText(path, text);
}

/// The text of the file at `path` as JSON, refused as `readJsonFile` refuses it: for a file read off the main thread.
export function parseJsonText(path: string, text: string): any {
  try {
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof SyntaxError) throw new InvalidJsonFile(path);
    throw error;
  }
}
