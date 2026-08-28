#!/bin/bash
# update-v5123.sh - v5.12.3 月报达标判定修复
# 变更：scheduler.js 不达标判定改为"用完2次补卡券后还有缺卡(irrecoverableMisses>0)"
#      修复：缺卡1次+已用2张补卡券的成员被误判达标的问题
# 只替换 scheduler.js，server.js / admin.html 不变
set +e

echo "=========================================="
echo "  v5.12.3 更新：月报达标判定修复"
echo "=========================================="
echo ""

# [1/4] CDN 多通道下载（gcore→fastly→cdn→raw）
echo "[1/4] 下载新代码（CDN多通道）..."
mkdir -p /tmp/rc-v5123
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
if ! download /tmp/rc-v5123/scheduler.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5123/scheduler.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5123/scheduler.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5123/scheduler.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5123/scheduler.js"; then
  echo "❌ scheduler.js 下载失败"; exit 1
fi

# [2/4] 校验：CRLF转LF + 内容标记 + 语法检查
echo "[2/4] 校验代码（转LF+内容标记+语法检查）..."
tr -d '\r' < /tmp/rc-v5123/scheduler.js > /tmp/rc-v5123/scheduler_lf.js
if grep -q "2026-08-28-v5.12.3" /tmp/rc-v5123/scheduler_lf.js; then
  echo "  ✅ 版本标记 v5.12.3"
else
  echo "  ❌ 版本标记不对"; exit 1
fi
if grep -q "irrecoverableMisses" /tmp/rc-v5123/scheduler_lf.js; then
  echo "  ✅ 达标判定逻辑(irrecoverableMisses)已带上"
else
  echo "  ❌ 缺少达标判定逻辑"; exit 1
fi
cp /tmp/rc-v5123/scheduler_lf.js /tmp/rc-v5123/chk_sch.cjs
NODE_BIN=$(command -v node || echo "node")
"$NODE_BIN" --check /tmp/rc-v5123/chk_sch.cjs && echo "  ✅ scheduler.js 语法OK"

# [3/4] 备份旧文件并替换 + 重启
echo "[3/4] 备份并替换..."
TS=$(date +%s)
[ -f /opt/reading-checkin/scheduler.js ] && cp /opt/reading-checkin/scheduler.js /opt/reading-checkin/scheduler.js.bak-$TS
cp /tmp/rc-v5123/scheduler_lf.js /opt/reading-checkin/scheduler.js
echo "  已备份(.bak-$TS)并替换 scheduler.js"

echo "[4/4] 重启服务..."
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

echo ""
echo "=========================================="
echo "  验证：版本 + 登录 + 内容"
echo "=========================================="
for i in 1 2 3 4 5; do
  R=$(curl -s --max-time 8 https://zhengpintang.cn/version)
  echo "  [试$i] $R"
  if echo "$R" | grep -q "v5.12.3"; then break; fi
  sleep 3
done
LOGIN=$(curl -s --max-time 8 -X POST https://zhengpintang.cn/api/admin/login \
  -H "Content-Type: application/json" -d '{"user":"zpt5201314","pass":"13787276549"}')
echo "  登录测试: $LOGIN"
CONTENT=$(curl -s --max-time 8 "https://zhengpintang.cn/api/content/today?group=1" | head -c 120)
echo "  今日内容: $CONTENT"

echo ""
echo "=========================================="
echo "  完成！9/2 早6点发的8月月报将正确标记不达标组"
echo "=========================================="
