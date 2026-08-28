#!/bin/bash
# update-v5122b.sh - v5.12.2 月报复发修复（原子锁）+ admin.html 抽签修复
# 变更：server.js(v5.12.2) + scheduler.js(月报改用tryAcquireCronLock) + admin.html(v5122抽签修复)
set +e

echo "=========================================="
echo "  v5.12.2 更新：月报只发一次 + 抽签修复"
echo "=========================================="
echo ""

# [1/5] CDN 多通道下载（gcore→fastly→cdn→raw）
echo "[1/5] 下载新代码（CDN多通道）..."
mkdir -p /tmp/rc-v5122b
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
if ! download /tmp/rc-v5122b/server.js 60000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122b/server.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122b/server.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122b/server.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5122b/server.js"; then
  echo "❌ server.js 下载失败"; exit 1
fi
if ! download /tmp/rc-v5122b/scheduler.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122b/scheduler.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122b/scheduler.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122b/scheduler.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5122b/scheduler.js"; then
  echo "❌ scheduler.js 下载失败"; exit 1
fi

# [2/5] 校验：CRLF转LF + 内容标记 + 语法检查
echo "[2/5] 校验代码（转LF+内容标记+语法检查）..."
tr -d '\r' < /tmp/rc-v5122b/server.js > /tmp/rc-v5122b/server_lf.js
tr -d '\r' < /tmp/rc-v5122b/scheduler.js > /tmp/rc-v5122b/scheduler_lf.js
if grep -q "2026-08-28-v5.12.2" /tmp/rc-v5122b/server_lf.js; then
  echo "  ✅ server.js 版本标记 v5.12.2"
else
  echo "  ❌ server.js 版本标记不对"; exit 1
fi
if grep -q "tryAcquireCronLock('monthly'" /tmp/rc-v5122b/scheduler_lf.js; then
  echo "  ✅ scheduler.js 月报原子锁已带上"
else
  echo "  ❌ scheduler.js 缺少月报原子锁"; exit 1
fi
cp /tmp/rc-v5122b/server_lf.js /tmp/rc-v5122b/chk_srv.cjs
cp /tmp/rc-v5122b/scheduler_lf.js /tmp/rc-v5122b/chk_sch.cjs
NODE_BIN=$(command -v node || echo "node")
"$NODE_BIN" --check /tmp/rc-v5122b/chk_srv.cjs && echo "  ✅ server.js 语法OK"
"$NODE_BIN" --check /tmp/rc-v5122b/chk_sch.cjs && echo "  ✅ scheduler.js 语法OK"

# [3/5] 备份旧文件并替换
echo "[3/5] 备份并替换..."
TS=$(date +%s)
[ -f /opt/reading-checkin/server.js ] && cp /opt/reading-checkin/server.js /opt/reading-checkin/server.js.bak-$TS
[ -f /opt/reading-checkin/scheduler.js ] && cp /opt/reading-checkin/scheduler.js /opt/reading-checkin/scheduler.js.bak-$TS
cp /tmp/rc-v5122b/server_lf.js /opt/reading-checkin/server.js
cp /tmp/rc-v5122b/scheduler_lf.js /opt/reading-checkin/scheduler.js
echo "  已备份(.bak-$TS)并替换 server.js / scheduler.js"

# 顺带升级 admin.html（抽签按钮修复）
rm -f /tmp/admin_new.html
for src in \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html"; do
  curl -sL --max-time 45 "$src" -o /tmp/admin_new.html 2>/dev/null
  SZ=$(stat -c%s /tmp/admin_new.html 2>/dev/null || echo 0)
  if [ "$SZ" -gt 30000 ] && grep -q "loadGroups().then(loadRegroup)" /tmp/admin_new.html; then
    cp /tmp/admin_new.html /opt/reading-checkin/public/admin.html
    echo "  admin.html 已升级 (${SZ} bytes)"
    break
  fi
done

# [4/5] 重启（端口定位法：只杀 :443/:3002 的 reading-checkin，绝不碰 health-check 的 :3001）
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
echo "[5/5] 验证..."
for i in 1 2 3 4 5; do
  R=$(curl -s --max-time 8 https://zhengpintang.cn/version)
  echo "  [试$i] $R"
  if echo "$R" | grep -q "v5.12.2"; then break; fi
  sleep 3
done
LOGIN=$(curl -s --max-time 8 -X POST https://zhengpintang.cn/api/admin/login \
  -H "Content-Type: application/json" -d '{"user":"zpt5201314","pass":"13787276549"}')
echo "  登录测试: $LOGIN"
CONTENT=$(curl -s --max-time 8 "https://zhengpintang.cn/api/content/today?group=1" | head -c 120)
echo "  今日内容: $CONTENT"

echo ""
echo "=========================================="
echo "  完成！月报从下月(9/2)起每月只发一次"
echo "=========================================="
