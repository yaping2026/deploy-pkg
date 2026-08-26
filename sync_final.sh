#!/bin/bash
# 最终数据同步：从CDN拉取GitHub最新数据快照，合并到本地（只追加本地缺少的记录，不覆盖本地）
set -e
CDN="https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN2="https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main"

echo "=== [1/4] 下载数据快照和合并脚本 ==="
cd /tmp
for c in "$CDN" "$CDN2"; do
  curl -sL --connect-timeout 15 --max-time 90 "$c/data-final.json.gz" -o data-final.json.gz 2>/dev/null || true
  SIZE=$(stat -c%s data-final.json.gz 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 50000 ]; then
    echo "  ✅ 数据包下载成功 ($SIZE 字节) 来源: $c"
    break
  fi
done
SIZE=$(stat -c%s data-final.json.gz 2>/dev/null || echo 0)
if [ "$SIZE" -lt 50000 ]; then
  echo "  ❌ 数据包下载失败，退出"; exit 1
fi

curl -sL --connect-timeout 15 --max-time 60 "$CDN/sync_final.js" -o sync_final.js
if [ ! -s sync_final.js ]; then
  curl -sL --connect-timeout 15 --max-time 60 "$CDN2/sync_final.js" -o sync_final.js
fi
echo "  ✅ 合并脚本就绪"

echo "=== [2/4] 解压数据 ==="
gunzip -f data-final.json.gz
echo "  ✅ 解压后 $(stat -c%s data-final.json) 字节"

echo "=== [3/4] 执行合并 ==="
node sync_final.js

echo "=== [4/4] 验证服务 ==="
sleep 2
if ss -tlnp 2>/dev/null | grep -q ':443'; then
  echo "  ✅ 443端口正常监听，服务无需重启（数据文件每次请求都重新读）"
else
  echo "  ⚠️ 443未监听，重启服务..."
  pkill -9 -f "node server.js" 2>/dev/null || true
  sleep 2
  bash /opt/reading-checkin/start.sh
  sleep 3
  ss -tlnp | grep ':443' && echo "  ✅ 已重启" || echo "  ❌ 启动失败，查看日志: tail -20 /var/log/reading-checkin.log"
fi

echo ""
echo "=========================================="
echo "🎉 最终数据同步完成！"
echo "现在可以去 Railway 控制台删除旧服务了"
echo "=========================================="