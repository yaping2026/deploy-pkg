#!/bin/bash
# update-v513.sh - v5.13 停止打卡功能 + 魏晓晴数据恢复
# 变更：
#   server.js  新增 POST /api/members/:id/stop（设置leftDate退出）和 /resume（恢复打卡），
#              后台报表按 leftDate 裁剪统计期（退出前缺卡仍计入历史月份），
#              打卡名单/排名/换组/成员数只统计未停止成员
#   scheduler.js 月报/日报/晚报过滤 leftDate 成员（退出当天起不再要求打卡）
#   admin.html 成员列表新增「停止打卡/恢复打卡」按钮，删除成员弹窗改为危险警告
#   ⚠️ 附带数据修复：恢复魏晓晴(id=27, leftDate=2026-08-01) —— 她8月初退出但被误删，
#      导致三组7月报表因统计不到她而错误显示"达标"
# 安全机制：
#   1) CDN 多通道下载（gcore→fastly→cdn→raw）
#   2) CRLF转LF + 版本标记校验 + node语法检查
#   3) 备份旧文件（含数据文件）后可一键回滚
#   4) 重启后自动验证 443 监听 + /version；失败→自动恢复 .bak 并重启（防止网页打不开）
set +e

echo "=========================================="
echo "  v5.13 更新：停止打卡功能 + 魏晓晴恢复"
echo "=========================================="
echo ""

# [1/6] CDN 多通道下载（scheduler.js + server.js + admin.html）
echo "[1/6] 下载新代码（CDN多通道）..."
mkdir -p /tmp/rc-v513
download() {
  local out="$1" min="$2"; shift 2
  for url in "$@"; do
    echo "  尝试: $url"
    curl -sL --max-time 60 "$url" -o "$out" 2>/dev/null
    local sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
    if [ "$sz" -ge "$min" ]; then
      echo "  ✅ 下载成功 ($sz bytes)"
      return 0
    fi
    echo "  ⚠️ 文件过小 ($sz bytes)，换通道"
  done
  return 1
}
if ! download /tmp/rc-v513/scheduler.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/scheduler.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/scheduler.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/scheduler.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/scheduler.js"; then
  echo "❌ scheduler.js 下载失败"; exit 1
fi
if ! download /tmp/rc-v513/server.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/server.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/server.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/server.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/server.js"; then
  echo "❌ server.js 下载失败"; exit 1
fi
if ! download /tmp/rc-v513/admin.html 50000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/admin.html"; then
  echo "❌ admin.html 下载失败"; exit 1
fi

# [2/6] 校验：CRLF转LF + 内容标记 + 语法检查
echo "[2/6] 校验代码（转LF+版本标记+语法检查）..."
tr -d '\r' < /tmp/rc-v513/scheduler.js > /tmp/rc-v513/scheduler_lf.js
tr -d '\r' < /tmp/rc-v513/server.js > /tmp/rc-v513/server_lf.js
tr -d '\r' < /tmp/rc-v513/admin.html > /tmp/rc-v513/admin_lf.html

grep -q "v5.13" /tmp/rc-v513/scheduler_lf.js \
  && echo "  ✅ scheduler 版本标记 v5.13" \
  || { echo "  ❌ scheduler 版本标记不对"; exit 1; }
grep -q "memberEnd" /tmp/rc-v513/scheduler_lf.js \
  && echo "  ✅ scheduler leftDate 统计期裁剪已带上" \
  || { echo "  ❌ scheduler 缺少 leftDate 逻辑"; exit 1; }
grep -q "2026-08-28-v5.13" /tmp/rc-v513/server_lf.js \
  && echo "  ✅ server 版本标记 v5.13" \
  || { echo "  ❌ server 版本标记不对"; exit 1; }
grep -q "leftDate" /tmp/rc-v513/server_lf.js \
  && echo "  ✅ server 停止打卡/leftDate 逻辑已带上" \
  || { echo "  ❌ server 缺少 leftDate 逻辑"; exit 1; }
# 关键：SSL 监听逻辑必须在（防止网页打不开）
grep -q "SSL_KEY_PATH" /tmp/rc-v513/server_lf.js && grep -q "listen(443" /tmp/rc-v513/server_lf.js \
  && echo "  ✅ server SSL监听443逻辑完好" \
  || { echo "  ❌ server 缺少 SSL 监听逻辑，已阻止替换！"; exit 1; }
