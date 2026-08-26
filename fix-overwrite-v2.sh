#!/bin/bash
# fix-overwrite-v2.sh —— 根治打卡数据被覆盖问题
# 根因：服务器每5分钟"海报补偿任务"调 db.readFresh()，从GitHub拉旧数据覆盖本地文件
#       v3本地模式下打卡只写本地不写GitHub → GitHub停留在旧版本 → 每次覆盖都丢新打卡
# 修复：1.合并本地+GitHub数据（保全部打卡） 2.readFresh改为只读本地 3.单进程重启
set -u
echo "===== 数据覆盖bug根治脚本 $(date '+%F %T') ====="
cd /opt/reading-checkin || { echo "❌ /opt/reading-checkin 不存在"; exit 1; }

echo ""
echo "--- [1] 备份关键文件 ---"
TS=$(date +%s)
cp db.js "db.js.bak-$TS" && echo "✅ db.js → db.js.bak-$TS"
[ -f data/reading-checkin-data.json ] && cp data/reading-checkin-data.json "data/reading-checkin-data.json.bak-$TS" && echo "✅ 数据文件已备份"

echo ""
echo "--- [2] 当前进程（改代码前留证）---"
ps -eo pid,lstart,cmd | grep -E "node.*server\.js" | grep -v grep || echo "（无server进程）"

echo ""
echo "--- [3] 合并本地+GitHub数据（保住全部打卡）---"
node -e '
const fs = require("fs");
(async () => {
  const DB = "data/reading-checkin-data.json";
  let local = null;
  try { local = JSON.parse(fs.readFileSync(DB, "utf8")); } catch(e) { console.log("本地文件不可读:", e.message); }
  let gh = null;
  const TOK = process.env.GITHUB_TOKEN;
  if (TOK) {
    try {
      const res = await fetch("https://api.github.com/repos/yaping2026/reading-checkin/contents/data/reading-checkin-data.json?ref=data", {
        headers: { Authorization: "token " + TOK, Accept: "application/vnd.github.v3+json", "User-Agent": "fix" }, signal: AbortSignal.timeout(15000)
      });
      if (res.ok) {
        const j = await res.json();
        let content;
        if (j.content && j.content.length > 0) {
          content = Buffer.from(j.content, "base64").toString("utf8");
        } else {
          const blobRes = await fetch("https://api.github.com/repos/yaping2026/reading-checkin/git/blobs/" + j.sha, {
            headers: { Authorization: "token " + TOK, Accept: "application/vnd.github.v3+json", "User-Agent": "fix" }, signal: AbortSignal.timeout(15000)
          });
          const bj = await blobRes.json();
          content = Buffer.from(bj.content, "base64").toString("utf8");
        }
        gh = JSON.parse(content);
        console.log("✅ GitHub数据拉取成功: " + gh.checkins.length + "条打卡");
      } else { console.log("GitHub读取HTTP " + res.status); }
    } catch(e) { console.log("GitHub拉取失败（国内网络常见）:", e.message); }
  } else { console.log("⚠️ 无GITHUB_TOKEN环境变量，只用本地数据"); }

  let merged;
  if (local && gh) {
    // 合并：以GitHub为主（含恢复数据），把本地独有的打卡并进来
    merged = gh;
    const key = c => c.memberId + "-" + c.date;
    const ghKeys = new Set(gh.checkins.map(key));
    let add = 0;
    for (const c of local.checkins) {
      if (!ghKeys.has(key(c))) { merged.checkins.push(c); add++; }
    }
    let maxId = 0;
    for (const c of merged.checkins) if (c.id > maxId) maxId = c.id;
    merged.nextCheckinId = Math.max(merged.nextCheckinId || 0, maxId + 1);
    console.log("✅ 合并完成: GitHub " + gh.checkins.length + " + 本地独有 " + add + " = " + merged.checkins.length + "条");
  } else if (local) {
    merged = local; console.log("⚠️ 用本地数据（GitHub不可达）: " + local.checkins.length + "条");
  } else if (gh) {
    merged = gh; console.log("⚠️ 用GitHub数据（本地无文件）: " + gh.checkins.length + "条");
  } else {
    console.log("❌ 两边都没数据，不动"); process.exit(1);
  }
  fs.writeFileSync(DB, JSON.stringify(merged));
  const today = merged.checkins.filter(c => c.date === "2026-08-26");
  console.log("合并后今日打卡: " + today.length + "条");
})().catch(e => { console.error("合并异常:", e.message); process.exit(1); });
'
[ $? -ne 0 ] && { echo "❌ 数据合并失败，中止（未改任何代码）"; exit 1; }

