#!/bin/bash
# fix-admin-v513.sh - 单独修补 admin.html 到正确的 public/ 路径
# 适用场景：update-v513v2.sh 把 admin.html mv 错了路径（应该是 public/admin.html，脚本之前写成了 admin.html）
# 用法：curl -sL https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/fix-admin-v513.sh | bash

set -e
LOG=/tmp/fix-admin-v513.log
TS=$(date +%s)
echo "[$(date '+%F %T')] === fix-admin-v513 开始 ===" | tee "$LOG"

# 1) 下载 v5.13 admin.html
cd /tmp
curl -sL --max-time 30 -o admin-v513.html \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  || curl -sL --max-time 30 -o admin-v513.html \
     "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  || curl -sL --max-time 30 -o admin-v513.html \
     "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/admin.html"

if [ ! -f admin-v513.html ] || [ $(stat -c%s admin-v513.html) -lt 50000 ]; then
  echo "❌ 下载失败或文件过小" | tee -a "$LOG"
  exit 1
fi
echo "[$(date '+%F %T')] ✅ admin-v513.html 大小: $(stat -c%s admin-v513.html)字节" | tee -a "$LOG"

# 2) 校验含关键特征
if ! grep -q "stopMember" admin-v513.html || ! grep -q "停止打卡" admin-v513.html; then
  echo "❌ 下载的文件缺停止打卡特征，终止" | tee -a "$LOG"
  exit 2
fi
echo "[$(date '+%F %T')] ✅ 校验含停止打卡特征" | tee -a "$LOG"

# 3) LF 转换（防 CRLF 渲染异常）
tr -d '\r' < admin-v513.html > admin-v513-lf.html

# 4) 备份两份路径下的旧文件
SRC=/opt/reading-checkin/public/admin.html
BAK=/opt/reading-checkin/public/admin.html.bak-$TS
if [ -f "$SRC" ]; then
  cp "$SRC" "$BAK"
  echo "[$(date '+%F %T')] 📦 备份: $BAK" | tee -a "$LOG"
fi

# 5) 覆盖 v5.13 admin.html
cp admin-v513-lf.html "$SRC"
echo "[$(date '+%F %T')] ✅ 已覆盖: $SRC ($(stat -c%s $SRC)字节)" | tee -a "$LOG"

# 6) 顺便也覆盖 backup 路径（不影响，公开是 public 优先级高）
SRC2=/opt/reading-checkin/admin.html
if [ -f "$SRC2" ]; then
  cp admin-v513-lf.html "$SRC2"
  echo "[$(date '+%F %T')] ✅ 同步覆盖: $SRC2" | tee -a "$LOG"
fi

# 7) 验证
NEW_MD5=$(md5sum "$SRC" | cut -d' ' -f1)
echo "[$(date '+%F %T')] === 当前 public/admin.md5: $NEW_MD5 ===" | tee -a "$LOG"

# 8) 通知 - 强制刷新缓存
NEW_SIZE=$(stat -c%s "$SRC")
echo "[$(date '+%F %T')] 🎉 修复完成！浏览器请按 Ctrl+Shift+R 强制刷新" | tee -a "$LOG"
echo ""
echo "================================================"
echo "请到管理员后台，按 Ctrl+Shift+R 强制刷新页面"
echo "应当可以看到三组成员行："
echo "  · 魏晓晴名字后有橙色「停止打卡」按钮（因为她 leftDate 已设，绿色会变「恢复打卡」）"
echo "  · 每个成员行：原删除按钮左边新增一个橙色/绿色按钮"
echo "================================================"
