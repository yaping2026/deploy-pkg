#!/bin/bash
# restore-wxq-only.sh - 独立脚本：恢复魏晓晴(id=27) 数据
# 背景：她最后打卡日 2026-08-11，2026-08-12 退出项目时被误删成员记录
#      导致三组7月报表统计不到她、错误显示"达标"
# 用法：curl -sL https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/restore-wxq-only.sh | bash
#
# 修复方案：恢复记录 + 标记 leftDate=2026-08-12
#   - 7月报表：恢复显示"不达标"（详情含"魏晓晴缺1"）
#   - 8月报表：8/1-8/11 共 11 天仍计入，含她 4 天缺卡（8/7 8/8 8/10 8/11）
#   - 8/12 起：不再要求打卡、不在日报/晚报/打卡名单/换组中出现
#
# 此脚本不修改任何代码，可与 update-v513.sh 独立执行
# 多次执行幂等

set +e
LOG=/tmp/restore-wxq.log
TS=$(date +%s)
echo "[$(date '+%F %T')] ====== restore-wxq-only.sh 开始 ======" | tee -a "$LOG"

# [1/5] 定位数据文件
echo "[$(date '+%F %T')] [1/5] 查找数据文件..." | tee -a "$LOG"
DATA_FILE=$(find /opt/reading-checkin -maxdepth 3 -name 'reading-checkin-data.json' -not -name '*.bak*' 2>/dev/null | head -1)
if [ -z "$DATA_FILE" ]; then
  DATA_FILE=$(find /opt/reading-checkin -maxdepth 3 -name 'data_latest.json' -not -name '*.bak*' 2>/dev/null | head -1)
fi
if [ -z "$DATA_FILE" ]; then
  echo "[$(date '+%F %T')] ❌ 找不到 reading-checkin-data.json 或 data_latest.json，请检查部署路径" | tee -a "$LOG"
  echo "[$(date '+%F %T')] 当前 /opt/reading-checkin/data/ 目录:" | tee -a "$LOG"
  ls -la /opt/reading-checkin/data/ 2>/dev/null | tee -a "$LOG"
  exit 1
fi
echo "[$(date '+%F %T')]  ✅ 数据文件: $DATA_FILE" | tee -a "$LOG"
echo "[$(date '+%F %T')]  当前大小: $(stat -c%s "$DATA_FILE") bytes" | tee -a "$LOG"

# [2/5] 备份现有数据文件
echo "[$(date '+%F %T')] [2/5] 备份现有数据..." | tee -a "$LOG"
cp "$DATA_FILE" "$DATA_FILE.bak-$TS"
echo "[$(date '+%F %T')]  ✅ 备份到: $DATA_FILE.bak-$TS" | tee -a "$LOG"

# [3/5] 执行数据修复
echo "[$(date '+%F %T')] [3/5] 恢复魏晓晴数据(leftDate=2026-08-12)..." | tee -a "$LOG"
cat > /tmp/restore-wxq.cjs <<'NODEEOF'
const fs = require('fs');
const FILE = process.argv[2];
let data;
try { data = JSON.parse(fs.readFileSync(FILE, 'utf8')); }
catch (e) { console.error('❌ 读取失败:', e.message); process.exit(2); }
if (!Array.isArray(data.members)) {
  console.error('❌ members 字段不是数组，文件结构可能异常');
  process.exit(2);
}
const REC = {
  id: 27,
  name: '魏晓晴',
  groupId: 3,
  pin: '8293',
  userid: '15973744774',
  startDate: '2026-06-01',
  leftDate: '2026-08-12'
};
const idx = data.members.findIndex(m => m && m.id === 27);
let changed = false;
if (idx < 0) {
  data.members.push(REC);
  changed = true;
  console.log('  ✅ 已恢复魏晓晴(id=27) 并标记 leftDate=2026-08-12');
} else if (!data.members[idx].leftDate) {
  data.members[idx].leftDate = '2026-08-12';
  changed = true;
  console.log('  ✅ 魏晓晴记录已存在，补充 leftDate=2026-08-12');
} else if (data.members[idx].leftDate === '2026-08-12') {
  console.log('  ⏭️ 魏晓晴已存在且 leftDate 正确，跳过（幂等）');
} else {
  console.error('  ⚠️ 魏晓晴已有 leftDate=' + data.members[idx].leftDate + '，与预期(2026-08-12)不一致，不自动覆盖');
  process.exit(3);
}
if (changed) {
  fs.writeFileSync(FILE, JSON.stringify(data));
  console.log('  ✅ 数据文件已保存');
}
NODEEOF
node /tmp/restore-wxq.cjs "$DATA_FILE" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
echo "[$(date '+%F %T')]  node exit code: $RC" | tee -a "$LOG"

# [4/5] 验证写入成功
echo "[$(date '+%F %T')] [4/5] 验证数据..." | tee -a "$LOG"
HAS_WXQ=$(grep -c '"name":"魏晓晴"' "$DATA_FILE" 2>/dev/null || echo 0)
HAS_DATE=$(grep -c '"leftDate":"2026-08-12"' "$DATA_FILE" 2>/dev/null || echo 0)
echo "[$(date '+%F %T')]  魏晓晴记录数: $HAS_WXQ（期望 1）" | tee -a "$LOG"
echo "[$(date '+%F %T')]  leftDate=2026-08-12 标记数: $HAS_DATE（期望 1）" | tee -a "$LOG"

# [5/5] 让服务立即生效（重启读取新文件）
echo "[$(date '+%F %T')] [5/5] 重启服务使数据生效..." | tee -a "$LOG"
PIDS=$(ss -tlnp 2>/dev/null | grep -E ':(443|3002) ' | grep -oP 'pid=\K[0-9]+' | sort -u || true)
if [ -n "$PIDS" ]; then
  echo "[$(date '+%F %T')]  清理旧进程: $PIDS" | tee -a "$LOG"
  for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
  sleep 3
fi
if [ -f /opt/reading-checkin/start.sh ]; then
  bash /opt/reading-checkin/start.sh
  sleep 8
  echo "[$(date '+%F %T')]  服务已重启" | tee -a "$LOG"
else
  echo "[$(date '+%F %T')]  ⚠️ 找不到 /opt/reading-checkin/start.sh，请手动重启" | tee -a "$LOG"
fi

echo "[$(date '+%F %T')] ====== 成功完成 ======" | tee -a "$LOG"
echo ""
echo "🎉 数据修复完成！请到后台 → 三组成员列表确认魏晓晴已出现"
echo "📋 完整日志见: $LOG"
echo ""
echo "[$(date '+%F %T')] 当前版本（重启后可能没变，因为这是数据脚本）:" | tee -a "$LOG"
curl -k -s --max-time 5 https://zhengpintang.cn/version | tee -a "$LOG"
echo "" | tee -a "$LOG"
