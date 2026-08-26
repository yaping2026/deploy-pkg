#!/bin/bash
# ============================================================
# 状态诊断脚本：查看 content/ 目录实际状态
# ============================================================

CONTENT_DIR=/opt/reading-checkin/content
LOG=/tmp/check_state.log
: > $LOG

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo "========================================"  | tee -a $LOG
echo " content/ 状态诊断"  | tee -a $LOG
echo "========================================"  | tee -a $LOG

echo -e "${YELLOW}[1] 当前目录所有文件${NC}" | tee -a $LOG
ls -la "$CONTENT_DIR" 2>/dev/null | head -40 | tee -a $LOG

echo "" | tee -a $LOG
echo -e "${YELLOW}[2] 文件总数和总大小${NC}" | tee -a $LOG
echo -n "  总数: " | tee -a $LOG
ls "$CONTENT_DIR" 2>/dev/null | wc -l | tee -a $LOG
echo -n "  总大小: " | tee -a $LOG
du -sh "$CONTENT_DIR" 2>/dev/null | tee -a $LOG

echo "" | tee -a $LOG
echo -e "${YELLOW}[3] 按日期统计${NC}" | tee -a $LOG
ls "$CONTENT_DIR" 2>/dev/null | sort | awk '{
  date=substr($1,1,8);
  count[date]++;
  total[date]+=1;
}
END {
  for (d in count) printf "  %s: %d个文件\n", d, count[d];
}' | sort | tee -a $LOG

echo "" | tee -a $LOG
echo -e "${YELLOW}[4] 今日（$(date '+%Y%m%d')）的文件是否齐全？${NC}" | tee -a $LOG
TODAY=$(date '+%Y%m%d')
for ext in "A.pdf" "B.jpg"; do
  F="${TODAY}${ext}"
  if [ -f "$CONTENT_DIR/$F" ]; then
    SIZE=$(stat -c%s "$CONTENT_DIR/$F" 2>/dev/null || echo 0)
    echo -e "  ${GREEN}✅ $F (${SIZE}B)${NC}" | tee -a $LOG
  else
    echo -e "  ${RED}❌ $F 缺失${NC}" | tee -a $LOG
  fi
done

echo "" | tee -a $LOG
echo -e "${YELLOW}[5] 网络测试：curl能不能连 GitHub raw${NC}" | tee -a $LOG
START=$(date +%s)
timeout 30 curl -sLI "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/data2.json.gz" 2>&1 | head -3 | tee -a $LOG
END=$(date +%s)
echo "  耗时: $((END-START))秒" | tee -a $LOG

echo "" | tee -a $LOG
echo -e "${YELLOW}[6] 网络测试：curl能不能连 jsDelivr${NC}" | tee -a $LOG
START=$(date +%s)
timeout 30 curl -sLI "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/data2.json.gz" 2>&1 | head -3 | tee -a $LOG
END=$(date +%s)
echo "  耗时: $((END-START))秒" | tee -a $LOG

echo "" | tee -a $LOG
echo -e "${YELLOW}[7] 当前服务在监听${NC}" | tee -a $LOG
ss -tlnp 2>/dev/null | grep -E ":443|:80" | tee -a $LOG

echo "" | tee -a $LOG
echo -e "${YELLOW}[8] 服务进程${NC}" | tee -a $LOG
ps aux | grep "node server" | grep -v grep | tee -a $LOG

echo "" | tee -a $LOG
echo "========================================"  | tee -a $LOG
echo " 完整日志: $LOG"  | tee -a $LOG
echo "========================================"  | tee -a $LOG
