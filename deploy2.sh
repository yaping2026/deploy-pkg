#!/bin/bash
# ============================================================
# 部署脚本 v3（2026-08-26）：本地存储模式 + HTTPS正式域名
# 前提：证书已粘贴到 /opt/reading-checkin/ssl/
# ============================================================
set -e

APP=/opt/reading-checkin
LOG=/var/log/reading-checkin.log
CDN_PRIMARY="https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN_BACKUP="https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main"

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
step() { echo -e "${YELLOW}[$1]${NC} $2"; }

cdn_download() {
  local out=$1 path=$2 minsize=$3
  for cdn in "$CDN_PRIMARY" "$CDN_BACKUP"; do
    echo "  尝试: $cdn/$path"
    curl -sL --connect-timeout 20 --max-time 120 -o "$out" "$cdn/$path" 2>/dev/null || true
    if [ -f "$out" ] && [ $(stat -c%s "$out" 2>/dev/null || echo 0) -gt $minsize ]; then
      return 0
    fi
  done
  return 1
}

echo "=========================================="
echo " 读书打卡系统部署 v3（本地存储+HTTPS）"
echo "=========================================="

step "1/8" "检查证书..."
if [ ! -f $APP/ssl/zhengpintang.cn.key ]; then
  fail "私钥不存在: $APP/ssl/zhengpintang.cn.key （请先粘贴证书，见部署说明第1步）"
fi
if [ ! -f $APP/ssl/zhengpintang.cn_bundle.crt ]; then
  fail "证书不存在: $APP/ssl/zhengpintang.cn_bundle.crt （请先粘贴证书，见部署说明第2步）"
fi
ok "证书文件齐全"

step "2/8" "下载新代码包..."
mkdir -p /tmp/deploy3
cdn_download /tmp/deploy3/app3.zip "app3.zip" 400000 || fail "代码包下载失败（CDN不通）"
ok "代码包下载成功 ($(du -h /tmp/deploy3/app3.zip | cut -f1))"

step "3/8" "下载最新打卡数据..."
cdn_download /tmp/deploy3/data2.json.gz "data2.json.gz" 50000 || fail "数据包下载失败（CDN不通）"
ok "数据包下载成功 ($(du -h /tmp/deploy3/data2.json.gz | cut -f1))"

step "4/8" "停止旧服务..."
pkill -9 -f "node server.js" 2>/dev/null || true
sleep 2
ok "旧服务已停止"

step "5/8" "部署代码和数据..."
# 解压代码（保留ssl目录和content目录）
unzip -o /tmp/deploy3/app3.zip -d $APP/ > /dev/null
mkdir -p $APP/content

# 备份现有数据后写入最新数据
mkdir -p $APP/data
if [ -f $APP/data/reading-checkin-data.json ]; then
  BAK=$APP/data/reading-checkin-data.json.bak.$(date +%Y%m%d%H%M%S)
  cp $APP/data/reading-checkin-data.json $BAK
  echo "  旧数据已备份: $BAK"
fi
gunzip -c /tmp/deploy3/data2.json.gz > $APP/data/reading-checkin-data.json
ok "代码部署完成，数据已更新"

step "6/8" "检查依赖..."
if [ ! -d $APP/node_modules ] || [ ! -f $APP/node_modules/express/package.json ]; then
  echo "  安装依赖（国内npm镜像，约1-2分钟）..."
  cd $APP && npm install --registry=https://registry.npmmirror.com > /tmp/deploy3/npm.log 2>&1
fi
ok "依赖就绪"

step "7/8" "生成启动脚本并启动..."
# 生成启动脚本（开机自启也用它）
cat > $APP/start.sh << 'START_EOF'
#!/bin/bash
cd /opt/reading-checkin
pkill -9 -f "node server.js" 2>/dev/null
sleep 1
STORAGE_MODE=local \
BASE_URL=https://zhengpintang.cn \
BASE_DOMAIN=zhengpintang.cn \
ADMIN_USER='zpt5201314' \
ADMIN_PASS='13787276549' \
SSL_KEY_PATH=/opt/reading-checkin/ssl/zhengpintang.cn.key \
SSL_CRT_PATH=/opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt \
PORT=3000 \
nohup node server.js >> /var/log/reading-checkin.log 2>&1 &
echo "服务已启动 PID: $!"
START_EOF
chmod +x $APP/start.sh

# 开机自启（crontab @reboot）
(crontab -l 2>/dev/null | grep -v "reading-checkin/start.sh"; echo "@reboot /opt/reading-checkin/start.sh") | crontab - 2>/dev/null || true

# 清空旧日志，启动
> $LOG
bash $APP/start.sh
ok "服务已启动"

step "8/8" "验证..."
sleep 5
if ss -tlnp 2>/dev/null | grep -q ":443 "; then
  ok "443端口(HTTPS)监听中"
else
  echo "  443端口未监听，查看日志："
  tail -20 $LOG
  fail "启动失败，请把上面的日志发给AI助手"
fi

echo ""
echo "=========================================="
echo -e "${GREEN} 部署完成！${NC}"
echo ""
echo " 打卡页:  https://zhengpintang.cn/checkin.html"
echo " 管理后台: https://zhengpintang.cn/admin.html"
echo ""
echo " 注意: 请确认腾讯云防火墙已放行 443 和 80 端口"
echo "       （控制台→轻量服务器→防火墙→添加规则）"
echo "=========================================="
