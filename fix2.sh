#!/bin/bash
# fix2.sh - 修复 start.sh 假死问题 + 重启补全环境变量 + 升级 admin.html

set +e

echo "=========================================="
echo "  fix2: 修复 start.sh + 重启 + admin.html"
echo "=========================================="
echo ""

# [1/6] 重写 start.sh（关键：nohup & disown 后台启动 + 完整环境变量）
echo "[1/6] 重写 start.sh（后台启动，不再占前台）..."
cat > /opt/reading-checkin/start.sh << 'EOF_START'
#!/bin/bash
cd /opt/reading-checkin
export STORAGE_MODE=local
export PORT=3002
export BASE_DOMAIN=zhengpintang.cn
export BASE_URL=https://zhengpintang.cn
export ADMIN_USER=zpt5201314
export ADMIN_PASS=13787276549
SK=$(ls /opt/reading-checkin/ssl/*.key 2>/dev/null | head -1)
SC=$(ls /opt/reading-checkin/ssl/*.crt 2>/dev/null | head -1)
[ -n "$SK" ] && export SSL_KEY_PATH="$SK"
[ -n "$SC" ] && export SSL_CRT_PATH="$SC"
nohup node server.js >> /var/log/reading-checkin.log 2>&1 &
disown
echo "服务已在后台启动，PID: $!"
exit 0
EOF_START
chmod +x /opt/reading-checkin/start.sh
echo "  start.sh 已重写（含 nohup & disown + 全部配置）"
echo ""

# [2/6] 杀掉 reading-checkin 占 :443 的进程（不动 health-check 的 :3001）
echo "[2/6] 杀掉 :443 上的旧进程..."
PIDS=$(ss -tlnp 2>/dev/null | grep ':443 ' | grep -oP 'pid=\K[0-9]+' || true)
if [ -n "$PIDS" ]; then
  echo "  PID: $PIDS"
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
  sleep 3
  echo "  已清理"
else
  echo "  :443 当前无进程占用"
fi
echo ""

# [3/6] 启动服务（这次 shell 会立刻返回，不会卡住）
echo "[3/6] 后台启动 v5.12.1..."
bash /opt/reading-checkin/start.sh
echo "  等 8 秒让 SSL 完成握手..."
sleep 8
LISTEN=$(ss -tlnp 2>/dev/null | grep ':443 ')
if [ -n "$LISTEN" ]; then
  echo "  443 监听中: $LISTEN"
else
  echo "  443 未监听，看日志..."
  tail -20 /var/log/reading-checkin.log 2>/dev/null
fi
echo ""

# [4/6] 验证版本
echo "[4/6] 版本验证..."
for i in 1 2 3; do
  R=$(curl -s --max-time 6 https://zhengpintang.cn/version)
  echo "  [试 $i] $R"
  if echo "$R" | grep -q "v5.12"; then break; fi
  sleep 2
done
echo ""

# [5/6] 验证登录（关键：要看到 ok:true）
echo "[5/6] 管理员登录验证..."
for i in 1 2 3 4 5 6 7; do
  R=$(curl -s --max-time 6 -X POST https://zhengpintang.cn/api/admin/login \
       -H "Content-Type: application/json" \
       -d '{"user":"zpt5201314","pass":"13787276549"}')
  echo "  [试 $i] $R"
  if echo "$R" | grep -q '"ok":true'; then
    echo "  登录成功！"
    break
  fi
  sleep 2
done
echo ""

# [6/6] 升级 admin.html（抽签按钮修复）
echo "[6/6] 升级 admin.html（修复换组按钮）..."
ADMIN_CUR=$(stat -c%s /opt/reading-checkin/public/admin.html 2>/dev/null || echo 0)
echo "  当前: ${ADMIN_CUR} bytes"
rm -f /tmp/admin_new.html
for src in \
  "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html" \
  "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/v5122/admin.html"; do
  curl -sL --max-time 45 "$src" -o /tmp/admin_new.html 2>/dev/null
  SZ=$(stat -c%s /tmp/admin_new.html 2>/dev/null || echo 0)
  echo "  试 $src (${SZ} bytes)"
  if [ "$SZ" -gt 30000 ] && grep -q "loadGroups().then(loadRegroup)" /tmp/admin_new.html; then
    cp /tmp/admin_new.html /opt/reading-checkin/public/admin.html
    echo "  admin.html 已升级（文件大小 $SZ）"
    break
  fi
done
if ! grep -q "loadGroups().then(loadRegroup)" /opt/reading-checkin/public/admin.html 2>/dev/null; then
  echo "  升级未完成，admin.html 维持旧版（不影响登录和主功能）"
fi
echo ""

echo "=========================================="
echo "  完成！浏览器强刷 https://zhengpintang.cn/admin"
echo "=========================================="
