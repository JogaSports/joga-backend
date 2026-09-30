/** JSON error in the same shape for every function: { error, message }. */
export function errorResponse(status: number, error: string, message: string): Response {
  return Response.json({ error, message }, { status });
}

/** Read a required environment variable or fail loudly at start-up. */
export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

/** Constant-time string comparison for shared secrets. */
export function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}
