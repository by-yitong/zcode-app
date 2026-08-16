// ZCode WSS 抓包日志面板
// 数据流: service-worker (解析/缓冲) --port--> 本页 (渲染)
'use strict';

const $ = (id) => document.getElementById(id);

const MAX_DOM_ROWS = 900;

const state = {
  summaries: [],
  filtered: [],
  dir: 'all',
  cats: new Set(),          // 空 = 全部
  query: '',
  queryLower: '',
  queryRe: null,
  showIncomplete: false,
  tabFilter: 'all',
  paused: false,
  autoScroll: true,
  caps: [],
  pendingFrags: 0,
  maxEntries: 8000,
  selectedId: null,
  cache: new Map(),
  pendingGets: new Map(),
  counts: { total: 0, err: 0 },
  domCount: 0,
};

let port = null;
let reconnectTimer = null;
let searchTimer = null;

// ── 后台连接 ──
function connect() {
  port = chrome.runtime.connect({ name: 'viewer' });
  port.onMessage.addListener(onPortMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    setStatus('与后台断开, 重连中…');
    scheduleReconnect();
  });
  port.postMessage({ t: 'snapshot' });
}
function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => { reconnectTimer = null; hardReset(); connect(); }, 800);
}
function hardReset() {
  state.summaries = [];
  state.filtered = [];
  state.cache.clear();
  state.pendingGets.clear();
  state.selectedId = null;
  state.counts = { total: 0, err: 0 };
  state.domCount = 0;
  $('list').innerHTML = '';
  renderDetailEmpty();
}

function onPortMessage(msg) {
  switch (msg.t) {
    case 'chunk':
      for (const s of msg.entries) {
        state.summaries.push(s);
        state.counts.total++;
        if (s.isError) state.counts.err++;
      }
      if (msg.done) applyFilters();
      break;
    case 'entries':
      for (const s of msg.entries) {
        state.summaries.push(s);
        state.counts.total++;
        if (s.isError) state.counts.err++;
        if (passes(s)) {
          state.filtered.push(s);
          if (!state.paused) appendRow(s);
        }
      }
      updateStatusBar();
      break;
    case 'stats':
      state.pendingFrags = msg.pending || 0;
      state.maxEntries = msg.max || 8000;
      updateStatusBar();
      break;
    case 'caps':
      state.caps = msg.tabs || [];
      renderCaps();
      if (state.tabFilter !== 'all' && !state.caps.some((c) => c.tabId === state.tabFilter)) {
        state.tabFilter = 'all';
        applyFilters();
      }
      break;
    case 'cleared':
      hardReset();
      applyFilters();
      break;
    case 'entry': {
      const resolve = state.pendingGets.get(msg.id);
      if (resolve) { state.pendingGets.delete(msg.id); resolve(msg.entry); }
      break;
    }
  }
}

function getEntry(id) {
  if (state.cache.has(id)) return Promise.resolve(state.cache.get(id));
  return new Promise((resolve) => {
    state.pendingGets.set(id, (e) => { if (e) state.cache.set(id, e); resolve(e); });
    if (port) port.postMessage({ t: 'get-entry', id });
    else resolve(null);
  });
}

// ── 筛选 ──
const CAT_CHIPS = [
  { k: 'req', label: '请求 100' },
  { k: 'sub', label: '订阅 102/103' },
  { k: 'ok', label: '响应 200/201' },
  { k: 'ev', label: '事件 204' },
  { k: 'err', label: '错误' },
  { k: 'auth', label: '认证/心跳' },
  { k: 'data', label: '数据层' },
  { k: 'sys', label: '连接/系统' },
];

function chipMatch(s) {
  for (const k of state.cats) {
    switch (k) {
      case 'req': if (s.cat === 'rpc' && s.rpcType === 100) return true; break;
      case 'sub': if (s.cat === 'rpc' && (s.rpcType === 102 || s.rpcType === 103)) return true; break;
      case 'ok': if (s.cat === 'rpc' && (s.rpcType === 200 || s.rpcType === 201)) return true; break;
      case 'ev': if (s.cat === 'rpc' && s.rpcType === 204) return true; break;
      case 'err': if (s.isError) return true; break;
      case 'auth': if (s.cat === 'auth') return true; break;
      case 'data': if (s.cat === 'data') return true; break;
      case 'sys': if (s.cat === 'system' || s.cat === 'raw' || s.cat === 'parse-error') return true; break;
    }
  }
  return false;
}

