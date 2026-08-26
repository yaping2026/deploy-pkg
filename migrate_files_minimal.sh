#!/bin/bash
# ============================================================
# 一键迁移脚本（精简版）：只下当日+未来 content + 可选 audio
# 适用：本地存储模式
# 用法：curl -sL ... | bash  [MODE=audio 可选下录音]
# ============================================================
set -e

APP=/opt/reading-checkin
CONTENT_DIR=$APP/content
AUDIO_DIR=$APP/data/audio
LOG=/var/log/migrate_files.log
TODAY=$(date '+%Y%m%d')
WITH_AUDIO=${WITH_AUDIO:-0}   # WITH_AUDIO=1 时才下载录音

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1" | tee -a $LOG; }
fail() { echo -e "${RED}[FAIL]${NC} $1" | tee -a $LOG; exit 1; }
step() { echo -e "${YELLOW}[$1]${NC} $2" | tee -a $LOG; }

: > $LOG
START_TIME=$(date +%s)
echo "精简版迁移启动: $(date '+%Y-%m-%d %H:%M:%S')  今日=$TODAY  WITH_AUDIO=$WITH_AUDIO" >> $LOG

step "1/4" "获取文件清单..."
curl -sL --connect-timeout 30 --max-time 60 \
  "https://api.github.com/repos/yaping2026/deploy-pkg/git/trees/main?recursive=1" \
  -o /tmp/file_list.json || fail "无法获取文件清单"

# 解析并过滤：只保留 >= today 的 content
node -e "
const fs=require('fs');
const j=JSON.parse(fs.readFileSync('/tmp/file_list.json','utf8'));
const today='$TODAY';
const trees=j.tree||[];
const allContent=trees.filter(t=>t.path.startsWith('content/')).map(t=>t.path.replace(/^content\//,''));
// 文件名格式 YYYYMMDD[A|B].pdf/jpg，过滤出 >= today
const futureContent=allContent.filter(f=>f.substring(0,8) >= today).sort();
const audioAll=trees.filter(t=>t.path.startsWith('audio/')).map(t=>t.path.replace(/^audio\//,''));
fs.writeFileSync('/tmp/content_list.json',JSON.stringify(futureContent));
fs.writeFileSync('/tmp/audio_list.json',JSON.stringify(audioAll));
console.log('  需要下载 content (>= 今日$today):',futureContent.length,'个');
console.log('  content总数(全部历史):',allContent.length);
console.log('  audio总数(可选下):',audioAll.length);
" || fail "解析文件清单失败"

step "2/4" "创建目录..."
mkdir -p $CONTENT_DIR $AUDIO_DIR
ok "目录就绪"

# 通用下载函数
cdn_download_file() {
  local subDir=$1 filename=$2 outPath=$3
  for try in 1 2; do
    if curl -fsSL --connect-timeout 30 --max-time 180 \
      "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/${subDir}/${filename}" \
      -o "$outPath.tmp" 2>/dev/null; then
      if [ -s "$outPath.tmp" ] && [ $(stat -c%s "$outPath.tmp" 2>/dev/null || echo 0) -gt 100 ]; then
        mv "$outPath.tmp" "$outPath"
        return 0
      fi
    fi
    rm -f "$outPath.tmp"
    sleep 1
  done
  if curl -fsSL --connect-timeout 30 --max-time 180 \
    "https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/${subDir}/${filename}" \
    -o "$outPath.tmp" 2>/dev/null; then
    if [ -s "$outPath.tmp" ] && [ $(stat -c%s "$outPath.tmp" 2>/dev/null || echo 0) -gt 100 ]; then
      mv "$outPath.tmp" "$outPath"
      return 0
    fi
  fi
  rm -f "$outPath.tmp"
  return 1
}

step "3/4" "迁移 content/ 文件（仅今日+未来，共7天×2=14个）..."
mapfile -t CONTENT_FILES < <(node -e "console.log(JSON.parse(require('fs').readFileSync('/tmp/content_list.json','utf8')).join('\n'))")
TOTAL=${#CONTENT_FILES[@]}
COUNT=0
SUCCESS=0
SKIP=0
FAIL=0

for filename in "${CONTENT_FILES[@]}"; do
  COUNT=$((COUNT+1))
  [ -z "$filename" ] && continue
  OUT=$CONTENT_DIR/$filename
  if [ -f "$OUT" ] && [ $(stat -c%s "$OUT" 2>/dev/null || echo 0) -gt 100 ]; then
    SKIP=$((SKIP+1))
  else
    if cdn_download_file "content" "$filename" "$OUT"; then
      SUCCESS=$((SUCCESS+1))
      SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
      echo -e "  ${GREEN}[$COUNT/$TOTAL]${NC} ✅ $filename ($((SIZE/1024))KB)" | tee -a $LOG
    else
      FAIL=$((FAIL+1))
      echo -e "  ${RED}[$COUNT/$TOTAL]${NC} ❌ $filename" | tee -a $LOG
    fi
  fi
done

CONTENT_OK=$(ls $CONTENT_DIR 2>/dev/null | wc -l)
ok "content完成: 目录现 $CONTENT_OK 个文件（新下载 $SUCCESS，跳过 $SKIP，失败 $FAIL）"

step "4/4" "audio 处理..."
if [ "$WITH_AUDIO" = "1" ]; then
  echo "  ⚠️ 用户要求下全部 audio（可能耗时较长）..." | tee -a $LOG
  mapfile -t AUDIO_FILES < <(node -e "console.log(JSON.parse(require('fs').readFileSync('/tmp/audio_list.json','utf8')).join('\n'))")
  TOTAL=${#AUDIO_FILES[@]}
  COUNT=0
  SUCCESS=0
  for filename in "${AUDIO_FILES[@]}"; do
    COUNT=$((COUNT+1))
    [ -z "$filename" ] && continue
    OUT=$AUDIO_DIR/$filename
    if [ -f "$OUT" ] && [ $(stat -c%s "$OUT" 2>/dev/null || echo 0) -gt 1000 ]; then
      continue
    fi
    if cdn_download_file "audio" "$filename" "$OUT"; then
      SUCCESS=$((SUCCESS+1))
    fi
    if [ $((COUNT % 30)) -eq 0 ]; then
      echo "  audio进度 [$COUNT/$TOTAL] 已下载 $SUCCESS" | tee -a $LOG
    fi
  done
  AUDIO_OK=$(ls $AUDIO_DIR 2>/dev/null | wc -l)
  ok "audio完成: 目录现 $AUDIO_OK 个录音"
else
  echo "  ℹ️  未开启 audio 下载（设 WITH_AUDIO=1 才下历史录音）" | tee -a $LOG
  echo "  ℹ️  本地新录的会自动保存到 $AUDIO_DIR" | tee -a $LOG
  AUDIO_OK=$(ls $AUDIO_DIR 2>/dev/null | wc -l)
  echo "  当前目录已有录音: $AUDIO_OK" | tee -a $LOG
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "================================" | tee -a $LOG
echo "✅ content/ 目录: $(ls $CONTENT_DIR 2>/dev/null | wc -l) 个文件" | tee -a $LOG
echo "🎤 audio/ 目录:  $(ls $AUDIO_DIR 2>/dev/null | wc -l) 个录音" | tee -a $LOG
echo "⏱️ 总耗时: $((DURATION/60))分$((DURATION%60))秒" | tee -a $LOG
echo "================================" | tee -a $LOG
ok "完成！刷新 https://zhengpintang.cn/checkin.html 验证"
