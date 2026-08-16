// popup 逻辑 (必须外置文件: MV3 CSP 禁止内联脚本)
'use strict';

let currentTab = null;
let statusTimer = null;

const $ = (id) => document.getElementById(id);

function refresh() {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    currentTab = tabs && tabs[0];
    const url = currentTab ? currentTab.url : '';
    const ok = /^(https?|file):/.test(url || '');
    $('target').textContent = currentTab ? `当前页面: ${url}` : '未找到活动标签页';
    $('attachBtn').disabled = !ok;
    chrome.runtime.sendMessage({ t: 'status' }, (st) => {
      if (chrome.runtime.lastError || !st) return;
      const attachedHere = currentTab && st.attached.some((t) => t.tabId === currentTab.id);
      $('dot').classList.toggle('on', !!attachedHere);
      $('attachBtn').disabled = !ok || !!attachedHere;
      $('detachBtn').disabled = !attachedHere;
      const stHere = attachedHere ? '抓包中 · ' : (st.attached.length ? '其他标签页抓包中 · ' : '');
      $('stats').innerHTML =
        `${stHere}已捕获 <b>${st.total}</b> 条` +
        (st.pending ? ` · 分片待收齐 <b>${st.pending}</b>` : '') +
        (st.attached.length ? '<br>目标: ' + st.attached.map((t) => `#${t.tabId}`).join(', ') : '');
    });
  });
}

$('attachBtn').onclick = () => {
  if (!currentTab) return;
  $('err').textContent = '';
  const reload = $('reloadChk').checked;
  chrome.runtime.sendMessage({ t: 'attach', tabId: currentTab.id, reload }, (r) => {
    if (chrome.runtime.lastError) { $('err').textContent = chrome.runtime.lastError.message; return; }
    if (!r || !r.ok) { $('err').textContent = (r && r.error) || '附加失败'; return; }
    openPanel();
    window.close();
  });
};

$('detachBtn').onclick = () => {
  chrome.runtime.sendMessage({ t: 'detach', tabId: currentTab ? currentTab.id : null }, () => {
    refresh();
  });
};

$('clearBtn').onclick = () => {
  chrome.runtime.sendMessage({ t: 'clear' }, refresh);
};

function openPanel() {
  chrome.tabs.create({ url: chrome.runtime.getURL('viewer/viewer.html') });
}
$('panelBtn').onclick = openPanel;

refresh();
statusTimer = setInterval(refresh, 1000);
window.addEventListener('unload', () => clearInterval(statusTimer));