function searchOf(s) {
  if (!s._search) {
    s._search = [s.outerType, s.zcodeType, s.typeName, s.channel, s.method, s.title,
      s.snippet, s.rpcId == null ? '' : String(s.rpcId), s.wsUrl].join(' ').toLowerCase();
  }
  return s._search;
}

function passes(s) {
  if (state.tabFilter !== 'all' && s.tabId !== state.tabFilter) return false;
  if (state.dir !== 'all' && s.dir !== state.dir) return false;
  if (!state.showIncomplete && s.incomplete) return false;
  if (state.cats.size && !chipMatch(s)) return false;
  if (state.query) {
    const hay = searchOf(s);
    if (state.queryRe) { if (!state.queryRe.test(hay)) return false; }
    else if (!hay.includes(state.queryLower)) return false;
  }
  return true;
}

function applyFilters() {
  state.filtered = state.summaries.filter(passes);
  renderList();
  updateStatusBar();
}

// ── 列表 ──
function renderList() {
  const list = $('list');
  list.innerHTML = '';
  state.domCount = 0;
  const tail = state.filtered.slice(-MAX_DOM_ROWS);
  const frag = document.createDocumentFragment();
  for (const s of tail) frag.appendChild(rowEl(s));
  list.appendChild(frag);
  state.domCount = tail.length;
  $('listNote').textContent = state.filtered.length > MAX_DOM_ROWS
    ? `仅显示最近 ${MAX_DOM_ROWS} 条 / 共 ${state.filtered.length} 条匹配`
    : (state.filtered.length ? `共 ${state.filtered.length} 条` : '');
  if (state.autoScroll) scrollBottom();
}

function appendRow(s) {
  const list = $('list');
  const stick = atBottom(); // 用户手动上翻时不强制拉回底部
  if (state.domCount >= MAX_DOM_ROWS && list.firstChild) {
    list.removeChild(list.firstChild);
    state.domCount--;
  }
  list.appendChild(rowEl(s));
  state.domCount++;
  if (state.autoScroll && stick) scrollBottom();
}

function atBottom() {
  const w = $('listWrap');
  return w.scrollHeight - w.scrollTop - w.clientHeight < 48;
}
function scrollBottom() {
  const w = $('listWrap');
  w.scrollTop = w.scrollHeight;
}

