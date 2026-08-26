// GitHub 每日备份：把本地主数据 gzip 后推到私有仓库 reading-checkin 的 backup 分支
// 用法: node github-backup.js  （由 crontab 每天 03:30 调用，也可手动跑）
// 恢复方法: 见文件末尾注释
const fs = require('fs');
const https = require('https');
const zlib = require('zlib');
const path = require('path');

const DATA_FILE = '/opt/reading-checkin/data/reading-checkin-data.json';
const TOKEN_FILE = '/opt/reading-checkin/.backup-token';
const REPO = 'yaping2026/reading-checkin';
const BRANCH = 'backup';

// 读 token：环境变量优先，其次 token 文件
let TOKEN = process.env.GITHUB_TOKEN;
if (!TOKEN && fs.existsSync(TOKEN_FILE)) {
  TOKEN = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
}
if (!TOKEN) {
  console.error('[备份失败] 未找到 GITHUB_TOKEN（环境变量或 ' + TOKEN_FILE + '）');
  process.exit(1);
}

function api(method, apiPath, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const req = https.request({
      hostname: 'api.github.com',
      path: '/repos/' + REPO + '/' + apiPath,
      method,
      headers: {
        'Authorization': 'token ' + TOKEN,
        'User-Agent': 'backup-script',
        'Content-Type': 'application/json',
        ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {})
      }
    }, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(d); } catch (e) {}
        resolve({ status: res.statusCode, json: j });
      });
    }).on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function ensureBranch() {
  const r = await api('GET', 'git/ref/heads/' + BRANCH);
  if (r.status === 200) return; // 分支已存在
  // 从 main 创建 backup 分支
  const m = await api('GET', 'git/ref/heads/main');
  if (m.status !== 200) throw new Error('读取main分支失败: ' + m.status);
  const c = await api('POST', 'git/refs', {
    ref: 'refs/heads/' + BRANCH,
    sha: m.json.object.sha
  });
  if (c.status !== 201) throw new Error('创建backup分支失败: ' + c.status + ' ' + JSON.stringify(c.json).slice(0, 150));
  console.log('[初始化] 已创建 backup 分支');
}

async function pushFile(remotePath, content, msg) {
  const r = await api('GET', 'contents/' + remotePath + '?ref=' + BRANCH);
  const sha = (r.status === 200 && r.json && r.json.sha) ? r.json.sha : null;
  const put = await api('PUT', 'contents/' + remotePath, {
    message: msg,
    content: content,
    branch: BRANCH,
    ...(sha ? { sha } : {})
  });
  if (put.status !== 200 && put.status !== 201) {
    throw new Error('推送 ' + remotePath + ' 失败: ' + put.status + ' ' + JSON.stringify(put.json).slice(0, 150));
  }
  return sha ? '覆盖' : '新建';
}

(async () => {
  const t0 = Date.now();
  try {
    // 1. 读数据并验证
    if (!fs.existsSync(DATA_FILE)) throw new Error('数据文件不存在: ' + DATA_FILE);
    const raw = fs.readFileSync(DATA_FILE);
    const data = JSON.parse(raw.toString('utf8')); // 验证完整性，损坏则中止
    const gz = zlib.gzipSync(raw, { level: 9 });
    const b64 = gz.toString('base64');

    console.log('[' + new Date().toLocaleString('zh-CN') + '] 开始备份');
    console.log('数据: ' + raw.length + ' 字节 → gzip ' + gz.length + ' 字节 | 打卡 ' + data.checkins.length + ' 条 | 成员 ' + (data.members || []).length + ' 人');

    // 2. 确保分支存在
    await ensureBranch();

    // 3. 按日期推一份（留历史，每月约3MB）
    const today = new Date().toISOString().slice(0, 10);
    const a1 = await pushFile('backup/data-' + today + '.json.gz', b64, 'backup ' + today + ' (' + data.checkins.length + '条)');
    console.log('按日备份: ' + a1 + ' backup/data-' + today + '.json.gz');

    // 4. 覆盖 latest（恢复时直接拿这个）
    const a2 = await pushFile('backup/data-latest.json.gz', b64, 'backup latest ' + today + ' (' + data.checkins.length + '条)');
    console.log('最新备份: ' + a2 + ' backup/data-latest.json.gz');

    console.log('[' + ((Date.now() - t0) / 1000).toFixed(1) + 's] ✅ 备份完成');
    process.exit(0);
  } catch (e) {
    console.error('[' + new Date().toLocaleString('zh-CN') + '] ❌ 备份失败:', e.message);
    process.exit(1);
  }
})();

// ============ 恢复方法（灾难恢复时用）============
// 1. 重新部署: curl -sL https://gcore.jsdelivr.net/gh/yaping2026/deploy-pkg@main/deploy2.sh | bash
// 2. 拉取备份数据:
//    curl -sL -H "Authorization: token <TOKEN>" \
//      https://raw.githubusercontent.com/yaping2026/reading-checkin/backup/backup/data-latest.json.gz \
//      -o /tmp/data-latest.json.gz
//    gunzip -f /tmp/data-latest.json.gz
//    cp /tmp/data-latest.json /opt/reading-checkin/data/reading-checkin-data.json
// 3. 重启: bash /opt/reading-checkin/start.sh
