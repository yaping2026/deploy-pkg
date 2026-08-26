#!/bin/bash
# fix-overwrite-v2.sh —— 根治打卡数据被覆盖问题（2026-08-26晚）
# 根因：db.js 的 readFresh() 只要进程带 GITHUB_TOKEN 环境变量，每5分钟的"海报补偿任务"
#       就会从GitHub拉数据并覆盖本地文件；而v3本地模式下打卡只写本地（GitHub停在16:05）
#       → 16:05之后的新打卡被反复冲掉（吴银春/易娟/袁宇/吴晓四就是这样丢的）
# 修复：①停掉所有server进程 ②合并本地+GitHub数据（并集，保住全部打卡）
#       ③readFresh改为只读本地 ④清掉GITHUB_TOKEN后用start.sh重启（环境干净）
# 本脚本可重复执行（幂等），失败可直接重跑
set -u
echo "===== 数据覆盖bug根治脚本 $(date '+%F %T') ====="
cd /opt/reading-checkin || { echo "❌ /opt/reading-checkin 不存在"; exit 1; }
[ "$(id -u)" = "0" ] || echo "⚠️ 未用root执行，读取进程环境变量可能失败"

echo ""
echo "--- [1] 备份关键文件 ---"
TS=$(date +%s)
cp db.js "db.js.bak-$TS" && echo "✅ db.js → db.js.bak-$TS"
[ -f data/reading-checkin-data.json ] && cp data/reading-checkin-data.json "data/reading-checkin-data.json.bak-$TS" && echo "✅ 数据文件已备份"
[ -f start.sh ] && cp start.sh "start.sh.bak-$TS" && echo "✅ start.sh已备份"

echo ""
echo "--- [2] 停掉所有server进程（止血：覆盖就是它们干的）---"
echo "--- 当前进程（含PPID，方便看出守护者） ---"
ps -eo pid,ppid,stat,lstart,cmd | grep -E "node.*server\.js" | grep -v grep || echo "（无server进程）"

# 关键：先杀PM2 daemon！它是元凶（PM2检测到node死会立刻拉起新进程）
if command -v pm2 >/dev/null 2>&1; then
  echo "--- 发现PM2，先pm2 kill停掉守护 ---"
  pm2 kill 2>/dev/null && echo "✅ PM2 daemon已停" || echo "⚠️ pm2 kill异常（可能PM2未运行）"
  sleep 2
elif [ -f /root/.pm2 ] || [ -f "$HOME/.pm2" ]; then
  echo "--- 找到.pm2目录，尝试直接杀PM2 daemon ---"
  pkill -9 -f "PM2" 2>/dev/null && echo "✅ PM2 daemon已杀" || echo "（无PM2进程）"
  sleep 2
else
  echo "（无PM2，按常规方式杀node）"
fi

# 从将死的进程里抢救GITHUB_TOKEN（数据合并要用；登录shell里通常没有这个变量）
SAVED_TOK=""
for PID in $(pgrep -f "node.*server\.js" 2>/dev/null); do
  if [ -r "/proc/$PID/environ" ]; then
    T=$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^GITHUB_TOKEN=' | head -1 | cut -d= -f2-)
    if [ -n "${T:-}" ]; then SAVED_TOK="$T"; export GITHUB_TOKEN="$T"; echo "✅ 已从进程$PID提取GITHUB_TOKEN（仅供本次数据合并）"; fi
  fi
done

# 先用信号优雅退出，给2秒
for PID in $(pgrep -f "node.*server\.js" 2>/dev/null); do kill -15 $PID 2>/dev/null; done
sleep 2
# 强杀SIGKILL
for PID in $(pgrep -f "node.*server\.js" 2>/dev/null); do kill -9 $PID 2>/dev/null && echo "killed node $PID"; done
sleep 1
# 踢占用443/3000端口的进程（防node以外的守护占着）
fuser -k -9 443/tcp 2>/dev/null; fuser -k -9 3000/tcp 2>/dev/null; sleep 1
# 再次强杀（防PM2重新拉起期间漏掉的）
pkill -9 -f "node.*server\.js" 2>/dev/null
pkill -9 -f "/opt/reading-checkin" 2>/dev/null
pkill -9 -f "/opt/health-check" 2>/dev/null
sleep 3

