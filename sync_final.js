// 最终同步：把GitHub上遗漏的打卡记录合并到本地数据（本地优先，只追加本地缺少的）
const fs = require('fs');
const LOCAL = '/opt/reading-checkin/data/reading-checkin-data.json';
const GH = '/tmp/data-final.json';

const local = JSON.parse(fs.readFileSync(LOCAL, 'utf8'));
const gh = JSON.parse(fs.readFileSync(GH, 'utf8'));

// 备份
const bak = LOCAL + '.bak-' + new Date().toISOString().slice(0, 10);
fs.copyFileSync(LOCAL, bak);

// 合并打卡记录（按id去重，本地已有保留）
const localIds = new Set(local.checkins.map(c => c.id));
const missing = gh.checkins.filter(c => !localIds.has(c.id));
missing.forEach(c => local.checkins.push(c));
local.checkins.sort((a, b) => a.id - b.id);

// 同步成员/群组里本地没有的（保险，正常无差异）
const lm = new Set((local.members || []).map(m => m.id));
(gh.members || []).forEach(m => { if (!lm.has(m.id)) local.members.push(m); });

fs.writeFileSync(LOCAL, JSON.stringify(local));

console.log('===同步完成===');
console.log('备份文件:', bak);
console.log('合并新增打卡:', missing.length, '条');
missing.forEach(c => {
  const m = (local.members || []).find(x => x.id === c.memberId);
  console.log('  -', c.id, c.date, m ? m.name : ('memberId=' + c.memberId), '(type:' + c.type + ')');
});
console.log('本地总打卡数:', local.checkins.length);
console.log('如显示新增0条，说明数据本来就一致，无需处理');
