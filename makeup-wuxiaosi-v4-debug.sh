#!/bin/bash
# v4-debug - 调试版，每个 curl 都打印完整响应（即使错也看得到）
set +e  # 不要因为任何一步出错就退出，要全部跑完看到底哪里出问题

echo "===== 吴晓四补卡 v4-debug ====="
echo ""

# 1) 登录（打印完整响应）
echo "[1] 管理员登录 - http://zhengpintang.cn/api/admin/login"
echo "    请求body: {\"user\":\"zpt5201314\",\"pass\":\"13787276549\"}"
rm -f /tmp/admin.cookies
curl -s -X POST -H "Content-Type: application/json" \
  -c /tmp/admin.cookies \
  -w "  HTTP=%{http_code} | cookie写入=%{num_redirects}\n" \
  http://zhengpintang.cn/api/admin/login \
  -d '{"user":"zpt5201314","pass":"13787276549"}'
echo "  cookie文件:"
cat /tmp/admin.cookies 2>/dev/null | grep -v "^#" | grep -v "^$"
echo ""

# 2) 验证登录态
echo "[2] 验证登录态 - /api/admin/check"
curl -s -b /tmp/admin.cookies -w "  HTTP=%{http_code}\n" \
  http://zhengpintang.cn/api/admin/check
echo ""

# 3) 调 admin-batch-update
echo "[3] 添加今日 normal 打卡 - PUT /api/checkins/admin-batch-update"
echo "    请求body: {\"changes\":[{\"memberId\":113,\"date\":\"2026-08-26\",\"action\":\"add-normal\"}]}"
RESULT=$(curl -s -X PUT -H "Content-Type: application/json" \
  -b /tmp/admin.cookies \
  -w "\n  HTTP=%{http_code}\n" \
  http://zhengpintang.cn/api/checkins/admin-batch-update \
  -d '{"changes":[{"memberId":113,"date":"2026-08-26","action":"add-normal"}]}')
echo "  响应: $RESULT"
echo ""

# 4) 如果 batch-update 失败，备用方案：直接走无admin鉴权的 /api/checkins/with-audio
if echo "$RESULT" | grep -q '"ok":true'; then
  echo "✅ admin-batch-update 成功"
else
  echo "⚠️ admin-batch-update 失败，试试 /api/poster/send (只需 memberId)"
  echo "[4] 备用方案 - POST /api/poster/send"
  curl -s -X POST -H "Content-Type: application/json" \
    -w "\n  HTTP=%{http_code}\n" \
    http://zhengpintang.cn/api/poster/send \
    -d '{"memberId":113,"date":"2026-08-26"}'
fi
echo ""

# 5) 验证
echo "[5] 实时查询吴晓四今日状态"
curl -s --max-time 15 "https://zhengpintang.cn/api/checkins/today/9" -o /tmp/today.json
node -e "
const d = JSON.parse(require('fs').readFileSync('/tmp/today.json','utf8'));
const w = (d.members||[]).find(m => m.id===113);
if (w) {
  console.log('  吴晓四 id=113:', JSON.stringify(w.name), '| checked=' + w.checked);
  if (w.checked) {
    const cnt = d.members.filter(m=>m.checked).length;
    console.log('  ✅ 补卡成功! 今日九组打卡数:', cnt + '/12');
  } else {
    console.log('  ⚠️ 数据未刷新，再等几秒');
  }
} else {
  console.log('  ❌ 找不到 id=113');
}
"

echo ""
echo "===== 调试结束，把整段输出发我 ====="
