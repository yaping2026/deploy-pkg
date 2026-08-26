#!/bin/bash
# ============================================================
# 强化版迁移脚本：直接用 jsDelivr Gcore（绕过 GitHub raw 不通的问题）
# 用法：curl -sL ... | bash
# ============================================================
set -e

APP=/opt/reading-checkin
CONTENT_DIR=$APP/content
AUDIO_DIR=$APP/data/audio
LOG=/var/log/migrate_files.log
TODAY=$(date '+%Y%m%d')
WITH_AUDIO=${WITH_AUDIO:-0}

# CDN源（经过多次验证，jsDelivr Gcore + Fastly 国内稳定）
CDN1="https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN2="https://fastly.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
CDN3="https://cdn.jsdelivr.net/gh/yaping2026/deploy-pkg@main"
GITHUB_API="https://api.github.com/repos/yaping2026/deploy-pkg/git/trees/main?recursive=1"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1" | tee -a $LOG; }
fail() { echo -e "${RED}[FAIL]${NC} $1" | tee -a $LOG; exit 1; }
step() { echo -e "${YELLOW}[$1]${NC} $2" | tee -a $LOG; }

: > $LOG
START_TIME=$(date +%s)

step "0/5" "先测试 CDN 连通性..."
for cdn_url in "$CDN1" "$CDN2" "$CDN3"; do
  host=$(echo "$cdn_url" | awk -F/ '{print $3}')
  if timeout 15 curl -fsSI "$cdn_url/data2.json.gz" -o /dev/null 2>/dev/null; then
    ok "✅ $host 可用（首选）"
    WORKING_CDN="$cdn_url"
    break
  else
    echo "  ⚠️ $host 不通，尝试下一个" | tee -a $LOG
  fi
done
[ -z "$WORKING_CDN" ] && fail "三个CDN全都不通！"
CDN="$WORKING_CDN"
echo "  使用CDN: $CDN" | tee -a $LOG

step "1/5" "从CDN下载文件清单..."
# 直接用 GitHub raw 的常见替代 - 通过 CDN 的目录接口可能不可靠，先尝试 GitHub API（上次能用）
LIST_TMP=/tmp/file_list_$$.json
for src in "$GITHUB_API"; do
  echo "  尝试: $src" | tee -a $LOG
  if timeout 60 curl -fsSL --connect-timeout 30 "$src" -o "$LIST_TMP" 2>/dev/null; then
    if [ -s "$LIST_TMP" ] && [ $(stat -c%s "$LIST_TMP" 2>/dev/null || echo 0) -gt 1000 ]; then
      ok "清单获取成功"
      break
    fi
  fi
  rm -f "$LIST_TMP"
done
[ ! -s "$LIST_TMP" ] && fail "无法获取文件清单（所有CDN都不通，需排查网络）"

step "2/5" "解析清单 + 创建目录..."
node -e "
const fs=require('fs');
const j=JSON.parse(fs.readFileSync('$LIST_TMP','utf8'));
const today='$TODAY';
const trees=j.tree||[];
const allContent=trees.filter(t=>t.path.startsWith('content/')).map(t=>t.path.replace(/^content\//,''));
const futureContent=allContent.filter(f=>f.substring(0,8) >= today).sort();
const audioAll=trees.filter(t=>t.path.startsWith('audio/')).map(t=>t.path.replace(/^audio\//,''));
fs.writeFileSync('/tmp/content_list.json',JSON.stringify(futureContent));
fs.writeFileSync('/tmp/audio_list.json',JSON.stringify(audioAll));
console.log('  need content:',futureContent.length,'/',allContent.length,'total');
console.log('  audio:',audioAll.length);
"
rm -f "$LIST_TMP"
mkdir -p $CONTENT_DIR $AUDIO_DIR
ok "目录就绪"

# 通用下载函数：多CDN失败重试
cdn_download_file() {
  local subDir=$1 filename=$2 outPath=$3
  local safe_name=$(echo "$filename" | sed 's/ /%20/g')

  # 尝试顺序：已知可用 CDN → 其他 CDN → GitHub raw
  for cdn in "$CDN" "$CDN1" "$CDN2" "$CDN3"; do
    if timeout 60 curl -fsSL --connect-timeout 20 "$cdn/${subDir}/${safe_name}" -o "$outPath.tmp" 2>/dev/null; then
      if [ -s "$outPath.tmp" ] && [ $(stat -c%s "$outPath.tmp" 2>/dev/null || echo 0) -gt 100 ]; then
        mv "$outPath.tmp" "$outPath"
        return 0
      fi
    fi
    rm -f "$outPath.tmp"
  done

  # 最后尝试 GitHub raw
  if timeout 90 curl -fsSL --connect-timeout 30 "https://raw.githubusercontent.com/yaping2026/deploy-pkg/main/${subDir}/${safe_name}" -o "$outPath.tmp" 2>/dev/null; then
    if [ -s "$outPath.tmp" ] && [ $(stat -c%s "$outPath.tmp" 2>/dev/null || echo 0) -gt 100 ]; then
      mv "$outPath.tmp" "$outPath"
      return 0
    fi
  fi
  rm -f "$outPath.tmp"
  return 1
}

step "3/5" "迁移 content/ 文件..."
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
ok "content完成: $CONTENT_OK 个（新 $SUCCESS，跳过 $SKIP，失败 $FAIL）"

step "4/5" "audio 处理..."
if [ "$WITH_AUDIO" = "1" ]; then
  echo "  用户开启 audio 全量下载..." | tee -a $LOG
  mapfile -t AUDIO_FILES < <(node -e "console.log(JSON.parse(require('fs').readFileSync('/tmp/audio_list.json','utf8')).join('\n'))")
  TOTAL=${#AUDIO_FILES[@]}
  COUNT=0
  SUCCESS=0
  for filename in "${AUDIO_FILES[@]}"; do
    COUNT=$((COUNT+1))
    [ -z "$filename" ] && continue
    OUT=$AUDIO_DIR/$filename
    if [ -f "$OUT" ] && [ $(stat -c%s "$OUT" 2>/dev/null || echo 0) -gt 1000 ]; then continue; fi
    if cdn_download_file "audio" "$filename" "$OUT"; then
      SUCCESS=$((SUCCESS+1))
    fi
    if [ $((COUNT % 30)) -eq 0 ]; then
      echo "  audio [$COUNT/$TOTAL] 成功 $SUCCESS" | tee -a $LOG
    fi
  done
  ok "audio完成: $(ls $AUDIO_DIR 2>/dev/null | wc -l) 个"
else
  echo "  ℹ️  跳过 audio（新录音将自动保存到本地）" | tee -a $LOG
fi

step "5/5" "统计..."
DURATION=$(( $(date +%s) - START_TIME ))
echo "================================" | tee -a $LOG
echo "  content/ : $(ls $CONTENT_DIR 2>/dev/null | wc -l)" | tee -a $LOG
echo "  audio/   : $(ls $AUDIO_DIR 2>/dev/null | wc -l)" | tee -a $LOG
echo "  耗时    : $((DURATION/60))分$((DURATION%60))秒" | tee -a $LOG
echo "================================" | tee -a $LOG
ok "完成！刷新页面验证"
