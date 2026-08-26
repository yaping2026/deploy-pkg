#!/bin/bash
# ============================================================
# 纯本地模式切换脚本
# 原理：db.js 所有 GitHub 读写都以 if (GITHUB_TOKEN) 守卫，
#       进程环境里没有 token => 自动全部走本地文件（纯本地模式）
# 本脚本：清干净 token 来源 -> 无 token 重启 -> 验证
# 可重复执行（幂等），出错自动中止并提示
# ============================================================
cd /opt/reading-checkin || { echo "❌ 目录不存在"; exit 1; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
TS=$(date +%Y%m%d%H%M%S)
TODAY=$(date +%F)

echo "=============================================="
echo " 纯本地模式切换（目标：进程不带GITHUB_TOKEN）"
echo "=============================================="

echo ""
echo "=== [1/7] 当前状态 ==="
PID=$(pgrep -f "node.*server\.js" | head -1)
if [ -n "$PID" ]; then
  TOKCNT=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | grep -c '^GITHUB_TOKEN=')
  if [ "$TOKCNT" -gt 0 ]; then
    echo "当前进程 PID=$PID 环境含GITHUB_TOKEN（GitHub主从模式，将切换为纯本地）"
  else
    echo "当前进程 PID=$PID 已无token（可能已切换过，继续做加固也无妨）"
  fi
else
  echo "（当前无server进程在运行）"
fi

echo ""
echo "=== [2/7] 备份（出问题随时可回滚） ==="
BKDIR="/opt/reading-checkin/backup-local-switch-$TS"
mkdir -p "$BKDIR"
cp start.sh "$BKDIR/" 2>/dev/null && echo "  已备份 start.sh"
cp db.js "$BKDIR/" 2>/dev/null && echo "  已备份 db.js"
cp data/reading-checkin-data.json "$BKDIR/" 2>/dev/null && echo "  已备份 数据文件"
BEFORE=$(node -e "const d=require('/opt/reading-checkin/data/reading-checkin-data.json');console.log(d.checkins.filter(c=>c.date==='$TODAY').length)" 2>/dev/null || echo "?")
echo "  切换前今日($TODAY)打卡数: $BEFORE"
echo "  备份目录: $BKDIR"

echo ""
echo "=== [3/7] 清理所有 token 来源 ==="
# 3a. 清当前shell（本脚本后续启动的进程就干净了）
unset GITHUB_TOKEN 2>/dev/null
export -n GITHUB_TOKEN 2>/dev/null
echo "  ✅ 当前shell的token已清除"

# 3b. start.sh 里如有 token 定义行，删掉（正常模板没有，防御性清理）
sed -i '/^[[:space:]]*export[[:space:]]\+GITHUB_TOKEN=/d' start.sh 2>/dev/null
sed -i '/^[[:space:]]*GITHUB_TOKEN=/d' start.sh 2>/dev/null

# 3c. start.sh 开头加 unset 防御（幂等：已有则跳过）
if ! grep -q "unset GITHUB_TOKEN" start.sh 2>/dev/null; then
  sed -i '1a unset GITHUB_TOKEN 2>/dev/null || true' start.sh
  echo "  ✅ start.sh 已加 unset 防御（以后无论谁带着token执行，进程都不会继承）"
else
  echo "  start.sh 已有 unset 防御，跳过"
fi

# 3d. start.sh 的 pkill pattern 加宽（防双进程复发，幂等）
sed -i 's/pkill -9 -f "node server\.js"/pkill -9 -f "node.*server[.]js"/g' start.sh 2>/dev/null

# 3e. 清 bashrc/profile 里的 token（防以后SSH登录再污染）
for RC in ~/.bashrc ~/.bash_profile ~/.profile; do
  if [ -f "$RC" ] && grep -q "GITHUB_TOKEN=" "$RC"; then
    cp "$RC" "$RC.bak-$TS"
    sed -i '/^[[:space:]]*\(export[[:space:]]\+\)\?GITHUB_TOKEN=/d' "$RC"
    echo "  ✅ 已清理 $RC 里的GITHUB_TOKEN（原文件备份为 $RC.bak-$TS）"
  fi
