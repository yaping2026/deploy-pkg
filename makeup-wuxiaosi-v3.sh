#!/bin/bash
# v3 - 用 admin-batch-update API 给吴晓四(memberId=113)补今日打卡
# 绕开磁盘文件结构问题（顶层 members vs 组内嵌套）
set -e

echo "===== 吴晓四补卡 (memberId=113, 五组, 今日 2026-08-26) ====="

# 1) 管理员登录拿 cookie
echo "[1/5] 管理员登录..."
rm -f /tmp/admin.cookies
LOGIN=$(curl -s -X POST -H "Content-Type: application/json" \
  -c /tmp/admin.cookies \
  http://zhengpintang.cn/api/admin/login \
  -d '{"user":"zpt5201314","pass":"13787276549"}')
echo "$LOGIN"

# 2) 调 admin-batch-update 加一条今日 normal 打卡
echo ""
echo "[2/5] 添加今日 normal 打卡..."
RESULT=$(curl -s -X PUT -H "Content-Type: application/json" \
  -b /tmp/admin.cookies \
  http://zhengpintang.cn/api/checkins/admin-batch-update \
  -d '{"changes":[{"memberId":113,"date":"2026-08-26","action":"add-normal"}]}')
echo "$RESULT"

# 3) 解析结果看是否成功
OK=$(echo "$RESULT" | grep -o '"ok":true' | head -1)
if [ -z "$OK" ]; then
  echo ""
  echo "❌ 补卡失败，请把上面输出发给 AI 看"
  exit 1
fi

# 4) 再发一次海报通知（让群里知道她完成了）
echo ""
echo "[3/5] 发送海报到五组群..."
POSTER=$(curl -s -X POST -H "Content-Type: application/json" \
  http://zhengpintang.cn/api/poster/send \
  -d '{"memberId":113,"date":"2026-08-26"}')
echo "$POSTER"

# 5) 验证
echo ""
echo "[4/5] 验证: 检查今日吴晓四打卡状态..."
curl -s --max-time 15 "https://zhengpintang.cn/api/checkins/today/9" -o /tmp/today.json
node -e "
const d = JSON.parse(require('fs').readFileSync('/tmp/today.json','utf8'));
const w = (d.members||[]).find(m => m.id===113);
if (w) {
  console.log('吴晓四 id=113:', JSON.stringify(w.name), '| checked=' + w.checked);
  if (w.checked) {
    const checked_count = d.members.filter(m=>m.checked).length;
    console.log('✅ 补卡成功! 今日九组打卡数:', checked_count + '/12');
  } else {
    console.log('⚠️ 还没刷新，再等几秒');
  }
} else {
  console.log('❌ 找不到 id=113 成员');
}
"

echo ""
echo "[5/5] 完成"
