// 后台: chrome.debugger (CDP) 抓 WebSocket 帧 → 协议解析 → 环形缓冲 → 推送给日志面板
import {
  parseWsText, decodeRpcFrame, decodeBase64, RPC_TYPES,
  FragmentAssembler, rpcTitle, rpcSnippet, hexPreview, clip, safeStringify,
} from '../shared/protocol.js';

const MAX_ENTRIES = 8000;
const MAX_TOTAL_CHARS = 150_000_000; // rawText 总量保护 (约 150MB)

const entries = [];
const entryById = new Map();
const attached = new Map();   // tabId -> {tabId, title, url}
const sockets = new Map();    // `${tabId}:${wsId}` -> url
const frag = new FragmentAssembler();
const ports = new Set();
let nextId = 1;
let totalChars = 0;
let queue = [];
let flushTimer = null;

// 抓包期间防止 SW 空闲休眠 (休眠会丢内存里的日志缓冲)
setInterval(() => { if (attached.size) chrome.runtime.getPlatformInfo(() => {}); }, 25_000);

// 分片超时补发 (抓包开始时已在传输中的大帧会永远收不齐)
setInterval(() => {
  for (const s of frag.takeStale(8000)) {
    const [tabId, wsId, dir, seq] = s.key.split(':');
    pushEntry({
      ts: Date.now(), dir, tabId: +tabId, wsId, wsUrl: sockets.get(`${tabId}:${wsId}`) || '',
      cat: 'rpc', incomplete: true, isError: false,
      outerType: 'data', zcodeType: 'rpc-frame',
      sizeBytes: s.parts.reduce((a, b) => a + b.length, 0),
      title: `分片未收齐 #${seq}`,
      snippet: `收到 ${s.parts.length} 片 (抓包可能开始于帧传输中途)`,
    });
  }
}, 4000);

// ── SW 冷启动恢复: debugger 附加在浏览器层, 不随 SW 重启丢失 ──
chrome.storage.session.get('attachedTabs').then((st) => {
  for (const t of st.attachedTabs || []) {
    chrome.debugger.sendCommand({ tabId: t.tabId }, 'Network.enable', null, () => {
      if (chrome.runtime.lastError) return; // 标签页已关闭
      attached.set(t.tabId, t);
      broadcast({ t: 'caps', tabs: [...attached.values()] });
    });
  }
});

function persistAttached() {
  chrome.storage.session.set({ attachedTabs: [...attached.values()] });
}

function pushEntry(e) {
  e.id = nextId++;
  if (typeof e.rawText === 'string') {
    if (e.rawText.length > 2_000_000) e.rawText = e.rawText.slice(0, 2_000_000) + '…(截断)';
    totalChars += e.rawText.length;
  }
  entries.push(e);
  entryById.set(e.id, e);
  let drop = 0;
  while (entries.length - drop > MAX_ENTRIES) drop++;
  while (totalChars > MAX_TOTAL_CHARS && entries.length - drop > 100) {
    totalChars -= typeof entries[drop].rawText === 'string' ? entries[drop].rawText.length : 0;
    drop++;
  }
  if (drop) {
    for (let i = 0; i < drop; i++) entryById.delete(entries[i].id);
    entries.splice(0, drop);
  }
  queue.push(summaryOf(e));
  scheduleFlush();
}

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(() => {
    flushTimer = null;
    if (!queue.length) return;
    const batch = queue;
    queue = [];
    broadcast({ t: 'entries', entries: batch });
    broadcast({ t: 'stats', total: entries.length, pending: frag.pending, max: MAX_ENTRIES });
    updateBadge();
  }, 200);
}

function updateBadge() {
  chrome.action.setBadgeText({ text: attached.size ? (entries.length > 9999 ? '9999+' : String(entries.length)) : '' });
}

function broadcast(msg) {
  for (const p of ports) {
    try { p.postMessage(msg); } catch { ports.delete(p); }
  }
}

function summaryOf(e) {
  return {
    id: e.id, ts: e.ts, dir: e.dir, cat: e.cat, tabId: e.tabId, wsId: e.wsId || '', wsUrl: e.wsUrl || '',
    sizeText: e.sizeText || 0, sizeBytes: e.sizeBytes || 0,
    outerType: e.outerType || '', zcodeType: e.zcodeType || '',
    rpcType: e.rpcType ?? null, typeName: e.typeName || '', rpcId: e.rpcId ?? null,
    channel: e.channel || '', method: e.method || '',
    fragSeq: e.fragSeq ?? null, fragCount: e.fragCount || 0,
    incomplete: !!e.incomplete, isError: !!e.isError,
    title: e.title || '', snippet: e.snippet || '',
  };
}

