// ZCode Relay WSS 协议解析 (与 lib/core/relay/rpc_codec.dart 对齐的 JS 移植)
//
// wire 格式:
//   WS 文本帧 = JSON: {type:'data', payload:{zcode_type:'rpc-frame', dataBase64, messageSeq,
//                       fragmentIndex, fragmentCount, ...}, client_ts}
//   dataBase64 解码后 = RPC 二进制帧: [header(list)] + [body] 两个 varint+tag 值顺序拼接
//     tag: 0=null 1=string 2/3=binary 4=list 5=json 6=int
//     header = [typeCode, id, channel?, methodOrEvent?]
//     typeCode: 100=请求 102=订阅 103=退订 200=Init 201=OK 202=Error 203=ErrorObject 204=事件

export const RPC_TYPES = {
  100: { name: 'REQ', label: '请求', error: false },
  102: { name: 'LISTEN', label: '订阅', error: false },
  103: { name: 'UNLISTEN', label: '退订', error: false },
  200: { name: 'INIT', label: '初始化', error: false },
  201: { name: 'OK', label: '响应', error: false },
  202: { name: 'ERR', label: '错误', error: true },
  203: { name: 'ERR_OBJ', label: '错误对象', error: true },
  204: { name: 'EVENT', label: '事件', error: false },
};

