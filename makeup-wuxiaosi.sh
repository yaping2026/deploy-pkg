#!/bin/bash
# makeup-wuxiaosi.sh - 管理员手动补吴晓四今日打卡
# 用法: curl ... | bash  (在服务器上跑)
# 路径: /opt/reading-checkin/data/reading-checkin-data.json

set -e
DATA=/opt/reading-checkin/data/reading-checkin-data.json
BACKUP=/opt/reading-checkin/data/reading-checkin-data.json.bak-$(date +%H%M%S)

cd /opt/reading-checkin

# 1. 备份原数据
cp -p "$DATA" "$BACKUP"
echo "[1/4] 备份原数据到 $BACKUP"

# 2. 用 node 操作数据文件，添加一条吴晓四今日打卡
node << 'NODEEOF'
const fs = require('fs');
const DATA = '/opt/reading-checkin/data/reading-checkin-data.json';

const raw = fs.readFileSync(DATA, 'utf8');
const d = JSON.parse(raw);

// 找吴晓四
let wuMember = null;
let wuGroup = null;
d.groups.forEach(g => {
  (g.members || []).forEach(m => {
    if ((m.name || '').includes('吴晓四') || (m.name || '').includes('晓四')) {
      wuMember = m;
      wuGroup = g;
    }
  });
});

if (!wuMember) {
  console.error('❌ 在数据中找不到"吴晓四"成员');
  process.exit(1);
}

console.log('找到成员:', wuMember.name, '| ID:', wuMember.id, '| 组:', wuGroup.name, '| userid:', wuMember.userid);
console.log('today:', wuMember.startDate || '(无起算日期)');

// 计算新打卡 id
const maxId = d.checkins.reduce((max, c) => Math.max(max, c.id || 0), 0);
const newId = maxId + 1;
const now = new Date().toISOString().slice(0, 19).replace('T', ' ');

// 创建新打卡
const newCheckin = {
  id: newId,
  memberId: wuMember.id,
  groupId: wuGroup.id,
  userName: wuMember.name,
  date: '2026-08-26',
  createdAt: now,
  type: 'normal',
  audioUrl: '',  // 无录音（原来的录音文件已被孤儿进程覆盖丢失）
  source: 'admin-makeup',
  pin: wuMember.pin,
  content: 'eligible-26'
};

d.checkins.push(newCheckin);

const out = JSON.stringify(d);
fs.writeFileSync(DATA, out);
console.log('✅ 已添加打卡 id=' + newId, '|', newCheckin.userName, '|', newCheckin.date);
NODEEOF

echo "[2/4] 数据已更新"

# 3. 调用 /api/admin/refresh-data 让内存缓存刷新（让新进程加载新数据）
echo "[3/4] 通知 server 刷新数据..."
curl -s -X POST -H "Content-Type: application/json" \
  -c /tmp/admin.cookies http://zhengpintang.cn/api/admin/login \
  -d '{"user":"zpt5201314","pass":"13787276549"}' > /dev/null

curl -s -X POST -b /tmp/admin.cookies \
  http://zhengpintang.cn/api/admin/refresh-data
echo ""

# 4. 验证 - 拉今日五组数据看吴晓四是否打卡
echo "[4/4] 验证：检查今日吴晓四打卡状态..."
GROUP_ID=$(node -e "
const d = JSON.parse(require('fs').readFileSync('$DATA','utf8'));
const g = d.groups.find(g => (g.members||[]).some(m => (m.name||'').includes('吴晓四')));
console.log(g ? g.id : '');
")
echo "二组查询（groupId=$GROUP_ID）"
curl -s --max-time 20 "https://zhengpintang.cn/api/checkins/today/$GROUP_ID" -o /tmp/today.json
node -e "
const d = JSON.parse(require('fs').readFileSync('/tmp/today.json','utf8'));
const w = (d.members||[]).find(m => (m.name||'').includes('吴晓四'));
console.log('吴晓四 checked:', w ? w.checked : '未找到');
if (w && w.checked) {
  console.log('✅ 补卡成功！今日打卡数:', d.members.filter(m=>m.checked).length);
} else {
  console.log('⚠️ 还没刷新，再等几秒（缓存可能还在更新）');
}
"

echo ""
echo "==================="
echo "🎉 修复完成"
echo "==================="
echo "备份文件: $BACKUP"
echo "新增打卡 id: $(grep -oE 'id=[0-9]+|newId' /dev/null 2>&1; node -e "console.log(JSON.parse(require('fs').readFileSync('$DATA','utf8')).checkins.slice(-1)[0].id)")"
