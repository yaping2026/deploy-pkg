#!/bin/bash
# ============================================================
# 极简迁移脚本 v2：清单内置 + 多CDN fallback + 默认跳过audio
# 关键改进：脚本自带文件清单，不依赖任何 GitHub API
# ============================================================
set -e

APP=/opt/reading-checkin
CONTENT_DIR=$APP/content
AUDIO_DIR=$APP/data/audio
LOG=/var/log/migrate_v2.log
TODAY=$(date '+%Y%m%d')

# ===== 内置文件清单（用户删过期的，自己加回来） =====
# deploy-pkg 仓库 content/ 目录所有文件，按日期排序
CONTENT_FILES=(
"20260825A.pdf" "20260825B.jpg"
"20260826A.pdf" "20260826B.jpg"
"20260827A.pdf" "20260827B.jpg"
"20260828A.pdf" "20260828B.jpg"
"20260829A.pdf" "20260829B.jpg"
"20260830A.pdf" "20260830B.jpg"
"20260831A.pdf" "20260831B.jpg"
)

# ===== CDN源（按优先级） =====
CDN1="https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN2="https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN3="https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN4="https://raw.githubusercontent.com/yaping2026/deploy-pkg/main"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1" | tee -a $LOG; }
fail() { echo -e "${RED}[FAIL]${NC} $1" | tee -a $LOG; exit 1; }
step() { echo -e "${YELLOW}[$1]${NC} $2" | tee -a $LOG; }

: > $LOG
START=$(date +%s)

step "0/4" "测试 CDN 连通性..."
WORKING=""
for url in "$CDN1/data2.json.gz" "$CDN2/data2.json.gz" "$CDN3/data2.json.gz" "$CDN4/data2.json.gz"; do
  host=$(echo "$url" | awk -F/ '{print $3}' | awk -F: '{print $1}')
  if timeout 20 curl -fsSI "$url" -o /dev/null 2>/dev/null; then
    ok "✅ $host"
    WORKING="$WORKING $host"
  fi
done
[ -z "$WORKING" ] && fail "所有CDN都不通，服务器可能完全断网"
echo "  可用CDN:$WORKING" | tee -a $LOG

step "1/4" "创建目录..."
mkdir -p $CONTENT_DIR $AUDIO_DIR
ok "就绪"

# 多CDN下载函数（依次尝试，记录成功源）
cdn_download() {
  local subDir=$1 filename=$2 outPath=$3
  local safe_name=$(echo "$filename" | sed 's/ /%20/g')

  for base in "$CDN1" "$CDN2" "$CDN3" "$CDN4"; do
    if timeout 30 curl -fsSL --connect-timeout 15 "$base/${subDir}/${safe_name}" -o "$outPath.tmp" 2>/dev/null; then
      if [ -s "$outPath.tmp" ] && [ $(stat -c%s "$outPath.tmp" 2>/dev/null || echo 0) -gt 100 ]; then
        mv "$outPath.tmp" "$outPath"
        echo "$base" > "$outPath.src"  # 记录来源
        return 0
      fi
    fi
    rm -f "$outPath.tmp"
  done
  return 1
}

step "2/4" "下载 content/ 文件..."
TOTAL=${#CONTENT_FILES[@]}
COUNT=0
SUCCESS=0
SKIP=0
FAIL=0
FAIL_LIST=""
for filename in "${CONTENT_FILES[@]}"; do
  COUNT=$((COUNT+1))
  OUT=$CONTENT_DIR/$filename
  if [ -f "$OUT" ] && [ $(stat -c%s "$OUT" 2>/dev/null || echo 0) -gt 100 ]; then
    SKIP=$((SKIP+1))
    echo "  [$COUNT/$TOTAL] 跳过: $filename" >> $LOG
  else
    if cdn_download "content" "$filename" "$OUT"; then
      SUCCESS=$((SUCCESS+1))
      SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
      echo -e "  ${GREEN}[$COUNT/$TOTAL]${NC} ✅ $filename ($((SIZE/1024))KB)" | tee -a $LOG
    else
      FAIL=$((FAIL+1))
      FAIL_LIST="$FAIL_LIST $filename"
      echo -e "  ${RED}[$COUNT/$TOTAL]${NC} ❌ $filename" | tee -a $LOG
    fi
  fi
done

CONTENT_TOTAL=$(ls $CONTENT_DIR 2>/dev/null | wc -l)
ok "完成: content目录现有 $CONTENT_TOTAL 个文件 (新下$SUCCESS 跳过$SKIP 失败$FAIL)"

step "3/4" "audio/ 处理..."
AUDIO_TOTAL=$(ls $AUDIO_DIR 2>/dev/null | wc -l)
echo "  ℹ️  默认跳过历史 audio 下载（新录音将自动本地保存）" | tee -a $LOG
echo "  当前 audio/ 目录已有录音: $AUDIO_TOTAL" | tee -a $LOG
echo "  需要时单独跑: WITH_AUDIO=1 bash 此脚本" | tee -a $LOG

step "4/4" "统计..."
DURATION=$(( $(date +%s) - START ))
echo "================================" | tee -a $LOG
echo " ⏱️  耗时: ${DURATION}秒" | tee -a $LOG
echo " 📁 content/ : $CONTENT_TOTAL 个" | tee -a $LOG
echo " 🎤 audio/   : $AUDIO_TOTAL 个" | tee -a $LOG
[ -n "$FAIL_LIST" ] && echo " ❌ 失败:$FAIL_LIST" | tee -a $LOG
echo "================================" | tee -a $LOG
echo "完整日志: $LOG" | tee -a $LOG
ok "完成！浏览器刷新 https://zhengpintang.cn/checkin.html"
