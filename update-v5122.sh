#!/bin/bash
# v5.12.2 更新脚本 —— 修复「季度换组」一键随机抽签按钮无响应
# 原因：admin.html 里 loadRegroup() 跟 loadGroups() 并行执行，前者读不到成员表就空跑；
#        且 randomDraw 在成员为空时静默退出，用户感觉"没反应"
# 修复：loadRegroup 改为 loadGroups().then(loadRegroup)；switchTab 进入换组页时强制刷新；空列表给 alert 提示
# 只更新 public/admin.html 一个文件；server.js 保持 v5.12.1 不动
set -u
cd /opt/reading-checkin || { echo "❌ 目录不存在"; exit 1; }

echo "===== v5.12.2 更新开始 ====="

echo "[1/4] 下载新版 admin.html（CDN多通道）..."
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
if ! download /tmp/admin_v5122.html 50000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v5122/admin.html"; then
  echo "❌ 下载失败"; exit 1
fi

echo "[2/4] 关键修复点校验..."
tr -d '\r' < /tmp/admin_v5122.html > /tmp/_chk_v5122.html
if grep -q "loadGroups().then(loadRegroup)" /tmp/_chk_v5122.html; then echo "  ✅ 修复1: loadRegroup 顺序等待"; else echo "❌ 缺少修复1"; exit 1; fi
if grep -q "群组列表为空" /tmp/_chk_v5122.html; then echo "  ✅ 修复2: 空列表提示"; else echo "❌ 缺少修复2"; exit 1; fi
if grep -q "if (idx === 3) loadRegroup();" /tmp/_chk_v5122.html; then echo "  ✅ 修复3: 切到换组页强制刷新"; else echo "❌ 缺少修复3"; exit 1; fi

echo "[3/4] 备份并替换..."
mkdir -p public
cp public/admin.html "public/admin.html.bak-v5121-$(date +%s)" 2>/dev/null
cp /tmp/admin_v5122.html public/admin.html
echo "  ✅ 已替换"

echo "[4/4] 验证（静态文件无需重启）..."
sleep 2
SIZE=$(stat -c%s public/admin.html)
echo "  本地文件: $SIZE bytes"
EXT_CHECK=$(curl -s --max-time 15 "https://zhengpintang.cn/admin" | grep -c "loadGroups().then(loadRegroup)")
if [ "$EXT_CHECK" -gt 0 ]; then echo "  ✅ 外网已生效（包含修复1）"; else echo "  ⚠️ 外网还没刷出来，浏览器强刷 Ctrl+F5"; fi

echo ""
echo "===== 完成 ====="
echo "刷新后台页面（Ctrl+F5）即可使用「一键随机抽签」"