REMAIN=$(pgrep -f "node.*server\.js" 2>/dev/null | wc -l)
echo "杀后残留: $REMAIN 个"
if [ "$REMAIN" -gt 0 ]; then
  echo "❌ 仍有进程残留，列出详情（看PPID找出元凶）："
  ps -eo pid,ppid,stat,cmd | grep -E "node.*server\.js" | grep -v grep
  echo ""
  echo "尝试最后手段：逐一 kill -9 + 等待5秒 + 再次确认"
  for PID in $(pgrep -f "node.*server\.js" 2>/dev/null); do kill -9 $PID 2>/dev/null; done
  sleep 5
  REMAIN2=$(pgrep -f "node.*server\.js" 2>/dev/null | wc -l)
  echo "再杀后残留: $REMAIN2 个"
  if [ "$REMAIN2" -gt 0 ]; then
    echo "❌ 仍残留！请把'详细列表'截图发我，可能是D状态或cgroup隔离"
    ps -eo pid,ppid,stat,cmd | grep -E "node.*server\.js" | grep -v grep
    exit 1
  fi
fi
echo "✅ 全部server进程已清干净"

echo ""
echo "--- [3] 合并本地+GitHub数据（并集，保住全部打卡）---"
node -e '
const fs = require("fs");
(async () => {
  const DB = "data/reading-checkin-data.json";
  const n = new Date();
  const TODAY = n.getFullYear() + "-" + String(n.getMonth() + 1).padStart(2, "0") + "-" + String(n.getDate()).padStart(2, "0");
  let local = null;
  try { local = JSON.parse(fs.readFileSync(DB, "utf8")); } catch (e) { console.log("本地文件不可读: " + e.message); }
  let gh = null;
  const TOK = process.env.GITHUB_TOKEN;
  if (TOK) {
    for (let i = 1; i <= 3 && !gh; i++) {
      try {
        const res = await fetch("https://api.github.com/repos/yaping2026/reading-checkin/contents/data/reading-checkin-data.json?ref=data", {
          headers: { Authorization: "token " + TOK, Accept: "application/vnd.github.v3+json", "User-Agent": "fix" },
          signal: AbortSignal.timeout(20000)
        });
        if (res.ok) {
          const j = await res.json();
          let content = null;
          if (j.content && j.content.length > 0) {
            content = Buffer.from(j.content, "base64").toString("utf8");
          } else if (j.sha) {
            const br = await fetch("https://api.github.com/repos/yaping2026/reading-checkin/git/blobs/" + j.sha, {
              headers: { Authorization: "token " + TOK, Accept: "application/vnd.github.v3+json", "User-Agent": "fix" },
              signal: AbortSignal.timeout(20000)
            });
            const bj = await br.json();
            if (bj.content) content = Buffer.from(bj.content, "base64").toString("utf8");
          }
          if (content) gh = JSON.parse(content);
          if (gh) console.log("✅ GitHub数据拉取成功: " + gh.checkins.length + "条打卡");
        } else { console.log("GitHub HTTP " + res.status + "（第" + i + "次尝试）"); }
      } catch (e) { console.log("GitHub拉取失败（第" + i + "次）: " + e.message); }
    }
    if (!gh) console.log("⚠️ GitHub多次拉取失败");
  } else {
    console.log("⚠️ 无GITHUB_TOKEN（进程和shell里都没有），拉不到GitHub——晚上恢复的4条打卡会缺失！可稍后重跑本脚本");
  }

  let merged;
  if (local && gh) {
    merged = gh;
    const key = c => c.memberId + "-" + c.date;
    const ghKeys = new Set(gh.checkins.map(key));
    let add = 0;
    for (const c of local.checkins) { if (!ghKeys.has(key(c))) { merged.checkins.push(c); add++; } }
    if (local._cronSent) {
      merged._cronSent = merged._cronSent || {};
      for (const k of Object.keys(local._cronSent)) {
        if (!merged._cronSent[k] || String(local._cronSent[k]) > String(merged._cronSent[k])) merged._cronSent[k] = local._cronSent[k];
      }
    }
    console.log("✅ 合并完成: GitHub " + gh.checkins.length + " + 本地独有 " + add + " = " + merged.checkins.length + "条");
  } else if (gh) {
    merged = gh;
    console.log("⚠️ 本地无文件，直接用GitHub数据: " + gh.checkins.length + "条");
  } else if (local) {
    merged = local;
    console.log("⚠️⚠️ GitHub不可达，暂用本地数据: " + local.checkins.length + "条（恢复的4条打卡在GitHub上，网络恢复后重跑本脚本可补齐）");
  } else {
    console.log("❌ 本地和GitHub都没有数据，无法处理");
    process.exit(1);
  }
  // 吴晓四(mid=113)海报置为待发送，让补偿任务自动补发到二组群
  const c113 = merged.checkins.find(x => x.memberId === 113 && x.date === TODAY);
  if (c113) { c113.posterSent = false; console.log("✅ 吴晓四(mid=113)海报已置为待补发（约5分钟内自动发出）"); }
  let maxId = 0;
  for (const c of merged.checkins) { if (c.id > maxId) maxId = c.id; }
  merged.nextCheckinId = Math.max(merged.nextCheckinId || 0, maxId + 1);
  fs.writeFileSync(DB, JSON.stringify(merged));
  const nameOf = {};
  for (const m of (merged.members || [])) nameOf[m.id] = m.name;
  const today = merged.checkins.filter(c => c.date === TODAY);
  console.log("合并后今日(" + TODAY + ")打卡 " + today.length + "条:");
  console.log(today.map(c => (nameOf[c.memberId] || ("mid" + c.memberId)) + "@" + c.time).join("、"));
})().catch(e => { console.error("合并异常: " + e.message); process.exit(1); });
'
if [ $? -ne 0 ]; then
  echo "⚠️ 数据合并失败，稍后可重跑本脚本。先继续把服务拉起来。"