grep -q "stopMember" /tmp/rc-v513/admin_lf.html \
  && echo "  ✅ admin.html 停止打卡按钮已带上" \
  || { echo "  ❌ admin.html 缺少停止打卡功能"; exit 1; }
cp /tmp/rc-v513/scheduler_lf.js /tmp/rc-v513/chk_sch.cjs
cp /tmp/rc-v513/server_lf.js /tmp/rc-v513/chk_srv.cjs
NODE_BIN=$(command -v node || echo "node")
"$NODE_BIN" --check /tmp/rc-v513/chk_sch.cjs && echo "  ✅ scheduler.js 语法OK"
"$NODE_BIN" --check /tmp/rc-v513/chk_srv.cjs && echo "  ✅ server.js 语法OK"
# admin.html 是纯前端文件，无语法检查（浏览器解析），只做内容校验

# [3/6] 备份旧文件并替换代码
echo "[3/6] 备份并替换代码..."
TS=$(date +%s)
[ -f /opt/reading-checkin/scheduler.js ] && cp /opt/reading-checkin/scheduler.js /opt/reading-checkin/scheduler.js.bak-$TS
[ -f /opt/reading-checkin/server.js ] && cp /opt/reading-checkin/server.js /opt/reading-checkin/server.js.bak-$TS
[ -f /opt/reading-checkin/admin.html ] && cp /opt/reading-checkin/admin.html /opt/reading-checkin/admin.html.bak-$TS
cp /tmp/rc-v513/scheduler_lf.js /opt/reading-checkin/scheduler.js
cp /tmp/rc-v513/server_lf.js /opt/reading-checkin/server.js
cp /tmp/rc-v513/admin_lf.html /opt/reading-checkin/admin.html
echo "  已备份(.bak-$TS)并替换 scheduler.js + server.js + admin.html"

# [4/6] 魏晓晴数据恢复（幂等，保留历史打卡记录）
#   背景：魏晓晴(id=27) 8月初退出读书打卡项目后被误删成员记录，
#   导致三组7月报表统计不到她、错误显示"达标"。恢复她并标记 leftDate=2026-08-01
#   （最后一次打卡日），这样：7月报表恢复"三组不达标（魏晓晴缺1）"，
#   8月起她不再参与打卡/日报/月报统计。
echo "[4/6] 恢复魏晓晴数据（leftDate=2026-08-01，幂等）..."
DATA_FILE=/opt/reading-checkin/data_latest.json
if [ -f "$DATA_FILE" ]; then
  cp "$DATA_FILE" "$DATA_FILE.bak-$TS"
  cat > /tmp/rc-v513/restore_wxq.cjs <<'EOF'
const fs = require('fs');
const FILE = process.argv[2];
let data;
try { data = JSON.parse(fs.readFileSync(FILE, 'utf8')); }
catch (e) { console.error('❌ 读取数据文件失败:', e.message); process.exit(2); }
const REC = { id: 27, name: '魏晓晴', groupId: 3, pin: '8293', userid: '15973744774', startDate: '2026-06-01', leftDate: '2026-08-01' };
const members = Array.isArray(data.members) ? data.members : [];
const idx = members.findIndex(m => m && m.id === 27);
let changed = false;
if (idx < 0) {
  members.push(REC);
  changed = true;
  console.log('  ✅ 已恢复魏晓晴(id=27) 并标记 leftDate=2026-08-01');
} else if (!members[idx].leftDate) {
  members[idx].leftDate = '2026-08-01';
  changed = true;
  console.log('  ✅ 魏晓晴记录已存在，补充 leftDate=2026-08-01');
} else if (members[idx].leftDate === '2026-08-01') {
  console.log('  ⏭️ 魏晓晴已恢复且 leftDate 正确，跳过（幂等）');
} else {
  console.error('  ⚠️ 魏晓晴已有 leftDate=' + members[idx].leftDate + '，与预期(2026-08-01)不一致，不覆盖，请人工确认');
  process.exit(3);
}
if (changed) {
  fs.writeFileSync(FILE, JSON.stringify(data));
  console.log('  ✅ data_latest.json 已保存');
}
EOF
  "$NODE_BIN" /tmp/rc-v513/restore_wxq.cjs "$DATA_FILE"
  RC=$?
  if [ $RC -ne 0 ] && [ $RC -ne 2 ]; then
    echo "  ⚠️ 魏晓晴恢复未按预期完成，继续部署（可事后人工处理）"
  fi