function fmtTime(ts) {
  const d = new Date(ts);
  const p = (n, l = 2) => String(n).padStart(l, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function fmtBytes(n) {
  if (n == null) return '';
  if (n < 1024) return `${n}B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)}KB`;
  return `${(n / 1024 / 1024).toFixed(2)}MB`;
}

function badgeOf(s) {
  if (s.cat === 'rpc') {
    if (s.isError) return ['errb', s.typeName || 'ERR'];
    switch (s.rpcType) {
      case 100: return ['req', 'REQ'];
      case 102: return ['listen', 'LISTEN'];
      case 103: return ['listen', 'UNSUB'];
      case 200: case 201: return ['ok', s.typeName || 'OK'];
      case 204: return ['ev', 'EVENT'];
      default: return ['sys', s.typeName || 'RPC'];
    }
  }
  if (s.cat === 'auth') return ['auth', 'AUTH'];
  if (s.cat === 'data') return ['data', 'DATA'];
  if (s.isError || s.cat === 'parse-error') return ['errb', 'ERR'];
  return ['sys', 'SYS'];
}

function rowEl(s) {
  const r = document.createElement('div');
  r.className = 'row' + (s.isError ? ' err' : '') + (s.id === state.selectedId ? ' selected' : '');
  r.dataset.id = s.id;

  const [bc, bt] = badgeOf(s);
  const cells = [
    ['span', 't', fmtTime(s.ts)],
    ['span', 'dir ' + s.dir, s.dir === 'send' ? '↑' : s.dir === 'recv' ? '↓' : '·'],
    ['span', 'badge ' + bc, bt],
    ['span', 'chan', s.channel ? `${s.channel}${s.method ? '.' + s.method : ''}` : (s.title || '')],
    ['span', 'snippet', s.snippet || ''],
    ['span', 'sz', s.sizeBytes ? fmtBytes(s.sizeBytes) : (s.sizeText ? `${s.sizeText}c` : '')],
    ['span', 'fg', s.fragCount > 1 ? `⧉${s.fragCount}` : ''],
  ];
  for (const [tag, cls, text] of cells) {
    const el = document.createElement(tag);
    el.className = cls;
    el.textContent = text;
    if (cls === 'chan') el.title = s.wsUrl || '';
    r.appendChild(el);
  }
  r.addEventListener('click', () => select(s.id));
  return r;
}

function select(id) {
  if (state.selectedId === id) return;
  state.selectedId = id;
  for (const row of $('list').children) {
    row.classList.toggle('selected', Number(row.dataset.id) === id);
  }
  renderDetailLoading(id);
  getEntry(id).then((d) => { if (state.selectedId === id) renderDetail(d); });
}

// ── 详情 ──
function renderDetailEmpty() {
  $('detail').innerHTML = '';
  const d = document.createElement('div');
  d.className = 'd-empty';
  d.textContent = '← 点击左侧日志条目查看详情';
  $('detail').appendChild(d);
}

function renderDetailLoading(id) {
  $('detail').innerHTML = '';
  const d = document.createElement('div');
  d.className = 'd-empty';
  d.textContent = `加载条目 #${id}…`;
  $('detail').appendChild(d);
}

function metaRow(k, v) {
  const tr = document.createElement('tr');
  const kd = document.createElement('td');
  kd.className = 'k'; kd.textContent = k;
  const vd = document.createElement('td');
  vd.className = 'v'; vd.textContent = v;
  tr.append(kd, vd);
  return tr;
}

function section(title, open_ = false) {
  const det = document.createElement('details');
  det.className = 'sec';
  if (open_) det.open = true;
  const sum = document.createElement('summary');
  sum.textContent = title;
  const body = document.createElement('div');
  body.className = 'secBody';
  det.append(sum, body);
  return [det, body];
}

function renderDetail(d) {
  const root = $('detail');
  root.innerHTML = '';
  if (!d) {
    const e = document.createElement('div');
    e.className = 'd-empty';
    e.textContent = '条目已过期 (被环形缓冲淘汰)';
    root.appendChild(e);
    return;
  }

  // 头部
  const head = document.createElement('div');
  head.className = 'd-head';
  const [bc, bt] = badgeOf(d);
  const badge = document.createElement('span');
  badge.className = 'badge ' + bc;
  badge.textContent = bt;
  const title = document.createElement('span');
  title.className = 'title';
  title.textContent = d.title || '';
  const actions = document.createElement('div');
  actions.className = 'd-actions';
  head.append(badge, title, actions);
  root.appendChild(head);

  // 元信息
  const meta = document.createElement('div');
  meta.className = 'meta';
  const tbl = document.createElement('table');
  const tbody = document.createElement('tbody');
  const rows = [
    ['时间', `${new Date(d.ts).toLocaleString('zh-CN')}.${String(new Date(d.ts).getMilliseconds()).padStart(3, '0')}`],
    ['方向', d.dir === 'send' ? '↑ 客户端 → 服务端' : d.dir === 'recv' ? '↓ 服务端 → 客户端' : '系统事件'],
    ['标签页', `#${d.tabId}`],
    ['WebSocket', d.wsUrl || '(未知 — 抓包前已建立)'],
    ['外层 type', d.outerType || ''],
    ['zcode_type', d.zcodeType || ''],
  ];
  if (d.cat === 'rpc') {
    rows.push(['RPC 类型', `${d.typeName} (typeCode=${d.rpcType})`]);
    rows.push(['RPC id / 订阅号', d.rpcId == null ? '' : String(d.rpcId)]);
    rows.push(['channel.method', `${d.channel || ''}${d.method ? '.' + d.method : ''}`]);
    rows.push(['RPC 字节数', d.sizeBytes ? `${d.sizeBytes} B (dataBase64 解码)` : '']);
    if (d.fragCount > 1) rows.push(['分片', `#${d.fragSeq} · 共 ${d.fragCount} 片, 已重组`]);
  } else if (d.incomplete) {
    rows.push(['分片', `#${d.fragSeq ?? '?'} · 仅收到部分, 未收齐`]);
  }
  rows.push(['WS 帧大小', d.sizeText ? `${d.sizeText} 字符` : '']);
  for (const [k, v] of rows) if (v !== '' && v != null) tbody.appendChild(metaRow(k, v));
  tbl.appendChild(tbody);
  meta.appendChild(tbl);
  root.appendChild(meta);

  if (d.decodeError) {
    const de = document.createElement('div');
    de.className = 'decodeError';
    de.textContent = '解码失败: ' + d.decodeError;
    root.appendChild(de);
  }

  // 操作按钮
  const mkBtn = (label, fn) => {
    const b = document.createElement('button');
    b.textContent = label;
    b.onclick = async () => {
      try { await fn(); b.textContent = '已复制 ✓'; setTimeout(() => (b.textContent = label), 1200); }
      catch { b.textContent = '复制失败'; setTimeout(() => (b.textContent = label), 1200); }
    };
    return b;
  };
  const copyText = (t) => navigator.clipboard.writeText(t);
  if (d.body != null) actions.appendChild(mkBtn('复制 Body', () => copyText(JSON.stringify(d.body, null, 2))));
  if (d.payload || d.msg) {
    actions.appendChild(mkBtn('复制外层 JSON', () => copyText(JSON.stringify(d.payload || d.msg, null, 2))));
  }
  if (d.rawText) actions.appendChild(mkBtn('复制原始帧', () => copyText(d.rawText)));

  // RPC body
  if (d.cat === 'rpc' && d.body != null) {
    const [sec, body] = section('RPC Body (dataBase64 解码)', true);
    const tree = document.createElement('div');
    tree.className = 'tree';
    buildTree(tree, d.body, 0);
    body.appendChild(tree);
    root.appendChild(sec);
  }

  // 数据层 payload
  if (d.payload) {
    const [sec, body] = section('data 层 payload (dataBase64 已折叠)', true);
    const tree = document.createElement('div');
    tree.className = 'tree';
    buildTree(tree, d.payload, 0);
    body.appendChild(tree);
    root.appendChild(sec);
  }

  // 认证等外层消息
  if (d.msg && !d.payload) {
    const [sec, body] = section('WS 消息 (外层 JSON)', true);
    const tree = document.createElement('div');
    tree.className = 'tree';
    buildTree(tree, d.msg, 0);
    body.appendChild(tree);
    root.appendChild(sec);
  }

  // hex
  if (d.hexPreview) {
    const [sec, body] = section('RPC 原始字节 (hex dump)');
    const pre = document.createElement('pre');
    pre.className = 'hex';
    pre.textContent = d.hexPreview;
    body.appendChild(pre);
    root.appendChild(sec);
  }

  // 原始文本
  if (d.rawText) {
    const [sec, body] = section('WS 原始文本帧');
    const pre = document.createElement('pre');
    pre.className = 'raw';
    pre.textContent = d.rawText.length > 100_000
      ? d.rawText.slice(0, 100_000) + `\n…(显示截断, 共 ${d.rawText.length} 字符, 用「复制原始帧」取完整)`
      : d.rawText;
    body.appendChild(pre);
    root.appendChild(sec);
  }
}

// ── JSON 树 ──
const B64_RE = /^[A-Za-z0-9+/]{48,}={0,2}$/;

function kspan(key) {
  const el = document.createElement('span');
  el.className = 'tkey';
  el.textContent = key + ': ';
  return el;
}

function tryUtf8(bytes) {
  let printable = 0;
  const n = Math.min(bytes.length, 4096);
  for (let i = 0; i < n; i++) {
    const b = bytes[i];
    if ((b >= 32 && b < 127) || b === 10 || b === 13 || b === 9 || b >= 0x80) printable++;
  }
  return n > 0 && printable / n > 0.92;
}

function decodeB64(s) {
  try {
    const clean = s.replace(/\s+/g, '');
    const bin = atob(clean);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch { return null; }
}

function leaf(key, v) {
  const frag = document.createDocumentFragment();
  if (key !== '') frag.appendChild(kspan(key));
  const el = document.createElement('span');
  el.className = 'tval';
  if (v === null) { el.classList.add('n'); el.textContent = 'null'; }
  else if (typeof v === 'number') { el.classList.add('n'); el.textContent = String(v); }
  else if (typeof v === 'boolean') { el.classList.add('b'); el.textContent = String(v); }
  else if (typeof v === 'string') {
    el.classList.add('s');
    if (v.length > 1200) {
      el.textContent = JSON.stringify(v.slice(0, 1200)).slice(0, 1200) + `…(共${v.length}字符)`;
      const btn = document.createElement('button');
      btn.className = 'xbtn';
      btn.textContent = '展开全部';
      btn.onclick = (ev) => {
        ev.stopPropagation();
        el.textContent = JSON.stringify(v);
        btn.remove();
      };
      frag.append(el, btn);
    } else {
      el.textContent = JSON.stringify(v);
      frag.appendChild(el);
      // base64 字段智能解码预览 (bytes / archive / 附件分块 data 等)
      if (B64_RE.test(v.replace(/\s+/g, '')) && v.length >= 48) {
        const bytes = decodeB64(v);
        if (bytes && bytes.length >= 16 && bytes.length <= 2_000_000) {
          const prev = document.createElement('span');
          prev.className = 'b64prev';
          if (tryUtf8(bytes)) {
            const text = new TextDecoder().decode(bytes.slice(0, 600));
            prev.textContent = `↳ base64 解码 ${bytes.length}B (文本): ${text}${bytes.length > 600 ? '…' : ''}`;
          } else {
            prev.textContent = `↳ base64 解码 ${bytes.length}B (二进制): ${Array.from(bytes.slice(0, 16)).map((b) => b.toString(16).padStart(2, '0')).join(' ')} …`;
          }
          frag.appendChild(prev);
        }
      }
      return frag;
    }
    return frag;
  } else if (v && v.__binary) {
    el.classList.add('bin');
    el.textContent = `⟨binary ${v.length}B⟩ ${v.hex || ''}`;
    frag.appendChild(el);
    return frag;
  } else {
    el.textContent = String(v);
    frag.appendChild(el);
    return frag;
  }
  frag.appendChild(el);
  return frag;
}

function buildTree(container, value, depth, key = '') {
  const wrap = document.createElement('div');
  wrap.className = 'tnode';
  const isObj = value && typeof value === 'object' && !value.__binary;

  if (!isObj) {
    wrap.appendChild(leaf(key, value));
    container.appendChild(wrap);
    return;
  }

  const isArray = Array.isArray(value);
  const keys = isArray ? value.map((_, i) => i) : Object.keys(value);
  const head = document.createElement('div');
  head.className = 'thead';
  const caret = document.createElement('span');
  caret.className = 'caret';
  head.appendChild(caret);
  if (key !== '') head.appendChild(kspan(key));
  const hint = document.createElement('span');
  hint.className = 'thint';
  hint.textContent = isArray ? `Array(${keys.length})` : `{${keys.length}}`;
  head.appendChild(hint);
  const kids = document.createElement('div');
  kids.className = 'tkids';
  wrap.append(head, kids);

  const renderKids = () => {
    for (const k of keys) buildTree(kids, value[k], depth + 1, isArray ? '' : k);
    kids.dataset.done = '1';
  };
  // 大数组默认折叠
  if (depth < 2 && keys.length <= 200) {
    renderKids();
    wrap.classList.add('open');
  }
  head.onclick = (ev) => {
    ev.stopPropagation();
    wrap.classList.toggle('open');
    if (wrap.classList.contains('open') && !kids.dataset.done) renderKids();
  };
  container.appendChild(wrap);
}

// ── 顶栏 ──
function renderCaps() {
  const el = $('caps');
  el.innerHTML = '';
  if (!state.caps.length) {
    const hint = document.createElement('span');
    hint.className = 'hint';
    hint.textContent = '未开始抓包 — 点击浏览器工具栏扩展图标 → 开始抓包';
    el.appendChild(hint);
    return;
  }
  const mk = (tabId, label) => {
    const c = document.createElement('span');
    c.className = 'cap' + (state.tabFilter === tabId ? ' on' : '');
    c.textContent = label;
    c.title = label;
    c.onclick = () => { state.tabFilter = tabId; renderCaps(); applyFilters(); };
    return c;
  };
  el.appendChild(mk('all', `全部 (${state.caps.length})`));
  for (const t of state.caps) {
    el.appendChild(mk(t.tabId, `#${t.tabId} ${(t.title || t.url || '').slice(0, 24)}`));
  }
}

function updateStatusBar() {
  const shown = state.filtered.length;
  let send = 0, recv = 0;
  for (const s of state.filtered) { if (s.dir === 'send') send++; else if (s.dir === 'recv') recv++; }
  const parts = [
    `共 <b>${state.counts.total}</b> 条 (缓冲上限 ${state.maxEntries})`,
    `<span class="sep">·</span>显示 <b>${shown}</b>`,
    `<span class="sep">·</span><span style="color:var(--send)">↑${send}</span> <span style="color:var(--recv)">↓${recv}</span>`,
    `<span class="sep">·</span>错误 <b style="color:var(--errc)">${state.counts.err}</b>`,
  ];
  if (state.pendingFrags) parts.push(`<span class="sep">·</span>分片待收齐 ${state.pendingFrags}`);
  if (state.paused) parts.push(`<span class="sep">·</span>⏸ 已暂停渲染 (仍在后台记录)`);
  setStatus(parts.join(' '));
}
function setStatus(html) { $('statusBar').innerHTML = html; }

// ── 导出 ──
async function doExport() {
  const src = state.filtered.length ? state.filtered : state.summaries;
  const list = src.slice(-2000);
  if (!list.length) { setStatus('没有可导出的条目'); return; }
  const btn = $('exportBtn');
  btn.disabled = true;
  const lines = [];
  try {
    for (let i = 0; i < list.length; i++) {
      const d = await getEntry(list[i].id);
      lines.push(JSON.stringify(d || list[i]));
      if (i % 50 === 0) {
        btn.textContent = `导出中 ${i}/${list.length}`;
        await new Promise((r) => setTimeout(r, 0));
      }
    }
    const blob = new Blob([lines.join('\n') + '\n'], { type: 'application/x-ndjson' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `zcode-wss-${new Date().toISOString().replace(/[:.]/g, '-')}.ndjson`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    setStatus(`已导出 ${list.length} 条 → ${a.download}`);
  } finally {
    btn.disabled = false;
    btn.textContent = '导出 NDJSON';
  }
}

// ── 事件绑定 ──
$('searchInput').addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    const raw = $('searchInput').value.trim();
    state.query = raw;
    state.queryLower = raw.toLowerCase();
    state.queryRe = null;
    if (raw && $('regexChk').checked) {
      try {
        state.queryRe = new RegExp(raw, 'i');
        $('searchInput').classList.remove('invalid');
      } catch {
        $('searchInput').classList.add('invalid');
      }
    } else {
      $('searchInput').classList.remove('invalid');
    }
    applyFilters();
  }, 250);
});
$('regexChk').addEventListener('change', () => $('searchInput').dispatchEvent(new Event('input')));
$('dirSel').addEventListener('change', (e) => { state.dir = e.target.value; applyFilters(); });
$('fragChk').addEventListener('change', (e) => { state.showIncomplete = e.target.checked; applyFilters(); });
$('scrollChk').addEventListener('change', (e) => {
  state.autoScroll = e.target.checked;
  if (state.autoScroll) scrollBottom();
});
$('pauseBtn').addEventListener('click', () => {
  state.paused = !state.paused;
  $('pauseBtn').textContent = state.paused ? '▶ 继续' : '⏸ 暂停';
  $('pauseBtn').classList.toggle('paused', state.paused);
  if (!state.paused) { applyFilters(); }
  else updateStatusBar();
});
$('clearBtn').addEventListener('click', () => {
  chrome.runtime.sendMessage({ t: 'clear' });
});
$('exportBtn').addEventListener('click', doExport);

// 渲染类型 chips
for (const c of CAT_CHIPS) {
  const chip = document.createElement('span');
  chip.className = 'chip';
  chip.textContent = c.label;
  chip.dataset.k = c.k;
  chip.onclick = () => {
    if (state.cats.has(c.k)) state.cats.delete(c.k);
    else state.cats.add(c.k);
    chip.classList.toggle('on', state.cats.has(c.k));
    applyFilters();
  };
  $('catChips').appendChild(chip);
}

renderDetailEmpty();
renderCaps();
connect();
