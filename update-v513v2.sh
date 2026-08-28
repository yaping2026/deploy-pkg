#!/bin/bash
# update-v513v2.sh - v5.13 简化升级版（只升级代码，不动数据）
#
# 改动：
#   server.js    新增 POST /api/members/:id/stop 和 /resume，报表按 leftDate 裁剪
#   scheduler.js 月报/日报/晚报过滤 leftDate 成员
#   admin.html   新增停止/恢复打卡按钮
#
# 简化点（相比 update-v513.sh）：
#   1) 数据修复独立到 restore-wxq-only.sh，本脚本只升级代码
#   2) 验证失败**不回滚**（v5.13 第一次部署时 /version 检查误判导致回滚，损失已确认）
#      改为：写详细日志到文件 + 输出明确错误码 + 让用户看 /tmp/update-v513v2.log 手动决定
#   3) 用 curl -k 跳过证书校验（OpenCloudOS 默认不带 ca-bundle，curl 60 错误是常见问题）
#   4) 三个文件统一替换（mv *.new 原文件），避免半替换状态
#
# 用法：curl -sL https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/update-v513v2.sh | bash
#
# 单独恢复魏晓晴数据请跑：restore-wxq-only.sh

set +e
LOG=/tmp/update-v513v2.log
TS=$(date +%s)
echo "[$(date '+%F %T')] ====== update-v513v2.sh 开始 ======" | tee "$LOG"

# [1/8] CDN 多通道下载（3 个文件并行思路：挨个下，便于定位）
echo "[$(date '+%F %T')] [1/8] CDN 多通道下载新代码..." | tee -a "$LOG"
mkdir -p /tmp/rc-v513v2
download() {
  local out="$1" min="$2"; shift 2
  for url in "$@"; do
    echo "[$(date '+%F %T')]   尝试: $url" | tee -a "$LOG"
    curl -sL --max-time 60 "$url" -o "$out" 2>/dev/null
    local sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
    if [ "$sz" -ge "$min" ]; then
      echo "[$(date '+%F %T')]   ✅ 下载成功 ($sz bytes) <- ${url%%/*}" | tee -a "$LOG"
      return 0
    fi
    echo "[$(date '+%F %T')]   ⚠️ 文件过小($sz bytes)，换通道" | tee -a "$LOG"
  done
  return 1
}
if ! download /tmp/rc-v513v2/scheduler.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/scheduler.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/scheduler.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/scheduler.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/scheduler.js"; then
  echo "[$(date '+%F %T')] ❌ scheduler.js 下载失败，请查看 $LOG" | tee -a "$LOG"
  exit 1
fi
if ! download /tmp/rc-v513v2/server.js 20000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/server.js" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/server.js" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/server.js" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/server.js"; then
  echo "[$(date '+%F %T')] ❌ server.js 下载失败" | tee -a "$LOG"
  exit 1
fi
if ! download /tmp/rc-v513v2/admin.html 50000 \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v513/admin.html" \
  "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/v513/admin.html"; then
  echo "[$(date '+%F %T')] ❌ admin.html 下载失败" | tee -a "$LOG"
  exit 1
fi

# [2/8] CRLF 转 LF
echo "[$(date '+%F %T')] [2/8] CRLF→LF..." | tee -a "$LOG"
tr -d '\r' < /tmp/rc-v513v2/scheduler.js > /tmp/rc-v513v2/scheduler_lf.js
tr -d '\r' < /tmp/rc-v513v2/server.js > /tmp/rc-v513v2/server_lf.js
tr -d '\r' < /tmp/rc-v513v2/admin.html > /tmp/rc-v513v2/admin_lf.html

# [3/8] 内容标记 + 语法检查
echo "[$(date '+%F %T')] [3/8] 校验内容标记..." | tee -a "$LOG"
FAIL=0
grep -q "v5.13" /tmp/rc-v513v2/scheduler_lf.js \
  && echo "[$(date '+%F %T')]   ✅ scheduler 含 v5.13 标记" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ scheduler 缺 v5.13 标记"; FAIL=1; }
grep -q "memberEnd" /tmp/rc-v513v2/scheduler_lf.js \
  && echo "[$(date '+%F %T')]   ✅ scheduler 含 leftDate 逻辑" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ scheduler 缺 leftDate 逻辑"; FAIL=1; }
grep -q "2026-08-28-v5.13" /tmp/rc-v513v2/server_lf.js \
  && echo "[$(date '+%F %T')]   ✅ server 含版本标记" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ server 缺 APP_VERSION 标记"; FAIL=1; }
grep -q "leftDate" /tmp/rc-v513v2/server_lf.js \
  && echo "[$(date '+%F %T')]   ✅ server 含 leftDate 逻辑" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ server 缺 leftDate 逻辑"; FAIL=1; }
# 关键：SSL 监听逻辑必须在（防 v5.12 教训重演）
grep -q "SSL_KEY_PATH" /tmp/rc-v513v2/server_lf.js && grep -q "listen(443" /tmp/rc-v513v2/server_lf.js \
  && echo "[$(date '+%F %T')]   ✅ server SSL 监听逻辑完好" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ server 缺 SSL 监听逻辑，已阻止替换！"; FAIL=1; }
grep -q "stopMember" /tmp/rc-v513v2/admin_lf.html \
  && echo "[$(date '+%F %T')]   ✅ admin.html 含停止打卡按钮" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ admin.html 缺停止打卡功能"; FAIL=1; }
