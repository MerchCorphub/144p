// Web Push (RFC 8030) with VAPID (RFC 8292) and aes128gcm payload encryption (RFC 8291),
// using only WebCrypto so it runs in Supabase Edge Functions (Deno) without Node modules.

const enc = new TextEncoder();
const b64u = {
  encode(buf: ArrayBuffer | Uint8Array): string {
    const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  },
  decode(s: string): Uint8Array {
    s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
    const bin = atob(s), out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  },
};
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, bytes * 8));
}

export type Vapid = { publicKey: string; privateKey: string; subject: string };
export type Subscription = { endpoint: string; p256dh: string; auth: string };

async function vapidHeader(endpoint: string, v: Vapid): Promise<string> {
  const pub = b64u.decode(v.publicKey); // 65 bytes: 0x04 || x || y
  const jwk = { kty: 'EC', crv: 'P-256', d: v.privateKey, x: b64u.encode(pub.slice(1, 33)), y: b64u.encode(pub.slice(33, 65)), ext: true };
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const header = b64u.encode(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64u.encode(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: v.subject })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(header + '.' + claims));
  return `vapid t=${header}.${claims}.${b64u.encode(sig)}, k=${v.publicKey}`;
}

export async function encryptPayload(sub: Subscription, payload: Uint8Array): Promise<Uint8Array> {
  const uaPublic = b64u.decode(sub.p256dh), authSecret = b64u.decode(sub.auth);
  const as = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, as.privateKey, 256));
  const ikm = await hkdf(authSecret, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(payload, new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]); // record size 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}

// Returns the push service's HTTP status (201 = delivered to the push service; 404/410 = subscription gone).
export async function sendPush(sub: Subscription, data: unknown, v: Vapid, ttlSeconds = 86400): Promise<{ status: number; text: string }> {
  const body = await encryptPayload(sub, enc.encode(JSON.stringify(data)));
  const res = await fetch(sub.endpoint, {
    method: 'POST',
    headers: {
      Authorization: await vapidHeader(sub.endpoint, v),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      TTL: String(ttlSeconds),
      Urgency: 'normal',
    },
    body,
  });
  return { status: res.status, text: res.ok ? '' : (await res.text()).slice(0, 300) };
}

export const _test = { b64u, vapidHeader };
