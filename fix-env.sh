#!/bin/bash
# 一键修复：补齐环境变量（管理员账号 zpt5201314 + 内容走本站代理）
# 不改任何代码，只修启动方式；不碰 health-check
set -u
cd /opt/reading-checkin || { echo "❌ 目录不存在"; exit 1; }

echo "===== 一键修复开始 ====="

echo "[1/5] 检查SSL证书..."
mkdir -p /opt/reading-checkin/ssl
SSL_KEY_PATH=$(ls /opt/reading-checkin/ssl/*.key 2>/dev/null | head -1)
SSL_CRT_PATH=$(ls /opt/reading-checkin/ssl/*.crt 2>/dev/null | head -1)
if [ -z "$SSL_CRT_PATH" ]; then SSL_CRT_PATH=$(ls /opt/reading-checkin/ssl/*.pem 2>/dev/null | head -1); fi
if [ -z "$SSL_KEY_PATH" ] || [ -z "$SSL_CRT_PATH" ]; then
  echo "❌ 证书未找到！/opt/reading-checkin/ssl/ 下需要 .key + .crt/.pem"
  exit 1
fi
echo "  证书: $SSL_KEY_PATH + $SSL_CRT_PATH"

echo "[2/5] 写入启动脚本 start.sh（配置永久固化）..."
# 从正在运行的进程里提取 GITHUB_TOKEN（避免明文写在脚本里）
OLD_PID=$(ss -tlnp 2>/dev/null | grep ":443 " | grep -oP 'pid=\K[0-9]+' | head -1)
GH_TOKEN=""
if [ -n "$OLD_PID" ] && [ -r "/proc/$OLD_PID/environ" ]; then
  GH_TOKEN=$(tr '\0' '\n' < "/proc/$OLD_PID/environ" | grep '^GITHUB_TOKEN=' | cut -d= -f2-)
fi
if [ -z "$GH_TOKEN" ]; then
  # 也试试3002端口上的旧进程
  OLD_PID2=$(ss -tlnp 2>/dev/null | grep ":3002 " | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -n "$OLD_PID2" ] && [ -r "/proc/$OLD_PID2/environ" ]; then
    GH_TOKEN=$(tr '\0' '\n' < "/proc/$OLD_PID2/environ" | grep '^GITHUB_TOKEN=' | cut -d= -f2-)
  fi
fi
cat > /opt/reading-checkin/start.sh <<EOF
#!/bin/bash
cd /opt/reading-checkin
export STORAGE_MODE=local
export PORT=3002
export BASE_DOMAIN=zhengpintang.cn
export BASE_URL=https://zhengpintang.cn
export ADMIN_USER=zpt5201314
export ADMIN_PASS=13787276549
export GITHUB_TOKEN=$GH_TOKEN
export SSL_KEY_PATH=\$(ls /opt/reading-checkin/ssl/*.key 2>/dev/null | head -1)
SSL_CRT=\$(ls /opt/reading-checkin/ssl/*.crt 2>/dev/null | head -1)
if [ -z "\$SSL_CRT" ]; then SSL_CRT=\$(ls /opt/reading-checkin/ssl/*.pem 2>/dev/null | head -1); fi
export SSL_CRT_PATH=\$SSL_CRT
exec nohup node server.js >> /var/log/reading-checkin.log 2>&1
EOF
chmod +x /opt/reading-checkin/start.sh
echo "  ✅ /opt/reading-checkin/start.sh 已生成"

echo "[3/5] 重启（只杀 reading-checkin，不碰卫生检查）..."
for P in 443 80 3002; do
  PID=$(ss -tlnp 2>/dev/null | grep ":$P " | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -n "$PID" ]; then echo "  kill :$P (PID $PID)"; kill -9 "$PID" 2>/dev/null; fi
done
sleep 2
bash /opt/reading-checkin/start.sh
echo "  启动中... (等10秒让SSL就绪)"

echo "[4/5] 等待启动..."
sleep 10
ss -tln | grep -q ':443 ' && echo "  ✅ 443已监听" || { echo "  ❌ 443未监听！查日志:"; tail -20 /var/log/reading-checkin.log; exit 1; }

echo "[5/5] 验证..."
echo "--- 版本 ---"
curl -s --max-time 15 https://zhengpintang.cn/version && echo ""
echo "--- 管理员登录验证 ---"
LOGIN=$(curl -s --max-time 15 -X POST https://zhengpintang.cn/api/admin/login -H "Content-Type: application/json" -d '{"user":"zpt5201314","pass":"13787276549"}')
echo "  $LOGIN"
echo "--- 今日内容走代理验证 ---"
curl -s --max-time 15 "https://zhengpintang.cn/api/content/today?group=1" | head -c 300
echo ""
echo ""
echo "===== 修复完成 ====="
echo "后台登录: https://zhengpintang.cn/admin  账号 zpt5201314 / 13787276549"
echo "以后重启只需: bash /opt/reading-checkin/start.sh"
