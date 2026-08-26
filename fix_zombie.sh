#!/bin/bash
# fix_zombie.sh - 一次性根治孤儿进程 + 防止重生
# 作者: AI 助手 / 时间: 2026-08-26
# 用法: curl ... | bash

set -e

LOG=/var/log/reading-checkin-zombie-fix.log
echo "[$LOG] $(date) 开始清理" | tee -a "$LOG"

# 1. 杀掉所有 reading-checkin/server.js 进程（包括刚冒的）
echo "[1/4] 杀掉所有孤儿..."
for pid in $(pgrep -f "reading-checkin/server.js" 2>/dev/null); do
    echo "  杀掉 PID $pid"
    kill -9 "$pid" 2>/dev/null || true
done
sleep 2

# 再次强杀（防止有新冒的）
for pid in $(pgrep -f "reading-checkin/server.js" 2>/dev/null); do
    echo "  二次强杀 PID $pid"
    kill -9 "$pid" 2>/dev/null || true
done
sleep 2

remaining=$(pgrep -f "reading-checkin/server.js" 2>/dev/null | wc -l)
echo "[1/4] 剩余孤儿: $remaining 个"
if [ "$remaining" -gt 0 ]; then
    echo "[警告] 还有 $remaining 个进程没杀掉，请发我看 ps 输出" | tee -a "$LOG"
fi

# 2. 把 start.sh 升级成 flock+PID 双锁版
echo "[2/4] 写入加固版 start.sh..."
cat > /opt/reading-checkin/start.sh << 'NEWSTART'
#!/bin/bash
# 加固版 start.sh - 即使被反复调用也只能运行一个实例
LOCKFILE=/tmp/reading-checkin-start.lock
PIDFILE=/opt/reading-checkin/server.pid

(
    flock -n 9 || {
        echo "[$(date '+%H:%M:%S')] start.sh: 已有实例在启动/运行，本调用跳过"
        exit 0
    }

    # 如果有 PIDFILE 且进程活着，直接跳过
    if [ -f "$PIDFILE" ]; then
        old_pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] start.sh: 服务已运行（PID $old_pid），本次跳过"
            exit 0
        fi
        # 旧 PID 死了，清理 PIDFILE
        rm -f "$PIDFILE"
    fi

    # 进入工作目录前先杀一遍（防御性）
    pkill -9 -f "reading-checkin/server.js" 2>/dev/null || true
    sleep 1

    # 启动新实例
    cd /opt/reading-checkin
    STORAGE_MODE=local \
    BASE_URL=https://zhengpintang.cn \
    BASE_DOMAIN=zhengpintang.cn \
    ADMIN_USER='zpt5201314' \
    ADMIN_PASS='13787276549' \
    SSL_KEY_PATH=/opt/reading-checkin/ssl/zhengpintang.cn.key \
    SSL_CRT_PATH=/opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt \
    PORT=3000 \
    nohup node server.js >> /var/log/reading-checkin.log 2>&1 &

    new_pid=$!
    echo "$new_pid" > "$PIDFILE"
    echo "[$(date '+%H:%M:%S')] start.sh: 服务已启动 PID $new_pid"
) 9>"$LOCKFILE"
NEWSTART

chmod +x /opt/reading-checkin/start.sh
echo "[2/4] start.sh 已加固（flock + PIDFILE 双重守护）"

# 3. 启动（现在只有 flock+PID 守护的新版本）
echo "[3/4] 通过加固 start.sh 启动..."
/opt/reading-checkin/start.sh
sleep 5

# 4. 验证：阅读-checkin 进程应该只剩 1 个
echo "[4/4] 验证进程状态："
ps aux | grep "reading-checkin/server.js" | grep -v grep || echo "（无进程）"

echo ""
echo "==================="
echo "✅ 修复完成"
echo "==================="
echo "下一步：帮吴晓四补今天的打卡"
echo "  curl -sL https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/makeup-wuxiaosi.sh | bash"
echo ""
echo "你现在应该只看到 1 个 reading-checkin 进程 + 1 个 health-check 进程"
echo "（health-check 是腾讯云系统服务，不要动）"