echo ""
echo "--- [4] 修改 db.js：readFresh 不再从GitHub覆盖本地 ---"
node -e '
const fs = require("fs");
let code = fs.readFileSync("db.js", "utf8");
const m = code.match(/async function readFresh\(\)\s*\{/);
if (!m) { console.log("❌ 未找到readFresh函数。db.js相关片段："); const i = code.indexOf("readFresh"); console.log(code.substring(Math.max(0,i-200), i+600)); process.exit(1); }
const start = m.index;
const nextFn = code.indexOf("async function", start + 10);
const section = code.substring(start, nextFn);
const patched = section.replace("if (GITHUB_TOKEN)", "if (false && GITHUB_TOKEN)");
if (patched === section) { console.log("❌ readFresh内未找到 if (GITHUB_TOKEN)，实际代码："); console.log(section); process.exit(1); }
code = code.substring(0, start) + patched + code.substring(nextFn);
fs.writeFileSync("db.js", code);
console.log("✅ readFresh 已改为本地文件优先（根治覆盖）");
console.log("--- 修改后的 readFresh ---");
console.log(patched);
'
[ $? -ne 0 ] && { echo "❌ db.js修改失败，中止"; exit 1; }

echo ""
echo "--- [5] 杀掉所有旧进程，单实例重启 ---"
pkill -9 -f "node.*server\.js" 2>/dev/null; sleep 2
REMAIN=$(ps -ef | grep -E "node.*server\.js" | grep -v grep | wc -l)
echo "残留进程: $REMAIN"
nohup flock -n /tmp/reading-checkin.lock -c "cd /opt/reading-checkin && exec node server.js >> /var/log/reading-checkin.log 2>&1" > /dev/null 2>&1 &
sleep 8
echo "--- 重启后进程 ---"
ps -eo pid,lstart,cmd | grep -E "node.*server\.js|flock -n" | grep -v grep

echo ""
echo "--- [6] 健康验证 ---"
sleep 3
for ep in "/" "/api/checkins/today/9" "/version"; do
  PORT=$(ss -tlnp 2>/dev/null | grep -oP "node.*pid=\d+" >/dev/null && echo "" ; true)
  :
done
curl -s -o /dev/null -w "本机3000首页: %{http_code}\n" http://localhost:3000/ --max-time 8
curl -s -o /dev/null -w "本机3000API: %{http_code}\n" http://localhost:3000/api/checkins/today/9 --max-time 8
curl -s -o /dev/null -w "外网HTTPS: %{http_code}\n" -k https://zhengpintang.cn/api/checkins/today/9 --max-time 10

echo ""
echo "--- [7] 数据最终验证 ---"
node -e '
const fs = require("fs");
const d = JSON.parse(fs.readFileSync("data/reading-checkin-data.json","utf8"));
const today = d.checkins.filter(c => c.date === "2026-08-26");
console.log("今日打卡总数: " + today.length);
const targets = [88, 44, 89, 113];
const names = {88:"吴银春", 44:"易娟", 89:"袁宇", 113:"吴晓四"};
for (const t of targets) {
  const c = today.find(x => x.memberId === t);
  console.log((c ? "✅" : "❌") + " " + names[t] + "(mid=" + t + "): " + (c ? "已打卡 " + c.time + (c.recovered ? " [恢复]" : "") : "未打卡!"));
}
console.log("nextCheckinId: " + d.nextCheckinId);
'

echo ""
echo "--- [8] 最近日志（看启动是否正常）---"
tail -15 /var/log/reading-checkin.log 2>/dev/null || echo "（日志文件不存在）"

echo ""
echo "===== 完成 $(date '+%F %T') ====="
echo "📌 请把以上全部输出截图发给AI助手确认"