fi

echo ""
echo "--- [4] 修改db.js：readFresh不再从GitHub覆盖本地（若已改过则跳过）---"
node -e '
const fs = require("fs");
let code = fs.readFileSync("db.js", "utf8");
const m = code.match(/async function readFresh\(\)\s*\{/);
if (!m) {
  console.log("⚠️ 未找到readFresh函数定义（结构可能不同）——无妨：重启的进程不带GITHUB_TOKEN，本身就不会拉GitHub");
  const i = code.indexOf("readFresh");
  if (i >= 0) console.log(code.substring(Math.max(0, i - 150), i + 400));
  process.exit(0);
}
const start = m.index;
const nextFn = code.indexOf("async function", start + 10);
const end = nextFn > 0 ? nextFn : code.length;
const section = code.substring(start, end);
if (section.includes("if (GITHUB_TOKEN)")) {
  const patched = section.replace("if (GITHUB_TOKEN)", "if (false && GITHUB_TOKEN)");
  code = code.substring(0, start) + patched + code.substring(end);
  fs.writeFileSync("db.js", code);
  console.log("✅ readFresh已改为只读本地（根治覆盖）");
  console.log("--- 修改后的 readFresh ---");
  console.log(patched);
} else if (section.includes("false && GITHUB_TOKEN")) {
  console.log("✅ readFresh已是本地模式（之前已改过），无需修改");
} else {
  console.log("⚠️ readFresh结构与预期不同，未修改（无妨：重启的进程无GITHUB_TOKEN同样安全）。实际代码：");
  console.log(section);
}
'

echo ""
echo "--- [5] 清掉GITHUB_TOKEN并重启（PM2优先，否则用start.sh）---"
unset GITHUB_TOKEN 2>/dev/null || true
# 关键防御：把start.sh的pkill pattern加宽，避免再出现"两个node并存"
if [ -f start.sh ]; then
  sed -i 's/pkill -9 -f "node server\.js"/pkill -9 -f "node.*server[.]js"/g' start.sh 2>/dev/null
  if grep -q 'node.*server\[.\]js' start.sh; then echo "✅ start.sh杀进程pattern已加宽（防双进程复发）"; fi
fi

if command -v pm2 >/dev/null 2>&1; then
  echo "--- 用PM2启动（之前它就是守护者，现在重新接管，稳定可靠）---"
  pm2 start server.js --name reading-checkin --log /var/log/reading-checkin.log 2>&1 | tail -5
  pm2 save 2>/dev/null
  echo "✅ PM2已启动 reading-checkin"
elif [ -f start.sh ]; then
  echo "--- 用start.sh启动 ---"
  bash start.sh
else
  echo "⚠️ start.sh不存在，用内置参数直接启动"
  STORAGE_MODE=local BASE_URL=https://zhengpintang.cn BASE_DOMAIN=zhengpintang.cn \
  ADMIN_USER='zpt5201314' ADMIN_PASS='13787276549' \
  SSL_KEY_PATH=/opt/reading-checkin/ssl/zhengpintang.cn.key \
  SSL_CRT_PATH=/opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt \
  PORT=3000 nohup node server.js >> /var/log/reading-checkin.log 2>&1 &
  echo "已启动 PID: $!"
fi
sleep 4
echo "--- 重启后进程（应只有1个 node server.js，且PPID是PM2或1）---"
ps -eo pid,ppid,stat,cmd | grep -E "node.*server\.js" | grep -v grep || echo "❌ 进程没起来！看下面的日志"

echo ""
echo "--- [6] 健康验证 ---"
ss -tlnp 2>/dev/null | grep -E ":443 |:80 " || echo "⚠️ 443/80未监听！请把 tail -30 /var/log/reading-checkin.log 发给助手"
curl -sk -o /dev/null -w "本机443首页: %{http_code}\n" https://127.0.0.1/ --max-time 8
curl -sk -o /dev/null -w "本机443API: %{http_code}\n" https://127.0.0.1/api/checkins/today/9 --max-time 8
curl -s -o /dev/null -w "外网HTTPS: %{http_code}\n" https://zhengpintang.cn/api/checkins/today/9 --max-time 10
echo "--- API实际返回（前300字符，应能看到今日打卡数据）---"
curl -sk https://127.0.0.1/api/checkins/today/9 --max-time 8 | head -c 300; echo ""

echo ""
echo "--- [7] 数据最终验证 ---"
node -e '
const fs = require("fs");
try {
  const d = JSON.parse(fs.readFileSync("data/reading-checkin-data.json", "utf8"));
  const n = new Date();
  const TODAY = n.getFullYear() + "-" + String(n.getMonth() + 1).padStart(2, "0") + "-" + String(n.getDate()).padStart(2, "0");
  const nameOf = {};
  for (const m of (d.members || [])) nameOf[m.id] = m.name;
  const today = d.checkins.filter(c => c.date === TODAY);
  console.log("本地数据文件 今日(" + TODAY + ")打卡总数: " + today.length + "条");
  const targets = [[88, "吴银春"], [44, "易娟"], [89, "袁宇"], [113, "吴晓四"]];
  for (const t of targets) {
    const c = today.find(x => x.memberId === t[0]);
    console.log((c ? "✅" : "❌") + " " + t[1] + ": " + (c ? "已打卡 " + c.time + (c.recovered ? " [恢复]" : "") + " 海报待补发=" + (c.posterSent === false ? "是" : "否") : "未打卡!!"));
  }
  let maxId = 0;
  for (const c of today) { if (c.id > maxId) maxId = c.id; }
  console.log("nextCheckinId=" + d.nextCheckinId + "（今日最大id=" + maxId + "，前者应更大）");
  console.log("今日全部打卡: " + today.map(c => (nameOf[c.memberId] || ("mid" + c.memberId)) + "@" + c.time).join("、"));
} catch (e) { console.log("❌ 验证失败: " + e.message); }
'

echo ""
echo "--- [8] 今日海报发送记录（从日志核对有无漏发）---"
grep "\[poster\]" /var/log/reading-checkin.log 2>/dev/null | tail -25 || echo "（日志暂无poster记录）"
echo ""
echo "--- [9] 最近启动日志 ---"
tail -8 /var/log/reading-checkin.log 2>/dev/null || echo "（日志文件不存在）"

echo ""
echo "===== 完成 $(date '+%F %T') ====="
echo "✅ 已完成：停旧进程 → 合并数据 → readFresh改本地优先 → 干净环境单进程重启"
echo "📌 吴晓四的海报会在服务启动后约5分钟内自动补发到二组群"
echo "📌 请把以上全部输出截图发给AI助手确认"
echo "📌 10分钟后请再打开管理后台确认数据没有回退"