export function decodeBase64(s) {
  const bin = atob(String(s).replace(/\s+/g, ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

const utf8 = new TextDecoder('utf-8', { fatal: false });

class Reader {
  constructor(bytes) { this.b = bytes; this.p = 0; }
  u8() {
    if (this.p >= this.b.length) throw new Error('unexpected EOF');
    return this.b[this.p++];
  }
  varint() {
    let r = 0, s = 0;
    for (;;) {
      const b = this.u8();
      r += (b & 0x7f) * Math.pow(2, s);
      if (!(b & 0x80)) break;
      s += 7;
      if (s > 63) throw new Error('varint too long');
    }
    return r;
  }
  bytes(n) {
    if (n < 0 || this.p + n > this.b.length) throw new Error('unexpected EOF');
    const v = this.b.subarray(this.p, this.p + n);
    this.p += n;
    return v;
  }
}

function readValue(r) {
  const tag = r.u8();
  switch (tag) {
    case 0: return null;
    case 1: { const n = r.varint(); return utf8.decode(r.bytes(n)); }
    case 2:
    case 3: { const n = r.varint(); const v = r.bytes(n); return { __binary: true, length: n, hex: hexPreview(v, 128, false) }; }
    case 4: {
      const n = r.varint();
      if (n > 5_000_000) throw new Error(`list too large: ${n}`);
      const a = [];
      for (let i = 0; i < n; i++) a.push(readValue(r));
      return a;
    }
    case 5: { const n = r.varint(); const s = utf8.decode(r.bytes(n)); try { return JSON.parse(s); } catch { return s; } }
    case 6: return r.varint();
    default: throw new Error(`unknown tag 0x${tag.toString(16)} @${r.p - 1}`);
  }
}

/** 解码一帧 RPC 二进制数据, 不会抛错之外的部分容忍 */
export function decodeRpcFrame(bytes) {
  const r = new Reader(bytes);
  const header = readValue(r);
  const body = readValue(r);
  const h = Array.isArray(header) ? header : [];
  return {
    typeCode: typeof h[0] === 'number' ? h[0] : -1,
    id: h.length > 1 ? h[1] : null,
    channel: typeof h[2] === 'string' ? h[2] : null,
    methodOrEvent: typeof h[3] === 'string' ? h[3] : null,
    body,
  };
}

export function rpcTitle(f) {
  const cm = f.channel ? `${f.channel}.${f.methodOrEvent || ''}` : (f.methodOrEvent || '');
  const topic = f.body && typeof f.body === 'object' && typeof f.body.topic === 'string' ? f.body.topic : '';
  switch (f.typeCode) {
    case 100: return `#${f.id} ${cm}`;
    case 102: return `#${f.id} LISTEN ${cm}`;
    case 103: return `#${f.id} UNLISTEN`;
    case 200: return 'INIT (bridge 就绪)';
    case 201: return `#${f.id} OK${topic ? ' · ' + topic : ''}`;
    case 202:
    case 203: return `#${f.id} ERR ${cm}`;
    case 204: return `#${f.id} EVENT${topic ? ' · ' + topic : ''}${cm ? ' ' + cm : ''}`;
    default: return `type=${f.typeCode} ${cm}`;
  }
}

export function rpcSnippet(f) {
  const b = f.body;
  if (b == null) return 'null';
  if (typeof b === 'string') return clip(b, 180);
  if (Array.isArray(b)) return clip(safeStringify(b), 180);
  if (typeof b === 'object') {
    if (b.__binary) return `binary ${b.length}B`;
    if (typeof b.message === 'string') return clip(b.message, 180);
  }
  return clip(safeStringify(b), 180);
}

/**
 * 解析一条 WS 文本帧 → 日志条目。
 * meta: {ts, dir:'send'|'recv', tabId, wsId, wsUrl}
 * 返回条目; 若是 rpc-frame 会带 pendingRpcFrame (payload 原始对象), 由调用方做分片重组。
 */
export function parseWsText(text, meta) {
  const e = { ...meta, sizeText: text.length, cat: 'raw', isError: false, rawText: text };
  let msg = null;
  try { msg = JSON.parse(text); } catch {
    e.cat = 'parse-error';
    e.outerType = '(非JSON)';
    e.title = '非 JSON 文本帧';
    e.snippet = clip(text, 180);
    return e;
  }
  e.msg = msg;
  const t = msg && typeof msg.type === 'string' ? msg.type : '(?)';
  e.outerType = t;

  const payload = msg && msg.type === 'data' && msg.payload && typeof msg.payload === 'object' ? msg.payload : null;
  if (payload) {
    e.payload = payload;
    const zt = typeof payload.zcode_type === 'string' ? payload.zcode_type : '';
    e.zcodeType = zt;
    if (zt === 'rpc-frame') { e.pendingRpcFrame = payload; return e; }
    e.cat = 'data';
    e.title = zt || 'data';
    if (zt === 'rpc-frame-ack') e.title = `rpc-frame-ack #${payload.ackMessageSeq ?? '?'}`;
    const rest = { ...payload };
    delete rest.zcode_type;
    delete rest.dataBase64;
    e.snippet = clip(safeStringify(rest), 220);
    if (zt === 'bridge-degraded' || zt === 'error') e.isError = true;
    return e;
  }

  if (t === 'error') {
    e.cat = 'error'; e.isError = true;
    e.title = '服务端 error';
    e.snippet = clip(safeStringify(msg), 220);
    return e;
  }
  if (t.startsWith('auth') || t.startsWith('pair_')) {
    e.cat = 'auth';
    e.title = t + (msg.pair_status ? ` · ${msg.pair_status}` : '');
    e.snippet = t === 'auth_ack'
      ? `terminal_sid=${msg.terminal_sid ?? ''} pair=${msg.pair_status ?? ''}`
      : clip(safeStringify(msg), 180);
    return e;
  }
  e.title = t;
  e.snippet = clip(safeStringify(msg), 180);
  return e;
}

/** rpc-frame 分片重组器 (大帧按 messageSeq 切片, 收齐才能解码) */
export class FragmentAssembler {
  constructor() { this.map = new Map(); }
  get pending() { return this.map.size; }
  feed(key, index, count, bytes, now = Date.now()) {
    let slot = this.map.get(key);
    if (!slot || slot.count !== count) {
      slot = { parts: new Array(count).fill(null), count, ts: now };
      this.map.set(key, slot);
    }
    slot.ts = now;
    if (index >= 0 && index < count && !slot.parts[index]) slot.parts[index] = bytes;
    const got = slot.parts.filter(Boolean);
    if (got.length === slot.count) {
      this.map.delete(key);
      const total = got.reduce((a, b) => a + b.length, 0);
      const merged = new Uint8Array(total);
      let off = 0;
      for (const p of slot.parts) { merged.set(p, off); off += p.length; }
      return { complete: true, bytes: merged };
    }
    return { complete: false, got: got.length };
  }
  /** 超时未收齐的分片 (如抓包开始时已传了一半), 返回已有部分 */
  takeStale(maxAgeMs, now = Date.now()) {
    const out = [];
    for (const [k, s] of this.map) {
      if (now - s.ts > maxAgeMs) {
        this.map.delete(k);
        out.push({ key: k, parts: s.parts.filter(Boolean) });
      }
    }
    return out;
  }
  dropPrefix(prefix) {
    for (const k of [...this.map.keys()]) if (k.startsWith(prefix)) this.map.delete(k);
  }
}

export function clip(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n) + '…' : s;
}

export function safeStringify(v) {
  try { return typeof v === 'string' ? v : JSON.stringify(v); } catch { return String(v); }
}

/** 经典 hex dump (offset + hex16 + ascii), 最多 max 字节 */
export function hexPreview(bytes, max = 16384, suffix = true) {
  const n = Math.min(bytes.length, max);
  const lines = [];
  for (let i = 0; i < n; i += 16) {
    let hex = '', asc = '';
    for (let j = 0; j < 16; j++) {
      if (i + j < n) {
        const b = bytes[i + j];
        hex += b.toString(16).padStart(2, '0') + ' ';
        asc += b >= 32 && b < 127 ? String.fromCharCode(b) : '.';
      } else { hex += '   '; asc += ' '; }
      if (j === 7) hex += ' ';
    }
    lines.push(i.toString(16).padStart(8, '0') + '  ' + hex + ' |' + asc + '|');
  }
  if (suffix && bytes.length > n) lines.push(`…(仅显示前 ${n} 字节, 共 ${bytes.length})`);
  return lines.join('\n');
}
