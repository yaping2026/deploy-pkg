#!/bin/bash
# 最终数据同步 v2：含肖艳平16:05打卡(id=5029)+龙玲8-23补卡(id=5028)，并直接下载新录音到本地
set -e
CDN="https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN2="https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main"

echo "=== [1/5] 下载数据快照和合并脚本 ==="
cd /tmp
for c in "$CDN" "$CDN2"; do
  curl -sL --connect-timeout 15 --max-time 90 "$c/data-final2.json.gz" -o data-final2.json.gz 2>/dev/null || true
  SIZE=$(stat -c%s data-final2.json.gz 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 50000 ]; then
    echo "  ✅ 数据包下载成功 ($SIZE 字节) 来源: $c"
    break
  fi
done
SIZE=$(stat -c%s data-final2.json.gz 2>/dev/null || echo 0)
if [ "$SIZE" -lt 50000 ]; then
  echo "  ❌ 数据包下载失败，退出"; exit 1
fi

curl -sL --connect-timeout 15 --max-time 60 "$CDN/sync_final.js" -o sync_final.js
if [ ! -s sync_final.js ]; then
  curl -sL --connect-timeout 15 --max-time 60 "$CDN2/sync_final.js" -o sync_final.js
fi
echo "  ✅ 合并脚本就绪"

echo "=== [2/5] 解压数据 ==="
gunzip -f data-final2.json.gz
cp data-final2.json data-final.json
echo "  ✅ 解压后 $(stat -c%s data-final.json) 字节"

echo "=== [3/5] 下载新录音（肖艳平8-26打卡，1MB） ==="
AUDIO_DIR="/opt/reading-checkin/content"
AUDIO_FILE="audio_1787731515059_qrablu.m4a"
if [ -s "$AUDIO_DIR/$AUDIO_FILE" ]; then
  echo "  ✅ 录音已存在，跳过"
else
  for c in "$CDN/audio" "$CDN2/audio"; do
    curl -sL --connect-timeout 15 --max-time 120 "$c/$AUDIO_FILE" -o "$AUDIO_DIR/$AUDIO_FILE" 2>/dev/null || true
    ASIZE=$(stat -c%s "$AUDIO_DIR/$AUDIO_FILE" 2>/dev/null || echo 0)
    if [ "$ASIZE" -gt 500000 ]; then
      echo "  ✅ 录音下载成功 ($ASIZE 字节) 来源: $c"
      break
    fi
  done
  ASIZE=$(stat -c%s "$AUDIO_DIR/$AUDIO_FILE" 2>/dev/null || echo 0)
  if [ "$ASIZE" -lt 500000 ]; then
    rm -f "$AUDIO_DIR/$AUDIO_FILE"
    echo "  ⚠️ 录音下载失败（不影响打卡数据，抽检时CDN懒加载仍可取）"
  fi
fi

echo "=== [4/5] 执行合并 ==="
node sync_final.js

echo "=== [5/5] 验证服务 ==="
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
echo "🎉 数据同步v2完成！（含5028补卡+5029新打卡）"
echo "请尽快删除 Railway 旧服务，防止再有人用旧链接打卡"
echo "=========================================="