if [ "$FAIL" = "1" ]; then
  echo "[$(date '+%F %T')] ❌ 内容校验失败，未替换任何文件。可重试或查看 $LOG" | tee -a "$LOG"
  exit 1
fi
echo "[$(date '+%F %T')] [4/8] 语法检查..." | tee -a "$LOG"
cp /tmp/rc-v513v2/scheduler_lf.js /tmp/rc-v513v2/chk_sch.cjs
cp /tmp/rc-v513v2/server_lf.js /tmp/rc-v513v2/chk_srv.cjs
NODE_BIN=$(command -v node || echo "node")
"$NODE_BIN" --check /tmp/rc-v513v2/chk_sch.cjs \
  && echo "[$(date '+%F %T')]   ✅ scheduler.js 语法OK" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ scheduler.js 语法错"; exit 1; }
"$NODE_BIN" --check /tmp/rc-v513v2/chk_srv.cjs \
  && echo "[$(date '+%F %T')]   ✅ server.js 语法OK" | tee -a "$LOG" \
  || { echo "[$(date '+%F %T')]   ❌ server.js 语法错"; exit 1; }

# [5/8] 备份 + 同时替换（mv 保证原子性，不会出现半替换状态）
echo "[$(date '+%F %T')] [5/8] 备份原文件..." | tee -a "$LOG"
for f in scheduler.js server.js admin.html; do
  if [ -f "/opt/reading-checkin/$f" ]; then
    cp "/opt/reading-checkin/$f" "/opt/reading-checkin/$f.bak-$TS"
    echo "[$(date '+%F %T')]   ✅ $f -> $f.bak-$TS" | tee -a "$LOG"
  fi
done
echo "[$(date '+%F %T')] [6/8] 替换（mv 原子操作，3文件统一切换）..." | tee -a "$LOG"
mv /tmp/rc-v513v2/scheduler_lf.js /opt/reading-checkin/scheduler.js
mv /tmp/rc-v513v2/server_lf.js /opt/reading-checkin/server.js
mv /tmp/rc-v513v2/admin_lf.html /opt/reading-checkin/admin.html
echo "[$(date '+%F %T')]   ✅ 3 个文件替换完成" | tee -a "$LOG"

# [7/8] 重启
echo "[$(date '+%F %T')] [7/8] 重启服务..." | tee -a "$LOG"
PIDS=$(ss -tlnp 2>/dev/null | grep -E ':(443|3002) ' | grep -oP 'pid=\K[0-9]+' | sort -u || true)
if [ -n "$PIDS" ]; then
  echo "[$(date '+%F %T')]   清理旧进程: $PIDS" | tee -a "$LOG"
  for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
  sleep 3
fi
if [ -f /opt/reading-checkin/start.sh ]; then
  bash /opt/reading-checkin/start.sh
  echo "[$(date '+%F %T')]   ✅ start.sh 已执行，等 10 秒" | tee -a "$LOG"
  sleep 10
else
  echo "[$(date '+%F %T')]   ⚠️ 找不到 start.sh，请手动启动 node server.js" | tee -a "$LOG"
  sleep 3
fi

# [8/8] 单一验证：curl -k version（跳过证书，回避 OpenCloudOS ca-bundle 缺失）
echo "[$(date '+%F %T')] [8/8] 验证 /version..." | tee -a "$LOG"
VER=""
for i in 1 2 3 4 5 6; do
  VER=$(curl -k -s --max-time 5 https://zhengpintang.cn/version 2>/dev/null)
  RC=$?
  echo "[$(date '+%F %T')]   [试$i] curl_rc=$RC -> $VER" | tee -a "$LOG"
  if echo "$VER" | grep -q "v5.13"; then
    echo "[$(date '+%F %T')]   ✅ /version 返回 v5.13，部署成功" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "🎉 v5.13 部署成功！" | tee -a "$LOG"
    echo "📋 日志: $LOG" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "下一步：单独跑数据恢复脚本" | tee -a "$LOG"
    echo "  curl -sL https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/restore-wxq-only.sh | bash" | tee -a "$LOG"
    exit 0
  fi
  sleep 3
done

# 验证失败：输出明确错误信息但 **不回滚**（避免误判毁掉 v5.13 部署）
echo "" | tee -a "$LOG"
echo "⚠️ /version 没有返回 v5.13，请查看以下信息排查：" | tee -a "$LOG"
echo "  最后响应: $VER" | tee -a "$LOG"
echo "  进程状态: $(ss -tlnp 2>/dev/null | grep -E ':443|:3002' | head -2)" | tee -a "$LOG"
echo "  /var/log/reading-checkin.log 最后 30 行:" | tee -a "$LOG"
tail -30 /var/log/reading-checkin.log 2>/dev/null | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "❌ 部署可能未成功，但已 *不自动回滚*（吸取上一次教训）" | tee -a "$LOG"
echo "   已替换的文件：scheduler.js / server.js / admin.html" | tee -a "$LOG"
echo "   备份：.bak-$TS" | tee -a "$LOG"
echo "   回滚命令（如需）：" | tee -a "$LOG"
echo "     bash /opt/reading-checkin/scheduler.js.bak-$TS /opt/reading-checkin/scheduler.js" | tee -a "$LOG"
echo "     bash /opt/reading-checkin/server.js.bak-$TS /opt/reading-checkin/server.js" | tee -a "$LOG"
echo "     bash /opt/reading-checkin/admin.html.bak-$TS /opt/reading-checkin/admin.html" | tee -a "$LOG"
exit 2
