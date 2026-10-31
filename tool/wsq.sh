#!/usr/bin/env bash
# wsq — 查询 chrome-wss-inspector 导出的 zcode WSS 抓包 NDJSON
#
# 用法:
#   wsq latest [N]              最近 N 个抓包文件 (默认 8, 含 zcode-wss-auto/)
#   wsq types  <file>           帧类型分布 (zcodeType / channel.method)
#   wsq calls  <file>           RPC 调用配对: REQ → OK/ERR, 按耗时排序
#   wsq chan   <file> <正则>    channel/method 匹配的帧摘要
#   wsq grep   <file> <正则>    按 title/snippet 搜帧摘要
#   wsq text   <file> <正则>    深度搜整帧 JSON (慢, 含 payload/rawText)
#   wsq frame  <file> <id>      单帧完整 JSON
#   wsq tail   <file> [N]       最后 N 帧摘要 (默认 30)
#
# 文件参数可写全路径, 也可只写文件名 (自动到 $WSQ_DIR 找, 默认 ~/下载)。
# 例: wsq calls zcode-wss-auto/zcode-wss-auto-2026-10-27T09-14-21-623Z.ndjson
set -euo pipefail

DIR="${WSQ_DIR:-$HOME/下载}"
BRIEF='[.ts, .dir, (.typeName // .zcodeType // .outerType // ""), ((.channel + "/" + .method) // ""), (.id|tostring), (.snippet // "") | @tsv]'

err() { echo "用法: $0 latest|types|calls|chan|grep|text|frame|tail  (详见文件头注释)" >&2; exit 1; }
[ $# -ge 1 ] || err

# 文件名 → 全路径
resolve() {
  local f="$1"
  if [ -f "$f" ]; then echo "$f"
  elif [ -f "$DIR/$f" ]; then echo "$DIR/$f"
  else echo "找不到抓包文件: $f (搜索目录 $DIR)" >&2; exit 1; fi
}

# 摘要行: 时间 方向 类型 channel/method id snippet
brief() {
  jq -r '.ts |= (./1000 | strftime("%H:%M:%S")) | [.ts, .dir, (.typeName // .zcodeType // .outerType // "?"), (if .channel != "" then .channel + "/" + .method else "" end), (.id|tostring), ((.snippet // "") | gsub("[\\t\\n\\r]"; " ") | .[0:120])] | @tsv' 2>/dev/null \
  | awk -F'\t' '{printf "%s %-4s %-10s %-45s %-5s %s\n", $1, $2, $3, $4, $5, substr($0, index($0,$6))}' \
  | cut -c1-220
}

case "$1" in
  latest)
    n="${2:-8}"
    { ls -t "$DIR"/zcode-wss-*.ndjson 2>/dev/null || true
      ls -t "$DIR"/zcode-wss-auto/zcode-wss-auto-*.ndjson 2>/dev/null || true; } | head -"$n" \
    | while IFS= read -r p; do printf '%-8s %s\n' "$(du -h "$p" | cut -f1)" "$p"; done ;;
  types)
    [ $# -ge 2 ] || err; f=$(resolve "$2")
    echo "== 方向/分类 =="; jq -r '[.dir, .cat] | @tsv' "$f" | sort | uniq -c | sort -rn | head -15
    echo "== zcodeType =="; jq -r 'select(.zcodeType != "") | .zcodeType' "$f" | sort | uniq -c | sort -rn | head -20
    echo "== channel/method =="; jq -r 'select(.channel != "") | "\(.typeName)\t\(.channel)/\(.method)"' "$f" | sort | uniq -c | sort -rn | head -30 ;;
  calls)
    [ $# -ge 2 ] || err; f=$(resolve "$2")
    # REQ 与 OK/ERR 按 rpcId 配对, 输出耗时 (ms)
    jq -rs '
      (map(select(.typeName == "REQ")) | map({key: (.rpcId|tostring), value: .}) | from_entries) as $req
      | map(select(.typeName == "OK" or .typeName == "ERR" or .typeName == "ERR_OBJ"))
      | map(select($req[ (.rpcId|tostring) ] != null) 
          | . as $r | ($req[ ($r.rpcId|tostring) ]) as $q
          | {ms: ($r.ts - $q.ts), chan: ($q.channel + "/" + $q.method), status: $r.typeName, rpcId: $r.rpcId, err: ($r.snippet // "")[0:100]})
      | sort_by(.ms) | reverse
      | .[] | [.ms, .status, .chan, (.rpcId|tostring), .err] | @tsv' "$f" \
    | awk -F'\t' '{printf "%6sms  %-7s %-48s id=%-6s %s\n", $1, $2, $3, $4, substr($0, index($0,$5))}' | head -40 ;;
  chan)
    [ $# -ge 3 ] || err; f=$(resolve "$2")
    jq -c "select((.channel + \"/\" + .method) | test(\"$3\"))" "$f" | brief ;;
  grep)
    [ $# -ge 3 ] || err; f=$(resolve "$2")
    jq -c "select(((.title // \"\") + \" \" + (.snippet // \"\")) | test(\"$3\"; \"i\"))" "$f" | brief ;;
  text)
    [ $# -ge 3 ] || err; f=$(resolve "$2")
    jq -c "select(tojson | test(\"$3\"; \"i\"))" "$f" | brief ;;
  frame)
    [ $# -ge 3 ] || err; f=$(resolve "$2")
    jq "select(.id == $3)" "$f" ;;
  tail)
    [ $# -ge 2 ] || err; f=$(resolve "$2"); n="${3:-30}"
    tail -n "$n" "$f" | jq -c '.' | brief ;;
  *) err ;;
esac