/** 详情 (体积大的字段截断, dataBase64 替换为标记) */
function detailOf(e) {
  const redact = (o) => {
    const c = { ...o };
    if (typeof c.dataBase64 === 'string') c.dataBase64 = `«base64 ${c.dataBase64.length} 字符 → 已解码 ${e.sizeBytes || '?'}B, 见下方»`;
    return c;
  };
  return {
    ...summaryOf(e),
    merged: !!e.merged,
    decodeError: e.decodeError || '',
    body: e.body ?? null,
    payload: e.payload ? redact(e.payload) : null,
    msg: e.msg && !e.payload ? redact(e.msg) : null,
    rawText: typeof e.rawText === 'string' && e.rawText.length > 300_000
      ? e.rawText.slice(0, 300_000) + `\n…(截断, 共 ${e.rawText.length} 字符)`
      : (e.rawText ?? ''),
    hexPreview: e.hexPreview || '',
  };
}

// ── CDP 事件 ──
chrome.debugger.onEvent.addListener((src, method, p) => {
  const tabId = src && src.tabId;
  if (!tabId || !attached.has(tabId) || !p) return;
  switch (method) {
    case 'Network.webSocketCreated':
      sockets.set(`${tabId}:${p.requestId}`, p.url || '');
      pushEntry(sysEntry(tabId, p.requestId, `WS 已建立`, p.url || ''));
      break;
    case 'Network.webSocketClosed': {
      const url = sockets.get(`${tabId}:${p.requestId}`) || '';
      pushEntry(sysEntry(tabId, p.requestId, 'WS 已关闭', url));
      frag.dropPrefix(`${tabId}:${p.requestId}:`);
      sockets.delete(`${tabId}:${p.requestId}`);
      break;
    }
    case 'Network.webSocketFrameSent':
      handleFrame(tabId, p.requestId, 'send', p.response);
      break;
    case 'Network.webSocketFrameReceived':
      handleFrame(tabId, p.requestId, 'recv', p.response);
      break;
    case 'Network.webSocketFrameError':
      pushEntry(sysEntry(tabId, p.requestId, 'WS 帧错误', p.errorMessage || ''));
      break;
  }
});

function sysEntry(tabId, wsId, title, snippet) {
  return {
    ts: Date.now(), dir: 'meta', cat: 'system', isError: false,
    tabId, wsId: wsId || '', wsUrl: snippet && snippet.startsWith('ws') ? snippet : '',
    title, snippet, sizeText: 0,
  };
}

function handleFrame(tabId, wsId, dir, frame) {
  if (!frame || typeof frame.payloadData !== 'string') return;
  const wsUrl = sockets.get(`${tabId}:${wsId}`) || '';
  if (frame.opcode === 1) {
    ingest(parseWsText(frame.payloadData, { ts: Date.now(), dir, tabId, wsId, wsUrl }));
  } else if (frame.opcode === 2) {
    // 协议理论纯文本; 二进制帧兜底: 尝试直接按 RPC 解码, 失败则展示 hex
    let bytes = null;
    try { bytes = decodeBase64(frame.payloadData); } catch { /* not base64 */ }
    const e = {
      ts: Date.now(), dir, tabId, wsId, wsUrl, cat: 'raw', isError: false,
      outerType: '(binary)', sizeText: frame.payloadData.length, title: '二进制帧',
      snippet: clip(frame.payloadData, 120),
    };
    if (bytes) attachRpc(e, bytes, 0, 1);
    pushEntry(e);
  }
}

function ingest(e) {
  const p = e.pendingRpcFrame;
  if (!p) { pushEntry(e); return; }
  delete e.pendingRpcFrame;
  e.cat = 'rpc';
  const seq = typeof p.messageSeq === 'number' ? p.messageSeq : (typeof p.seq === 'number' ? p.seq : 0);
  const idx = typeof p.fragmentIndex === 'number' ? p.fragmentIndex : 0;
  const cnt = typeof p.fragmentCount === 'number' ? p.fragmentCount : 1;

  let bytes = null;
  try { bytes = decodeBase64(p.dataBase64 || ''); } catch (err) { e.decodeError = 'base64: ' + err.message; }
  if (!bytes) {
    e.title = 'rpc-frame (无 dataBase64)';
    e.snippet = clip(safeStringify(p), 180);
    pushEntry(e);
    return;
  }
  if (cnt <= 1) {
    attachRpc(e, bytes, seq, cnt);
    pushEntry(e);
    return;
  }
  const res = frag.feed(`${e.tabId}:${e.wsId}:${e.dir}:${seq}`, idx, cnt, bytes);
  if (res.complete) {
    attachRpc(e, res.bytes, seq, cnt);
    e.merged = true;
    pushEntry(e);
  }
  // 未收齐: 静默等待; 超时由 stale 补发
}