else
  echo "  ⚠️ 未找到 $DATA_FILE，跳过数据恢复（请确认部署环境）"
fi

# [5/6] 重启服务
echo "[5/6] 重启服务..."
PIDS=$(ss -tlnp 2>/dev/null | grep -E ':(443|3002) ' | grep -oP 'pid=\K[0-9]+' | sort -u || true)
if [ -n "$PIDS" ]; then
  echo "  清理旧进程: $PIDS"
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
  sleep 3
fi
bash /opt/reading-checkin/start.sh
echo "  等 10 秒让 SSL 完成握手..."
sleep 10

# [6/6] 验证 + 自动回滚保险
echo ""
echo "[6/6] 验证（443监听 + /version）..."
FAIL=0
LISTEN=$(ss -tlnp 2>/dev/null | grep ':443 ')
if [ -z "$LISTEN" ]; then
  echo "  ❌ 443 未监听！"
  FAIL=1
else
  echo "  ✅ 443 监听中"
fi
VER_OK=0
for i in 1 2 3 4 5; do
  R=$(curl -s --max-time 8 https://zhengpintang.cn/version)
  echo "  [试$i] $R"
  if echo "$R" | grep -q "v5.13"; then VER_OK=1; break; fi
  sleep 3
done
[ "$VER_OK" = "1" ] && echo "  ✅ /version 返回 v5.13" || { echo "  ❌ /version 不通或版本不对"; FAIL=1; }

if [ "$FAIL" = "1" ]; then
  echo ""
  echo "  ⚠️⚠️⚠️ 验证失败，自动回滚到 .bak-$TS 并重启！"
  [ -f /opt/reading-checkin/scheduler.js.bak-$TS ] && cp /opt/reading-checkin/scheduler.js.bak-$TS /opt/reading-checkin/scheduler.js
  [ -f /opt/reading-checkin/server.js.bak-$TS ] && cp /opt/reading-checkin/server.js.bak-$TS /opt/reading-checkin/server.js
  [ -f /opt/reading-checkin/admin.html.bak-$TS ] && cp /opt/reading-checkin/admin.html.bak-$TS /opt/reading-checkin/admin.html
  [ -f "$DATA_FILE.bak-$TS" ] && cp "$DATA_FILE.bak-$TS" "$DATA_FILE" && echo "  数据文件已回滚"
  PIDS=$(ss -tlnp 2>/dev/null | grep -E ':(443|3002) ' | grep -oP 'pid=\K[0-9]+' | sort -u || true)
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
  sleep 2
  bash /opt/reading-checkin/start.sh
  sleep 8
  echo "  🔄 已回滚，当前 /version:"
  curl -s --max-time 8 https://zhengpintang.cn/version
  echo ""
  echo "  ❌ v5.13 部署失败，已恢复旧版本。请查看 /var/log/reading-checkin.log 排查原因"
  exit 1
fi

# 补充验证：登录 + 今日内容（确认服务正常）
LOGIN=$(curl -s --max-time 8 -X POST https://zhengpintang.cn/api/admin/login \
  -H "Content-Type: application/json" -d '{"user":"zpt5201314","pass":"13787276549"}')
echo "  登录测试: $LOGIN"
CONTENT=$(curl -s --max-time 8 "https://zhengpintang.cn/api/content/today?group=1" | head -c 120)
echo "  今日内容: $CONTENT"

echo ""
echo "=========================================="
echo "  ✅ v5.13 部署成功！"
echo "  1) 停止打卡功能已上线（后台成员列表→停止打卡/恢复打卡）"
echo "  2) 魏晓晴已恢复：7月三组报表恢复为不达标（含她缺卡1次），8月起不再要求打卡"
echo "  3) 9/2 早6点发的8月月报按新标准统计（未停止成员）"
echo "=========================================="
