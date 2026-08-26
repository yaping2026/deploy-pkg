#!/bin/bash
# 备份频率升级：每天1次 → 每6小时1次（00:30 / 06:30 / 12:30 / 18:30）
# 用法: curl -sL https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/install-backup2.sh | bash
set -e
DIR="/opt/reading-checkin"
NODE_BIN=$(command -v node)

echo "=== [1/3] 检查现有备份脚本 ==="
if [ ! -f "$DIR/github-backup.js" ]; then
  echo "  ❌ 未找到 $DIR/github-backup.js，请先运行 install-backup.sh 安装基础版"
  exit 1
fi
echo "  ✅ github-backup.js 存在"

echo "=== [2/3] 升级 crontab（每6小时备份一次） ==="
(crontab -l 2>/dev/null | grep -v "github-backup.js"; \
 echo "30 */6 * * * $NODE_BIN $DIR/github-backup.js >> /var/log/reading-checkin-backup.log 2>&1") | crontab -
echo "  ✅ 已配置: 30 */6 * * *  (每天 00:30 / 06:30 / 12:30 / 18:30)"
echo "  📋 当前定时任务:"
crontab -l | grep github-backup

echo "=== [3/3] 立即执行一次备份（把当前最新数据推上云） ==="
"$NODE_BIN" "$DIR/github-backup.js"
RC=$?

echo ""
echo "=========================================="
if [ $RC -eq 0 ]; then
  echo "🎉 备份升级完成！"
  echo "  · 现在起每 6 小时自动备份（最多丢 6 小时数据）"
  echo "  · 立即备份完成 = 当前所有数据已安全上云"
  echo "  · 手动备份: node $DIR/github-backup.js"
  echo "  · 查看备份: https://github.com/yaping2026/reading-checkin/tree/backup/backup"
  echo "  · 查看日志: tail -20 /var/log/reading-checkin-backup.log"
else
  echo "⚠️ 本次备份失败（返回码 $RC），请把错误信息反馈给助手排查"
fi
echo "=========================================="
exit $RC