done
echo "  ✅ token 来源清理完毕"

echo ""
echo "=== [4/7] 停进程 ==="
pkill -9 -f "node.*server\.js" 2>/dev/null
sleep 3
REMAIN=$(pgrep -f "node.*server\.js" | wc -l)
if [ "$REMAIN" -gt 0 ]; then
  echo -e "${RED}❌ 有残留进程杀不掉，请截图发助手，脚本中止${NC}"
  pgrep -af "node.*server\.js"
  exit 1
fi
echo -e "${GREEN}✅ 已停止${NC}"

echo ""
echo "=== [5/7] 重启（无 token 环境） ==="
bash start.sh
sleep 6

echo ""
echo "=== [6/7] 验证进程环境 ==="
NEWPID=$(pgrep -f "node.*server\.js" | head -1)
if [ -z "$NEWPID" ]; then
  echo -e "${RED}❌ 进程没起来！最近日志：${NC}"
  tail -20 /var/log/reading-checkin.log
  echo "回滚方法：cp $BKDIR/start.sh /opt/reading-checkin/ && bash /opt/reading-checkin/start.sh"
  exit 1
fi
echo "新进程 PID=$NEWPID"
if tr '\0' '\n' < /proc/$NEWPID/environ 2>/dev/null | grep -q '^GITHUB_TOKEN='; then
  echo -e "${RED}❌ 新进程仍带token！token来源没清干净，请把上面[3/7]的输出截图发助手${NC}"
  exit 1
else
  echo -e "${GREEN}✅ 新进程环境无 GITHUB_TOKEN —— 纯本地模式已生效！${NC}"
fi
echo "  STORAGE_MODE=$(tr '\0' '\n' < /proc/$NEWPID/environ 2>/dev/null | grep '^STORAGE_MODE=' | cut -d= -f2)"
echo "  SSL_KEY_PATH=$(tr '\0' '\n' < /proc/$NEWPID/environ 2>/dev/null | grep '^SSL_KEY_PATH=' | cut -d= -f2)"

echo ""
echo "=== [7/7] 服务与数据验证 ==="
sleep 3
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://127.0.0.1/)
echo "  首页: HTTP $CODE"
if [ "$CODE" != "200" ]; then
  echo -e "${YELLOW}⚠️ 首页非200，最近日志：${NC}"
  tail -10 /var/log/reading-checkin.log
fi
AFTER=$(node -e "const d=require('/opt/reading-checkin/data/reading-checkin-data.json');console.log(d.checkins.filter(c=>c.date==='$TODAY').length)" 2>/dev/null || echo "?")
echo "  切换后今日($TODAY)打卡数: $AFTER (切换前: $BEFORE)"
if [ "$BEFORE" != "?" ] && [ "$AFTER" != "?" ] && [ "$BEFORE" != "$AFTER" ]; then
  echo -e "${YELLOW}⚠️ 条数有变化（$BEFORE -> $AFTER），请告知助手核对${NC}"
else
  echo -e "${GREEN}  ✅ 数据完整无损${NC}"
fi
CNT=$(curl -sk --max-time 10 https://127.0.0.1/api/checkins/today/1 2>/dev/null | head -c 150)
echo "  today接口抽查: ${CNT:0:120}..."

echo ""
echo "=============================================="
echo -e "${GREEN} 切换完成！当前架构：纯本地模式${NC}"
echo "  · 读写全部走本地文件（不再访问GitHub）"
echo "  · 每5分钟补偿任务读本地（本地永远最新，覆盖问题根治）"
echo "  · 服务器重启会自动拉起（crontab @reboot，同样无token）"
echo "  · 备份在 $BKDIR"
echo "=============================================="
echo ""
echo "5分钟后助手会从外网复查数据稳定性。"
