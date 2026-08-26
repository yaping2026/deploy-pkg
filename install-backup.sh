#!/bin/bash
# 安装 GitHub 每日备份（私有仓库，零费用）
# 用法:
#   export GITHUB_TOKEN=ghp_你的token
#   curl -sL https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/install-backup.sh | bash
set -e
CDN="https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN2="https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
DIR="/opt/reading-checkin"

echo "=== [1/5] 前置检查 ==="
if ! command -v node >/dev/null 2>&1; then
  echo "  ❌ 未找到 node，退出"; exit 1
fi
NODE_BIN=$(command -v node)
echo "  ✅ node: $NODE_BIN"

if [ -z "$GITHUB_TOKEN" ]; then
  echo "  ❌ 未设置 GITHUB_TOKEN 环境变量"
  echo "     正确用法: export GITHUB_TOKEN=ghp_xxx 先执行，再跑本脚本"
  exit 1
fi
echo "  ✅ GITHUB_TOKEN 已提供"

if [ ! -f "$DIR/data/reading-checkin-data.json" ]; then
  echo "  ❌ 未找到数据文件 $DIR/data/reading-checkin-data.json"; exit 1
fi
echo "  ✅ 数据文件存在"

echo "=== [2/5] 写入 token（仅root可读） ==="
echo "$GITHUB_TOKEN" > "$DIR/.backup-token"
chmod 600 "$DIR/.backup-token"
echo "  ✅ 已写入 $DIR/.backup-token (600)"

echo "=== [3/5] 下载备份脚本 ==="
for c in "$CDN" "$CDN2"; do
  curl -sL --connect-timeout 15 --max-time 60 "$c/github-backup.js" -o "$DIR/github-backup.js" 2>/dev/null || true
  if [ -s "$DIR/github-backup.js" ]; then
    echo "  ✅ 已下载 github-backup.js 来源: $c"; break
  fi
done
if [ ! -s "$DIR/github-backup.js" ]; then
  echo "  ❌ 下载失败"; exit 1
fi

echo "=== [4/5] 配置 crontab（每天 03:30 自动备份） ==="
(crontab -l 2>/dev/null | grep -v "github-backup.js"; \
 echo "30 3 * * * $NODE_BIN $DIR/github-backup.js >> /var/log/reading-checkin-backup.log 2>&1") | crontab -
echo "  ✅ 已配置: 30 3 * * * $NODE_BIN $DIR/github-backup.js"
echo "  日志位置: /var/log/reading-checkin-backup.log"

echo "=== [5/5] 立即执行首次备份（验证） ==="
"$NODE_BIN" "$DIR/github-backup.js"
RC=$?

echo ""
echo "=========================================="
if [ $RC -eq 0 ]; then
  echo "🎉 每日备份安装完成！"
  echo "  · 每天 03:30 自动备份到 GitHub 私有仓库 backup 分支"
  echo "  · 查看备份: https://github.com/yaping2026/reading-checkin/tree/backup"
  echo "  · 手动备份: node $DIR/github-backup.js"
  echo "  · 查看日志: tail -20 /var/log/reading-checkin-backup.log"
else
  echo "⚠️ 首次备份失败（返回码 $RC），请把上面的错误信息反馈给助手排查"
fi
echo "=========================================="
exit $RC
