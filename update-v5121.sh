#!/bin/bash
# v5.12.1 更新脚本 —— 恢复 SSL 直接监听 443（v5.12 丢失了此逻辑导致 HTTPS 全断）
# 只更新 server.js 一个文件；scheduler.js / admin.html 保持 v5.12 不动
set -u
cd /opt/reading-checkin || { echo "❌ 目录不存在"; exit 1; }

echo "===== v5.12.1 更新开始 ====="
echo "[0/6] 检查证书..."
mkdir -p /opt/reading-checkin/ssl
SSL_KEY_PATH=$(ls /opt/reading-checkin/ssl/*.key 2>/dev/null | head -1)
SSL_CRT_PATH=$(ls /opt/reading-checkin/ssl/*.crt 2>/dev/null | head -1)
if [ -z "$SSL_CRT_PATH" ]; then SSL_CRT_PATH=$(ls /opt/reading-checkin/ssl/*.pem 2>/dev/null | head -1); fi
if [ -z "$SSL_KEY_PATH" ] || [ -z "$SSL_CRT_PATH" ]; then
  echo "❌ 证书未找到！/opt/reading-checkin/ssl/ 下需要 .key + .crt/.pem"
  ls -la /opt/reading-checkin/ssl/ 2>/dev/null
  exit 1
fi
echo "  证书: $SSL_KEY_PATH + $SSL_CRT_PATH"

echo "[1/6] 下载 v5.12.1 server.js（CDN多通道）..."
download() {
  local out="$1" min="$2"; shift 2
  for url in "$@"; do
    echo "  尝试: $url"
    if curl -sL --max-time 60 "$url" -o "$out" 2>/dev/null; then
      local sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
      if [ "$sz" -ge "$min" ] && ! head -c 200 "$out" | grep -qi "<!DOCTYPE\|<html"; then
        echo "  ✅ 下载成功 ($sz bytes)"
        return 0
      fi
      echo "  ⚠️ 文件异常 ($sz bytes)，换通道"
    fi
  done
  return 1
}
if ! download /tmp/server_v5121.js 70000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5121/server.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5121/server.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5121/server.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5121/server.js"; then
  echo "❌ 下载失败"; exit 1
fi

echo "[2/6] 语法检查（CRLF→LF + .cjs后缀）..."
tr -d '\r' < /tmp/server_v5121.js > /tmp/_chk_v5121.cjs
if node --check /tmp/_chk_v5121.cjs; then echo "  ✅ 语法OK"; else echo "❌ 语法错误"; exit 1; fi

echo "[3/6] 确认版本号..."
if grep -q "v5.12.1" /tmp/server_v5121.js; then echo "  ✅ v5.12.1"; else echo "❌ 版本号不对"; exit 1; fi
if ! grep -q "SSL_KEY_PATH" /tmp/server_v5121.js; then echo "❌ 缺少SSL逻辑"; exit 1; fi

echo "[4/6] 备份并替换..."
cp server.js "server.js.bak-v5121-$(date +%s)" && mv /tmp/server_v5121.js server.js
echo "  ✅ 已替换"

echo "[5/6] 重启（只杀 reading-checkin，不碰 health-check）..."
for P in 3002 443; do
  PID=$(ss -tlnp 2>/dev/null | grep ":$P " | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -n "$PID" ]; then echo "  kill :$P (PID $PID)"; kill -9 "$PID" 2>/dev/null; fi
done
sleep 2
STORAGE_MODE=local PORT=3002 \
  SSL_KEY_PATH="$SSL_KEY_PATH" SSL_CRT_PATH="$SSL_CRT_PATH" \
  BASE_DOMAIN=zhengpintang.cn \
  nohup node server.js >> /var/log/reading-checkin.log 2>&1 &
echo "  启动中... PID=$!"

echo "[6/6] 验证..."
sleep 5
echo "--- 端口监听 ---"
ss -tln | grep -E ':443 |:80 |:3002 ' && echo "  ✅ 443/80已监听" || echo "  ❌ 443未监听！查日志: tail -30 /var/log/reading-checkin.log"
echo "--- 本机版本 ---"
curl -s --max-time 5 http://localhost:3002/version && echo ""
echo "--- 外网版本(重试3次) ---"
for i in 1 2 3; do
  R=$(curl -s --max-time 15 https://zhengpintang.cn/version)
  if [ -n "$R" ]; then echo "  ✅ $R"; break; fi
  echo "  第${i}次未通，重试..."; sleep 2
done
echo ""
echo "===== 完成 ====="
echo "浏览器打开: https://zhengpintang.cn/admin"
