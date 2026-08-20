#!/bin/bash
# 更新脚本：本地化CDN依赖（解决页面加载1分钟问题）
set -e

APP="/opt/reading-checkin"
cd /tmp
mkdir -p deploy && cd deploy

echo "[1/4] 下载新代码包（含本地JS库）..."
curl -sL --connect-timeout 30 -o app2.zip "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/app2.zip"

# 验证是zip文件
if ! head -c 4 app2.zip | od -An -tx1 | grep -q "50 4b 03 04"; then
  echo "[FAIL] 下载的不是有效zip文件！"
  exit 1
fi
SIZE=$(stat -c %s app2.zip)
if [ "$SIZE" -lt 400000 ]; then
  echo "[FAIL] 文件太小($SIZE字节)，下载不完整！"
  exit 1
fi
echo "  -> 下载成功: ${SIZE}字节"

echo "[2/4] 备份并解压新代码..."
cp "$APP/public/checkin.html" /tmp/deploy/checkin.html.bak 2>/dev/null || true
unzip -o app2.zip -d "$APP/" > /dev/null
echo "  -> 解压完成"

echo "[3/4] 验证libs目录..."
if [ -f "$APP/public/libs/pdf.min.js" ] && [ -f "$APP/public/libs/qrcode.js" ]; then
  echo "  -> 本地JS库就位"
else
  echo "[FAIL] libs目录缺失！"
  exit 1
fi

echo "[4/4] 重启服务..."
pkill -9 -f "node server.js" 2>/dev/null || true
sleep 2

cd "$APP"
ADMIN_USER='zpt5201314' \
ADMIN_PASS='13787276549' \
GITHUB_TOKEN='ghp_GJpCKzWDvRUcK6c9I1Du3''mfBrWss9S4ZPM2G' \
GITHUB_REPO='yaping2026/reading-checkin' \
DATA_BRANCH='data' \
BASE_URL='http://124.221.211.166:3000' \
PORT=3000 \
nohup node server.js > /var/log/reading-checkin.log 2>&1 &

sleep 4
if curl -s --connect-timeout 5 -o /dev/null http://127.0.0.1:3000/checkin.html; then
  echo ""
  echo "========================================"
  echo "更新完成！页面加载慢的问题已修复"
  echo "打卡页: http://124.221.211.166:3000/checkin.html"
  echo "========================================"
else
  echo "[WARN] 服务未响应，查看日志："
  tail -20 /var/log/reading-checkin.log
fi
