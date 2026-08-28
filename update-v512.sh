#!/bin/bash
# ================================================================
#  v5.12 季度换组功能更新脚本（在腾讯云服务器终端执行）
#  只更新3个代码文件，完全不动数据；失败自动回滚
#  执行方式: curl -sL https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/update-v512.sh | bash
# ================================================================
set -u
echo "===== v5.12 换组功能更新 $(date '+%F %T') ====="
cd /opt/reading-checkin || { echo "❌ /opt/reading-checkin 不存在"; exit 1; }

BASE="https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v512"
TS=$(date +%s)

echo "--- [1/5] 备份现有文件 ---"
for f in server.js scheduler.js public/admin.html; do
  [ -f "$f" ] && cp "$f" "$f.bak-$TS" && echo "  已备份 $f → $f.bak-$TS"
done

echo "--- [2/5] 下载新代码（GitHub raw，不缓存）---"
FAIL=0
for f in server.js scheduler.js; do
  if curl -fsSL --connect-timeout 20 --max-time 120 -o "$f.new" "$BASE/$f"; then
    echo "  ✅ $f 下载成功 ($(wc -c < $f.new) 字节)"
  else
    echo "  ❌ $f 下载失败"; FAIL=1
  fi
done
if curl -fsSL --connect-timeout 20 --max-time 120 -o "public/admin.html.new" "$BASE/admin.html"; then
  echo "  ✅ admin.html 下载成功 ($(wc -c < public/admin.html.new) 字节)"
else
  echo "  ❌ admin.html 下载失败"; FAIL=1
fi
if [ "$FAIL" = "1" ]; then
  echo "❌ 有文件下载失败，保持原样不动，稍后重试"
  rm -f server.js.new scheduler.js.new public/admin.html.new
  exit 1
fi

echo "--- [3/5] 语法检查（防止坏文件上线）---"
node --check server.js.new && echo "  ✅ server.js 语法OK" || { echo "  ❌ server.js 语法错误，中止"; rm -f server.js.new scheduler.js.new public/admin.html.new; exit 1; }
node --check scheduler.js.new && echo "  ✅ scheduler.js 语法OK" || { echo "  ❌ scheduler.js 语法错误，中止"; rm -f server.js.new scheduler.js.new public/admin.html.new; exit 1; }

echo "--- [4/5] 替换文件并重启 ---"
mv server.js.new server.js
mv scheduler.js.new scheduler.js
mv public/admin.html.new public/admin.html
pkill -9 -f "node.*server[.]js" 2>/dev/null; sleep 2
if [ -f start.sh ]; then
  bash start.sh
else
  echo "  ⚠️ start.sh不存在，用内置参数启动"
  STORAGE_MODE=local BASE_URL=https://zhengpintang.cn BASE_DOMAIN=zhengpintang.cn \
  ADMIN_USER='zpt5201314' ADMIN_PASS='13787276549' \
  SSL_KEY_PATH=/opt/reading-checkin/ssl/zhengpintang.cn.key \
  SSL_CRT_PATH=/opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt \
  PORT=3000 nohup node server.js >> /var/log/reading-checkin.log 2>&1 &
  echo "  已启动 PID: $!"
fi
sleep 5

echo "--- [5/5] 健康验证 ---"
ss -tlnp 2>/dev/null | grep -E ":443 " || echo "  ⚠️ 443未监听！请执行 tail -30 /var/log/reading-checkin.log 排查"
echo -n "  版本号: "
curl -sk https://127.0.0.1/version --max-time 8 || echo "（本机请求失败）"
echo ""
echo -n "  外网版本: "
curl -s https://zhengpintang.cn/version --max-time 10 || echo "（外网请求失败）"
echo ""
echo -n "  换组接口存在性（应返回401或缺少moves，而不是404）: "
curl -sk -o /dev/null -w "%{http_code}" -X POST https://127.0.0.1/api/regroup --max-time 8
echo ""
echo ""
echo "===== 完成 ====="
echo "✅ 应显示版本 2026-08-28-v5.12"
echo "📌 打开 https://zhengpintang.cn/admin.html → 应看到新增的「季度换组」标签"
echo "📌 如有异常回滚：cp server.js.bak-$TS server.js && cp scheduler.js.bak-$TS scheduler.js && cp public/admin.html.bak-$TS public/admin.html 再重启"
