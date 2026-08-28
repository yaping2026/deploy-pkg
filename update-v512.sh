#!/bin/bash
# ================================================================
#  v5.12 季度换组功能更新脚本（腾讯云服务器终端执行）
#  只更新3个代码文件，完全不动数据；失败自动回滚
#
#  通道: jsDelivr CDN 三节点 + GitHub raw 兜底（国内服务器更稳）
#  执行: curl -sL https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/update-v512.sh | bash
# ================================================================
set -u
echo "===== v5.12 换组功能更新 $(date '+%F %T') ====="
cd /opt/reading-checkin || { echo "❌ /opt/reading-checkin 不存在"; exit 1; }

BASE_PATH="v512"   # deploy-pkg 仓库里的子目录
TS=$(date +%s)

# ====== 多通道下载函数（按优先级尝试） ======
# 用法: download <远程相对路径> <本地保存路径> [期望最小字节]
download() {
  local rel="$1" dst="$2" min_size="${3:-5000}"
  local tried=0
  # 1. jsDelivr Gcore（香港节点，国内最快）
  if ! tried=1; then :; fi
  for base in \
    "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main" \
    "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main" \
    "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main" \
    "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main"; do
    local url="$base/$rel"
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$dst" "$url" 2>/dev/null; then
      local sz
      sz=$(wc -c < "$dst" 2>/dev/null || echo 0)
      if [ "$sz" -ge "$min_size" ]; then
        echo "  ✅ $(basename $dst) 来自 $(echo $base | cut -d/ -f3)  ($sz 字节)"
        return 0
      else
        echo "  ⚠️ $(basename $dst) 来自 $(echo $base | cut -d/ -f3) 仅 $sz 字节，跳过"
        rm -f "$dst"
      fi
    fi
  done
  echo "  ❌ $(basename $dst) 所有通道都失败"
  return 1
}

echo "--- [1/5] 备份现有文件 ---"
for f in server.js scheduler.js public/admin.html; do
  [ -f "$f" ] && cp "$f" "$f.bak-$TS" && echo "  已备份 $f → $f.bak-$TS"
done

echo "--- [2/5] 下载新代码（jsDelivr CDN 三节点 + raw 兜底）---"
FAIL=0
download "$BASE_PATH/server.js"      "server.js.new"          10000  || FAIL=1
download "$BASE_PATH/scheduler.js"   "scheduler.js.new"       5000   || FAIL=1
download "$BASE_PATH/admin.html"     "public/admin.html.new"  30000  || FAIL=1
if [ "$FAIL" = "1" ]; then
  echo "❌ 有文件下载失败，保持原样不动，稍后重试"
  rm -f server.js.new scheduler.js.new public/admin.html.new
  exit 1
fi

echo "--- [3/5] 语法检查（防止坏文件上线）---"
# Node 20 对未知扩展名（.new）抛 ERR_UNKNOWN_FILE_EXTENSION，所以改名 .cjs 再检查
# 同时做 CRLF → LF 规范化（deploy-pkg 上传时偶尔会引入 CRLF）
ERR=0
tr -d '\r' < server.js.new > /tmp/_check_server.cjs
node --check /tmp/_check_server.cjs 2> /tmp/check_server.err
if [ $? -eq 0 ]; then
  echo "  ✅ server.js 语法OK"
else
  echo "  ❌ server.js 语法错误："
  cat /tmp/check_server.err | head -8
  ERR=1
fi
tr -d '\r' < scheduler.js.new > /tmp/_check_sched.cjs
node --check /tmp/_check_sched.cjs 2> /tmp/check_sched.err
if [ $? -eq 0 ]; then
  echo "  ✅ scheduler.js 语法OK"
else
  echo "  ❌ scheduler.js 语法错误："
  cat /tmp/check_sched.err | head -8
  ERR=1
fi
if [ "$ERR" = "1" ]; then
  echo ""
  echo "  🔍 诊断信息："
  echo "    node版本:   $(node -v 2>&1)"
  echo "    server.js.new 字节: $(wc -c < server.js.new)"
  echo "    server.js.new 首行: $(head -1 server.js.new | cut -c1-60)"
  echo "    server.js.new 末行: $(tail -1 server.js.new | cut -c1-60)"
  echo "    CRLF/LF 诊断: $(grep -c $'\r' server.js.new 2>/dev/null) CR字节"
  echo ""
  echo "  ⚠️ 中止。先看上面错误原因修复后再重试"
  rm -f server.js.new scheduler.js.new public/admin.html.new /tmp/_check_server.cjs /tmp/_check_sched.cjs
  exit 1
fi
rm -f /tmp/_check_server.cjs /tmp/_check_sched.cjs

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
echo -n "  本机版本: "
curl -sk https://127.0.0.1/version --max-time 8 || echo "（本机请求失败）"
echo ""
echo -n "  外网版本: "
curl -s https://zhengpintang.cn/version --max-time 10 || echo "（外网请求失败）"
echo ""
echo -n "  换组接口存在性（应非404）: "
curl -sk -o /dev/null -w "%{http_code}" -X POST https://127.0.0.1/api/regroup --max-time 8
echo ""
echo ""
echo "===== 完成 ====="
echo "✅ 应显示版本 2026-08-28-v5.12"
echo "📌 打开 https://zhengpintang.cn/admin.html → 应看到新增的「季度换组」标签"
echo "📌 如有异常回滚："
echo "   cp server.js.bak-$TS server.js"
echo "   cp scheduler.js.bak-$TS scheduler.js"
echo "   cp public/admin.html.bak-$TS public/admin.html"
echo "   再重启即可"