function attachRpc(e, bytes, seq, cnt) {
  e.cat = 'rpc';
  e.sizeBytes = bytes.length;
  e.fragSeq = seq;
  e.fragCount = cnt;
  e.hexPreview = hexPreview(bytes, 16384);
  try {
    const f = decodeRpcFrame(bytes);
    const meta = RPC_TYPES[f.typeCode] || { name: 'RPC' + f.typeCode, error: false };
    e.rpcType = f.typeCode;
    e.typeName = meta.name;
    e.rpcId = f.id;
    e.channel = f.channel || '';
    e.method = f.methodOrEvent || '';
    e.body = f.body;
    e.isError = !!meta.error;
    e.title = rpcTitle(f);
    e.snippet = rpcSnippet(f);
  } catch (err) {
    e.decodeError = String(err && err.message || err);
    e.title = 'RPC 解码失败';
    e.snippet = e.decodeError;
    e.isError = true;
  }
}

// ── 附加 / 分离 ──
chrome.debugger.onDetach.addListener((src, reason) => {
  const tabId = src && src.tabId;
  if (!tabId || !attached.has(tabId)) return;
  attached.delete(tabId);
  persistAttached();
  pushEntry(sysEntry(tabId, '', `调试已分离: ${reason || ''}`, ''));
  broadcast({ t: 'caps', tabs: [...attached.values()] });
  updateBadge();
});

function attachTab(tabId, reload, cb) {
  chrome.tabs.get(tabId, (tab) => {
    if (chrome.runtime.lastError || !tab) {
      cb({ ok: false, error: chrome.runtime.lastError ? chrome.runtime.lastError.message : 'tab not found' });
      return;
    }
    const info = { tabId, title: tab.title || '', url: tab.url || '' };
    chrome.debugger.attach({ tabId }, '1.3', () => {
      if (chrome.runtime.lastError) { cb({ ok: false, error: chrome.runtime.lastError.message }); return; }
      chrome.debugger.sendCommand({ tabId }, 'Network.enable', null, () => {
        if (chrome.runtime.lastError) { cb({ ok: false, error: chrome.runtime.lastError.message }); return; }
        attached.set(tabId, info);
        persistAttached();
        broadcast({ t: 'caps', tabs: [...attached.values()] });
        pushEntry(sysEntry(tabId, '', `开始抓包: ${info.title || info.url}`, info.url));
        if (reload) chrome.tabs.reload(tabId);
        updateBadge();
        cb({ ok: true });
      });
    });
  });
}

function detachTab(tabId, cb) {
  const targets = tabId != null ? [tabId] : [...attached.keys()];
  for (const id of targets) {
    if (!attached.has(id)) continue;
    const info = attached.get(id);
    attached.delete(id);
    persistAttached();
    pushEntry(sysEntry(id, '', `停止抓包: ${info.title || info.url}`, ''));
    chrome.debugger.detach({ tabId: id }, () => void chrome.runtime.lastError);
    for (const k of [...sockets.keys()]) if (k.startsWith(id + ':')) sockets.delete(k);
    frag.dropPrefix(id + ':');
  }
  broadcast({ t: 'caps', tabs: [...attached.values()] });
  updateBadge();
  cb({ ok: true });
}

function clearAll() {
  entries.length = 0;
  entryById.clear();
  totalChars = 0;
  queue = [];
  broadcast({ t: 'cleared' });
  updateBadge();
}

// ── 消息接口 (popup) ──
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg.t !== 'string') return;
  switch (msg.t) {
    case 'status':
      sendResponse({
        ok: true,
        attached: [...attached.values()],
        total: entries.length,
        pending: frag.pending,
        max: MAX_ENTRIES,
        sockets: [...sockets.entries()].map(([k, url]) => ({ key: k, url })),
      });
      return;
    case 'attach':
      attachTab(msg.tabId, !!msg.reload, sendResponse);
      return true; // async
    case 'detach':
      detachTab(msg.tabId ?? null, sendResponse);
      return true;
    case 'clear':
      clearAll();
      sendResponse({ ok: true });
      return;
  }
});

// ── 长连接 (日志面板) ──
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'viewer') return;
  ports.add(port);
  port.onDisconnect.addListener(() => ports.delete(port));
  port.onMessage.addListener((m) => {
    if (!m || typeof m.t !== 'string') return;
    if (m.t === 'snapshot') {
      post(port, { t: 'caps', tabs: [...attached.values()] });
      post(port, { t: 'stats', total: entries.length, pending: frag.pending, max: MAX_ENTRIES });
      const summs = entries.map(summaryOf);
      if (!summs.length) { post(port, { t: 'chunk', entries: [], done: true }); return; }
      for (let i = 0; i < summs.length; i += 500) {
        post(port, { t: 'chunk', entries: summs.slice(i, i + 500), done: i + 500 >= summs.length });
      }
    } else if (m.t === 'get-entry') {
      const e = entryById.get(m.id);
      post(port, { t: 'entry', id: m.id, entry: e ? detailOf(e) : null });
    }
  });
});

function post(port, msg) {
  try { port.postMessage(msg); } catch { ports.delete(port); }
}
