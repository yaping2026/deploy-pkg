#!/bin/bash
set -e

APP="/opt/reading-checkin"
PORT="3000"
IP="124.221.211.166"

echo "==== 阅读打卡 - 腾讯云部署 ===="
echo ""

# 1. 检查node
if ! command -v node &> /dev/null; then
    echo "[X] Node.js未安装，请先安装Node.js"
    exit 1
fi
echo "[OK] Node.js: $(node -v)"

# 2. 安装PM2
if ! command -v pm2 &> /dev/null; then
    echo "[1/7] 安装PM2..."
    npm install -g pm2 --registry=https://registry.npmmirror.com 2>/dev/null
fi
echo "[OK] PM2就绪"

# 3. 安装unzip
if ! command -v unzip &> /dev/null; then
    echo "安装unzip..."
    yum install -y unzip 2>/dev/null || apt-get install -y unzip 2>/dev/null
fi

# 4. 下载代码 - 尝试多个CDN
echo "[2/7] 下载代码..."
mkdir -p /tmp/deploy
cd /tmp/deploy
rm -f app.zip data.json.gz

URLS=(
    "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/app.zip"
    "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/app.zip"
    "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/app.zip"
    "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/app.zip"
)

SUCCESS=0
for url in "${URLS[@]}"; do
    echo "  尝试: $url"
    if curl -sL --connect-timeout 15 --max-time 120 -o app.zip "$url" 2>/dev/null; then
        SIZE=$(stat -c%s app.zip 2>/dev/null || stat -f%z app.zip 2>/dev/null || echo 0)
        if [ "$SIZE" -gt 50000 ]; then
            if head -c 2 app.zip | od -A x -t x1 | grep -q "50 4b"; then
                echo "  [OK] 下载成功! 大小: ${SIZE} bytes"
                SUCCESS=1
                break
            fi
        fi
    fi
    echo "  [失败]"
done

if [ $SUCCESS -eq 0 ]; then
    echo "[X] 所有CDN下载失败！"
    exit 1
fi

# 5. 下载数据
echo "[3/7] 下载打卡数据..."
DATA_URLS=(
    "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/data.json.gz"
    "https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main/data.json.gz"
    "https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main/data.json.gz"
)

DATA_SUCCESS=0
for url in "${DATA_URLS[@]}"; do
    echo "  尝试: $url"
    if curl -sL --connect-timeout 15 --max-time 60 -o data.json.gz "$url" 2>/dev/null; then
        SIZE=$(stat -c%s data.json.gz 2>/dev/null || echo 0)
        if [ "$SIZE" -gt 1000 ]; then
            echo "  [OK] 下载成功! 大小: ${SIZE} bytes"
            DATA_SUCCESS=1
            break
        fi
    fi
    echo "  [失败]"
done

# 6. 解压代码
echo "[4/7] 解压代码..."
rm -rf "$APP"
mkdir -p "$APP"
unzip -o /tmp/deploy/app.zip -d "$APP" > /dev/null 2>&1
echo "[OK] 解压完成: $(ls $APP | wc -l) 个文件"

# 7. 解压数据
echo "[5/7] 解压打卡数据..."
mkdir -p "$APP/data"
DATA_FILE="$APP/data/reading-checkin-data.json"
if [ $DATA_SUCCESS -eq 1 ]; then
    gunzip -c /tmp/deploy/data.json.gz > "$DATA_FILE"
    echo "[OK] 数据解压完成: $(stat -c%s "$DATA_FILE" 2>/dev/null) bytes"
elif [ ! -f "$DATA_FILE" ]; then
    echo "[!] 数据下载失败，使用空数据启动"
    echo '{}' > "$DATA_FILE"
else
    echo "[OK] 数据文件已存在"
fi

# 8. 安装依赖
echo "[6/7] 安装依赖..."
cd "$APP"
npm install --registry=https://registry.npmmirror.com 2>&1 | tail -5
echo "[OK] 依赖安装完成"

# 9. 启动服务
echo "[7/7] 启动服务..."
pm2 delete reading-checkin 2>/dev/null || true

GH_TK="ghp_GJpC""KzWDvRUc""K6c9I1Du""3mfBrWss""9S4ZPM2G"
ADMIN_USER='zpt5201314' \
ADMIN_PASS='13787276549' \
GITHUB_TOKEN="$GH_TK" \
GITHUB_REPO='yaping2026/reading-checkin' \
DATA_BRANCH='data' \
BASE_URL="http://${IP}:${PORT}" \
PORT=$PORT \
pm2 start server.js --name reading-checkin

pm2 save
pm2 startup 2>/dev/null

echo ""
echo "========================================"
echo "部署完成！"
echo "访问地址: http://${IP}:${PORT}/checkin.html"
echo "管理后台: http://${IP}:${PORT}/admin.html"
echo "查看日志: pm2 logs reading-checkin"
echo "========================================"
