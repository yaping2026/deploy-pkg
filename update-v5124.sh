#!/bin/bash
# update-v5124.sh - v5.12.4 达标判定对齐用户标准
# 变更：
#   scheduler.js 月报：个人不达标 = 统计周期内存在任意一天未补上的缺卡（不管剩余补卡券）
#     （补卡只能在缺卡次日进行，月报统计时上月所有缺卡均已过补卡期限）
#   server.js 后台报表：不可补救缺卡>=1 即判不达标（原来 >=2 或 =1且券用完），与月报口径一致
# 小组不达标 = 组内任何一人不达标 → 整组不达标
# 替换 scheduler.js + server.js，admin.html 不变
set +e

echo "=========================================="
echo "  v5.12.4 更新：达标判定对齐用户标准"
echo "=========================================="
echo ""

# [1/5] CDN 多通道下载（gcore→fastly→cdn→raw）
echo "[1/5] 下载新代码（CDN多通道）..."
mkdir -p /tmp/rc-v5124
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
if ! download /tmp/rc-v5124/scheduler.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5124/scheduler.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5124/scheduler.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5124/scheduler.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5124/scheduler.js"; then
  echo "❌ scheduler.js 下载失败"; exit 1
fi
if ! download /tmp/rc-v5124/server.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5124/server.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5124/server.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5124/server.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5124/server.js"; then
  echo "❌ server.js 下载失败"; exit 1
fi

# [2/5] 校验：CRLF转LF + 内容标记 + 语法检查
echo "[2/5] 校验代码（转LF+内容标记+语法检查）..."
tr -d '\r' < /tmp/rc-v5124/scheduler.js > /tmp/rc-v5124/scheduler_lf.js
tr -d '\r' < /tmp/rc-v5124/server.js > /tmp/rc-v5124/server_lf.js

if grep -q "2026-08-28-v5.12.4" /tmp/rc-v5124/scheduler_lf.js; then
  echo "  ✅ scheduler 版本标记 v5.12.4"
else
  echo "  ❌ scheduler 版本标记不对"; exit 1
fi
if grep -q "irrecoverableMisses = missedCount" /tmp/rc-v5124/scheduler_lf.js; then
  echo "  ✅ scheduler 达标判定(任意未补缺卡即不达标)已带上"
else
  echo "  ❌ scheduler 缺少新达标判定"; exit 1
fi
if grep -q "2026-08-28-v5.12.4" /tmp/rc-v5124/server_lf.js; then
  echo "  ✅ server 版本标记 v5.12.4"
else
  echo "  ❌ server 版本标记不对"; exit 1
fi
if grep -q "unfixableMisses >= 1" /tmp/rc-v5124/server_lf.js; then
  echo "  ✅ server 后台报表判定(不可补救>=1即不达标)已带上"
else
  echo "  ❌ server 缺少新预警判定"; exit 1
fi
cp /tmp/rc-v5124/scheduler_lf.js /tmp/rc-v5124/chk_sch.cjs
cp /tmp/rc-v5124/server_lf.js /tmp/rc-v5124/chk_srv.cjs
NODE_BIN=$(command -v node || echo "node")
"$NODE_BIN" --check /tmp/rc-v5124/chk_sch.cjs && echo "  ✅ scheduler.js 语法OK"
"$NODE_BIN" --check /tmp/rc-v5124/chk_srv.cjs && echo "  ✅ server.js 语法OK"

# [3/5] 备份旧文件并替换
echo "[3/5] 备份并替换..."
TS=$(date +%s)
[ -f /opt/reading-checkin/scheduler.js ] && cp /opt/reading-checkin/scheduler.js /opt/reading-checkin/scheduler.js.bak-$TS
[ -f /opt/reading-checkin/server.js ] && cp /opt/reading-checkin/server.js /opt/reading-checkin/server.js.bak-$TS
cp /tmp/rc-v5124/scheduler_lf.js /opt/reading-checkin/scheduler.js
cp /tmp/rc-v5124/server_lf.js /opt/reading-checkin/server.js
echo "  已备份(.bak-$TS)并替换 scheduler.js + server.js"

# [4/5] 重启服务
echo "[4/5] 重启服务..."
PIDS=$(ss -tlnp 2>/dev/null | grep -E ':(443|3002) ' | grep -oP 'pid=\K[0-9]+' | sort -u || true)
if [ -n "$PIDS" ]; then
  echo "  清理旧进程: $PIDS"
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
  sleep 3
fi
bash /opt/reading-checkin/start.sh
echo "  等 10 秒让 SSL 完成握手..."
sleep 10
LISTEN=$(ss -tlnp 2>/dev/null | grep ':443 ')
if [ -n "$LISTEN" ]; then
  echo "  ✅ 443 监听中"
else
  echo "  ⚠️ 443 未监听，日志如下："
  tail -25 /var/log/reading-checkin.log 2>/dev/null
fi

# [5/5] 验证：版本 + 登录 + 内容
echo ""
echo "[5/5] 验证：版本 + 登录 + 内容"
echo "=========================================="
for i in 1 2 3 4 5; do
  R=$(curl -s --max-time 8 https://zhengpintang.cn/version)
  echo "  [试$i] $R"
  if echo "$R" | grep -q "v5.12.4"; then break; fi
  sleep 3
done
LOGIN=$(curl -s --max-time 8 -X POST https://zhengpintang.cn/api/admin/login \
  -H "Content-Type: application/json" -d '{"user":"zpt5201314","pass":"13787276549"}')
echo "  登录测试: $LOGIN"
CONTENT=$(curl -s --max-time 8 "https://zhengpintang.cn/api/content/today?group=1" | head -c 120)
echo "  今日内容: $CONTENT"

echo ""
echo "=========================================="
echo "  完成！9/2 早6点发的8月月报将按新标准标记不达标组"
echo "  （个人不达标=存在任意未补缺卡；小组=一人不达标整组不达标）"
echo "=========================================="
