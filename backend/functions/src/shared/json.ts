import { Buffer } from "node:buffer";

export function parseJsonRequestBody(body: unknown): unknown {
  if (typeof body === "string") {
    return parseJsonText(body);
  }

  if (Buffer.isBuffer(body)) {
    return parseJsonText(body.toString("utf8"));
  }

  if (body instanceof Uint8Array) {
    return parseJsonText(Buffer.from(body).toString("utf8"));
  }

  return body ?? {};
}

function parseJsonText(value: string): unknown {
  const trimmed = value.trim();
  return trimmed.length ? JSON.parse(trimmed) : {};
}
