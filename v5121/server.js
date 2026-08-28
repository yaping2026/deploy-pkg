const express = require('express');
// ===== 版本标记（修改此行可强制Railway重新部署）=====
const APP_VERSION = '2026-08-28-v5.12.1'; // v5.12季度换组 + 恢复SSL直接监听443（v5.12曾丢失此逻辑导致HTTPS全断）
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const db = require('./db');
const scheduler = require('./scheduler');
const wecom = require('./wecom');
const poster = require('./poster');
const posterSender = require('./poster-sender');

const githubFiles = require('./github-files');
const session = require('express-session');

// ========= Express App 初始化（必须在路由定义之前）=========
const app = express();
const PORT = process.env.PORT || 3001;

// ========= Session 中间件 =========
app.use(session({
  secret: process.env.SESSION_SECRET || 'reading-checkin-session-secret-2026',
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 7 * 24 * 60 * 60 * 1000 }
}));

app.use(express.json({ limit: '10mb' }));

// ========= Session 鉴权中间件函数 =========
function requireAdmin(req, res, next) {
  if (req.session && req.session.isAdmin) return next();
  if (req.path.startsWith('/api/')) {
    return res.status(401).json({ ok: false, msg: '未登录' });
  }
  res.redirect('/admin/login');
}

// ========= 登录页面 =========
function sendLoginPage(res) {
  res.send(`<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>管理后台登录</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f0ede8;display:flex;align-items:center;justify-content:center;min-height:100vh}
  .login-box{background:#fff;border-radius:16px;padding:40px 36px;width:360px;box-shadow:0 4px 20px rgba(0,0,0,.08)}
  h2{text-align:center;color:#5a4a9a;margin-bottom:28px;font-size:22px}
  .form-group{margin-bottom:18px}
  .form-group label{display:block;margin-bottom:6px;color:#555;font-size:14px;font-weight:500}
  .form-group input{width:100%;padding:10px 14px;border:1px solid #ddd;border-radius:8px;font-size:15px;outline:none;transition:border-color .2s}
  .form-group input:focus{border-color:#5a4a9a}
  .btn{width:100%;background:#5a4a9a;color:#fff;border:none;padding:12px;border-radius:8px;font-size:15px;cursor:pointer;transition:opacity .2s}
  .btn:hover{opacity:.85}
  .error{background:#f8d7da;color:#721c24;padding:10px 14px;border-radius:8px;margin-bottom:14px;font-size:13px;text-align:center}
</style>
</head><body>
<div class="login-box">
  <h2>🔐 管理后台登录</h2>
  <div id="err" class="error" style="display:none"></div>
  <div class="form-group">
    <label>用户名</label>
    <input type="text" id="user" placeholder="请输入用户名" autocomplete="off">
  </div>
  <div class="form-group">
    <label>密码</label>
    <input type="password" id="pass" placeholder="请输入密码" autocomplete="off">
  </div>
  <button class="btn" onclick="doLogin()">登 录</button>
</div>
<script>
async function doLogin(){
  const r=await fetch('/api/admin/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({user:document.getElementById('user').value,pass:document.getElementById('pass').value})});
  const d=await r.json();
  if(d.ok){location.href='/admin/home';}else{document.getElementById('err').style.display='block';document.getElementById('err').textContent=d.msg||'登录失败';}
}
document.getElementById('pass').addEventListener('keydown',e=>{if(e.key==='Enter')doLogin();});
</script>
</body></html>`);
}


// ========= 日志查询 API =========
app.get('/api/logs', requireAdmin, async (req, res) => {
  try {
    const data = await db.read();
    const logs = data._logs || [];
    res.json({ ok: true, logs: logs.slice(0, 50) });
  } catch (e) {
    res.json({ ok: false, msg: e.message });
  }
});

app.get('/api/logs/all', requireAdmin, async (req, res) => {
  try {
    const data = await db.read();
    res.json({ ok: true, logs: data._logs || [] });
  } catch (e) {
    res.json({ ok: false, msg: e.message });
  }
});

// ========= 登录 API =========
app.post('/api/admin/login', express.json({ limit: '1mb' }), (req, res) => {
  const { user, pass } = req.body;
  const ADMIN_USER = process.env.ADMIN_USER || 'admin';
  const ADMIN_PASS = process.env.ADMIN_PASS || 'admin123';
  if (user === ADMIN_USER && pass === ADMIN_PASS) {
    req.session.isAdmin = true;
    res.json({ ok: true });
  } else {
    res.json({ ok: false, msg: '用户名或密码错误' });
  }
});

// ========= 退出 API =========
app.post('/api/admin/logout', (req, res) => {
  req.session.destroy(() => {
    res.json({ ok: true });
  });
});

// ========= 登录状态检查 API =========
app.get('/api/admin/check', (req, res) => {
  res.json({ ok: true, isAdmin: !!(req.session && req.session.isAdmin) });
});

// ========= 数据刷新 API：从GitHub强制拉取最新数据，替换本地缓存 =========
app.post('/api/admin/refresh-data', requireAdmin, async (req, res) => {
  try {
    const fresh = await db.readFresh();
    res.json({ ok: true, msg: '已从GitHub刷新最新数据', sha: fresh.sha });
  } catch (e) {
    res.json({ ok: false, msg: e.message });
  }
});

// ========= 登录页面路由 =========
app.get('/admin/login', (req, res) => {
  if (req.session && req.session.isAdmin) return res.redirect('/admin/home');
  sendLoginPage(res);
});

// ========= 管理后台主页（鉴权后）=========
app.get('/admin/home', requireAdmin, (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// ========= 管理后台根路径：已登录跳 home，未登录跳 login =========
app.get('/admin', (req, res) => {
  if (req.session && req.session.isAdmin) return res.redirect('/admin/home');
  res.redirect('/admin/login');
});
// ========= Session 鉴权结束 =========

// 音频文件GitHub上传辅助函数（带重试，解决并发冲突）
async function uploadAudioToGitHub(filename, buffer, maxRetries = 3) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const results = await githubFiles.uploadFiles([{ filename, buffer }]);
      console.log('[audio] GitHub上传成功:', filename);
      return results[0];
    } catch (e) {
      console.error(`[audio] GitHub上传尝试 ${i + 1}/${maxRetries} 失败:`, e.message);
      if (i < maxRetries - 1) {
        await new Promise(r => setTimeout(r, 1000 * (i + 1)));
      }
    }
  }
  throw new Error('GitHub上传失败，已重试' + maxRetries + '次');
}

// ========= GitHub 音频上传队列（串行执行，避免并发冲突）=========
const githubUploadQueue = [];
let isUploadingToGitHub = false;

async function processGithubUploadQueue() {
  if (isUploadingToGitHub || githubUploadQueue.length === 0) return;
  isUploadingToGitHub = true;
  const { filename, buffer, resolve, reject } = githubUploadQueue.shift();
  try {
    const result = await uploadAudioToGitHub(filename, buffer);
    resolve(result);
  } catch (e) {
    console.error('[audio] 队列上传最终失败:', filename, e.message);
    reject(e);
  } finally {
    isUploadingToGitHub = false;
    // 继续处理队列中的下一个
    setImmediate(processGithubUploadQueue);
  }
}

function queueAudioUpload(filename, buffer) {
  return new Promise((resolve, reject) => {
    githubUploadQueue.push({ filename, buffer, resolve, reject });
    processGithubUploadQueue();
  });
}

// 同步保存音频文件到本地磁盘（确保响应前文件已落盘）
function saveAudioFileSync(audioFileName, buffer) {
  try {
    const audioDir = path.join(__dirname, 'uploads', 'audio');
    if (!fs.existsSync(audioDir)) fs.mkdirSync(audioDir, { recursive: true });
    const audioPath = path.join(audioDir, audioFileName);
    fs.writeFileSync(audioPath, buffer);
    console.log('[audio] 文件已同步保存:', audioFileName, 'size=' + buffer.length);
    return true;
  } catch (e) {
    console.error('[audio] 同步保存文件失败:', e.message);
    return false;
  }
}

// 内存级防重复打卡缓存（解决 GitHub API 写入延迟导致的并发重复问题）
const recentCheckins = new Map(); // key: `${memberId}-${date}` => true
const recentMakeups = new Map();  // key: `${memberId}-${date}-makeup` => true

// ========= 鉴权中间件（必须在 static 之前）=========
const PUBLIC_PATHS = ['/admin/login', '/api/admin/login', '/api/admin/logout', '/api/admin/check'];
// 打卡页面需要访问的接口（不需要登录管理后台）
const USER_FACING = [
  '/api/checkin', '/api/with-audio', '/api/checkin/stats',
  '/api/members', '/api/groups', '/api/groups/',
  '/api/content/today', '/api/date-content',
  '/api/checkins/today/', '/api/checkins/stats/', '/api/checkins/makeup-status/',
  '/api/poster/send',
  '/api/poster/resend/',
  '/api/audio/info/', '/api/audio/play/'
];
app.use((req, res, next) => {
  const p = req.path;
  if (PUBLIC_PATHS.includes(p)) return next();
  if (p === '/admin' || p === '/admin/home') return requireAdmin(req, res, next);
  if (p.startsWith('/api/')) {
    const isUserFacing = USER_FACING.some(prefix => p.startsWith(prefix));
    if (!isUserFacing) return requireAdmin(req, res, next);
  }
  next();
});
// ========= 鉴权结束 =========

// 动态提供 admin.html（绕过Railway静态文件缓存问题）
app.get('/admin.html', (req, res) => {
  const adminPath = path.join(__dirname, 'public', 'admin.html');
  if (fs.existsSync(adminPath)) {
    const html = fs.readFileSync(adminPath, 'utf8');
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    return res.send(html);
  }
  const rootPath = path.join(__dirname, 'admin.html');
  if (fs.existsSync(rootPath)) {
    const html = fs.readFileSync(rootPath, 'utf8');
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    return res.send(html);
  }
  res.status(404).send('admin.html not found');
});
app.use(express.static(path.join(__dirname, 'public'), {
  setHeaders: (res, path) => {
    if (path.endsWith('.html')) {
      res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
      res.setHeader('Pragma', 'no-cache');
      res.setHeader('Expires', '0');
    }
  }
}));

// Multer 内存存储（文件直接上传到 GitHub）
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 20 * 1024 * 1024 } });

// ========= 打卡页面 =========
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'checkin.html'));
});

app.get('/admin', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// ========= API: 群组管理 =========
app.get('/api/groups', async (req, res) => {
  const data = await db.read();
  const groups = data.groups.map(g => ({
    ...g,
    memberCount: data.members.filter(m => m.groupId === g.id).length
  }));
  res.json({ ok: true, groups });
});

app.post('/api/groups', async (req, res) => {
  const { data } = await db.readFresh();
  const { name, webhookUrl } = req.body;
  if (!name || !webhookUrl) return res.status(400).json({ ok: false, msg: '缺少参数' });
  const group = { id: data.nextGroupId++, name: name, webhookUrl: webhookUrl };
  data.groups.push(group);
  await db.write(data);
  res.json({ ok: true, group });
});

app.delete('/api/groups/:id', async (req, res) => {
  const { data } = await db.readFresh();
  data.groups = data.groups.filter(g => g.id !== parseInt(req.params.id));
  data.members = data.members.filter(m => m.groupId !== parseInt(req.params.id));
  await db.write(data);
  res.json({ ok: true });
});

// ========= API: 成员管理 =========
app.get('/api/groups/:groupId/members', async (req, res) => {
  const data = await db.read();
  const members = data.members.filter(m => m.groupId === parseInt(req.params.groupId));
  res.json({ ok: true, members });
});

app.post('/api/groups/:groupId/members', async (req, res) => {
  const { data } = await db.readFresh();
  const groupId = parseInt(req.params.groupId);
  const { names, mobiles, startDates } = req.body;  // startDates可选，默认当天
  if (!names || !Array.isArray(names)) return res.status(400).json({ ok: false, msg: '缺少names数组' });
  const added = [];
  for (let i = 0; i < names.length; i++) {
    const trimmed = (names[i] || '').trim();
    if (!trimmed) continue;
    const member = {
      id: data.nextMemberId++,
      name: trimmed,
      groupId: groupId,
      mobile: (mobiles && mobiles[i]) ? mobiles[i].trim() : '',
      startDate: (startDates && startDates[i]) || new Date().toISOString().split('T')[0]
    };
    data.members.push(member);
    added.push(member);
  }
  await db.write(data);
  res.json({ ok: true, added });
});

app.delete('/api/members/:id', async (req, res) => {
  const { data } = await db.readFresh();
  data.members = data.members.filter(m => m.id !== parseInt(req.params.id));
  await db.write(data);
  res.json({ ok: true });
});

// 更新成员手机号（用于企微@提醒）
app.put('/api/members/:id/mobile', async (req, res) => {
  const { data } = await db.readFresh();
  const member = data.members.find(m => m.id === parseInt(req.params.id));
  if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });
  const { mobile } = req.body;
  member.mobile = mobile ? mobile.trim() : '';
  await db.write(data);
  res.json({ ok: true, member });
});

// 更新成员信息（姓名+手机号+开始日期）
app.put('/api/members/:id', async (req, res) => {
  const { data } = await db.readFresh();
  const member = data.members.find(m => m.id === parseInt(req.params.id));
  if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });
  const { name, mobile, startDate } = req.body;
  if (name !== undefined && name.trim()) member.name = name.trim();
  if (mobile !== undefined) member.mobile = mobile ? mobile.trim() : '';
  if (startDate !== undefined && startDate) member.startDate = startDate;
  await db.write(data);
  res.json({ ok: true, member });
});

// ========= API: 季度批量换组（每3个月抽签换组用）=========
// moves: [{memberId, newGroupId}]  effectiveDate: 生效日期（建议季度首月1号）
// 换组只挪人不删组不删人（ID/pin/userid不变，打卡身份无缝衔接），自动写入组历史并备份换组前名单
app.post('/api/regroup', requireAdmin, async (req, res) => {
  try {
    const { moves, effectiveDate } = req.body;
    if (!Array.isArray(moves) || moves.length === 0) {
      return res.status(400).json({ ok: false, msg: '缺少moves数组（格式：[{memberId, newGroupId}]）' });
    }
    const eff = effectiveDate || scheduler.getTodayStr();

    const { data } = await db.readFresh();

    // 换组前名单快照备份（保留最近5次，便于人工恢复）
    if (!Array.isArray(data._regroupBackups)) data._regroupBackups = [];
    data._regroupBackups.push({
      time: new Date().toISOString(),
      effectiveDate: eff,
      members: data.members.map(m => ({ id: m.id, name: m.name, groupId: m.groupId }))
    });
    if (data._regroupBackups.length > 5) data._regroupBackups.shift();

    const results = [];
    for (const mv of moves) {
      const member = data.members.find(m => m.id === parseInt(mv.memberId));
      if (!member) { results.push({ memberId: mv.memberId, ok: false, msg: '成员不存在' }); continue; }
      const newGroup = data.groups.find(g => g.id === parseInt(mv.newGroupId));
      if (!newGroup) { results.push({ memberId: mv.memberId, name: member.name, ok: false, msg: '目标组不存在' }); continue; }
      const oldGroupId = member.groupId;
      if (oldGroupId === newGroup.id) { results.push({ memberId: mv.memberId, name: member.name, ok: true, skipped: true }); continue; }

      // 组历史：老成员没有groupHistory的，先回填当前组
      if (!Array.isArray(member.groupHistory)) member.groupHistory = [];
      if (member.groupHistory.length === 0) {
        member.groupHistory.push({ groupId: oldGroupId, from: member.startDate || '2026-06-01' });
      }
      // 同一生效日期只保留一条，避免重复换组产生脏历史
      member.groupHistory = member.groupHistory.filter(h => h.from !== eff);
      member.groupHistory.push({ groupId: newGroup.id, from: eff });

      member.groupId = newGroup.id;
      const oldGroup = data.groups.find(g => g.id === oldGroupId);
      results.push({ memberId: mv.memberId, name: member.name, ok: true, from: oldGroup ? oldGroup.name : String(oldGroupId), to: newGroup.name });
    }

    await db.write(data);
    const changed = results.filter(r => r.ok && !r.skipped).length;
    res.json({ ok: true, effectiveDate: eff, changed, results });
  } catch (err) {
    console.error('[regroup] 换组失败:', err.message);
    res.status(500).json({ ok: false, msg: '换组失败: ' + err.message });
  }
});

// ========= API: 打卡 =========
app.get('/api/checkins/today/:groupId', async (req, res) => {
  const data = await db.read();
  const today = scheduler.getTodayStr();
  const groupId = parseInt(req.params.groupId);
  const members = data.members.filter(m => m.groupId === groupId);
  const todayCheckins = data.checkins.filter(c => c.date === today && members.some(m => m.id === c.memberId));

  const result = members.map(m => {
    const ci = todayCheckins.find(c => c.memberId === m.id);
    return {
      ...m,
      checked: !!ci,
      checkinType: ci ? (ci.type || 'normal') : null
    };
  });

  const checked = result.filter(m => m.checked);
  const unchecked = result.filter(m => !m.checked);
  const rate = result.length > 0 ? Math.round(checked.length / result.length * 100) : 0;

  res.json({
    ok: true,
    date: today,
    weekday: scheduler.getWeekdayName(),
    total: result.length,
    checkedCount: checked.length,
    uncheckedCount: unchecked.length,
    rate: rate,
    members: result,
    todayCheckins: todayCheckins  // 今天的打卡记录（供客户端生成海报二维码）
  });
});

app.post('/api/checkins', async (req, res) => {
  const today = scheduler.getTodayStr();
  const { memberId } = req.body;
  if (!memberId) return res.status(400).json({ ok: false, msg: '缺少memberId' });

  // =============================================================
  // 核心修复：用readFresh+writeWithData替代read+write，防止并发覆盖
  // =============================================================
  let lastError = null;
  for (let retry = 0; retry < 3; retry++) {
    if (retry > 0) {
      console.log('[quick-checkin] SHA冲突，重试 ' + retry + '/3，memberId=' + memberId);
      await new Promise(r => setTimeout(r, 200 * retry));
    }

    const fresh = await db.readFresh();
    if (!fresh || !fresh.data) {
      return res.status(500).json({ ok: false, msg: '读取数据失败，请重试' });
    }
    const data = fresh.data;
    const sha = fresh.sha;

    const member = data.members.find(m => m.id === memberId);
    if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

    const cacheKey = memberId + '-' + today;
    const existing = data.checkins.find(c => c.memberId === memberId && c.date === today);
    if (existing || recentCheckins.has(cacheKey)) {
      return res.json({ ok: true, msg: '今日已打卡', duplicate: true, checkin: existing || null });
    }
    recentCheckins.set(cacheKey, true);

    const checkin = {
      id: data.nextCheckinId++,
      memberId: memberId,
      groupId: member.groupId,
      date: today,
      time: new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }),
      type: 'normal'
    };
    data.checkins.push(checkin);

    const groupMembers = data.members.filter(m => m.groupId === member.groupId);
    const todayChecked = data.checkins.filter(c => c.date === today && groupMembers.some(m => m.id === c.memberId));
    const rank = todayChecked.length;
    const total = groupMembers.length;

    // 用 writeWithData 带SHA写入，冲突时重试
    try {
      await db.writeWithData(data, sha);
      db.updateCache(data); // 更新内存缓存

      // 响应客户端
      res.json({ ok: true, checkin: checkin, rank: rank, total: total });

      // 向群内发送打卡通知
      try {
        const group = data.groups.find(g => g.id === member.groupId);
        if (group && group.webhookUrl) {
          const msg = '🌈📖✨ 恭喜' + member.name + '完成今日读书打卡！\n你是本组今日第' + rank + '位打卡的伙伴，当前本组打卡进度：' + rank + '/' + total + '\n以书为伴，共赴成长，感谢你的坚持与付出！';
          wecom.sendText(group.webhookUrl, msg).catch(err => {
            console.error('打卡通知发送失败:', err.message);
          });
        }
      } catch (e) {
        console.error('打卡通知异常:', e.message);
      }
      return; // 成功，退出
    } catch (e) {
      if (e && e.message && e.message.includes('SHA_CONFLICT') && retry < 2) {
        lastError = e;
        continue; // 重试
      }
      // 非SHA错误，直接报错
      if (!res.headersSent) {
        return res.status(500).json({ ok: false, msg: '打卡失败: ' + e.message });
      }
    }
  }
  // 3次重试都失败了
  if (!res.headersSent) {
    return res.status(500).json({ ok: false, msg: '系统繁忙，请稍后重试' });
  }
});

// ========= API: 补打卡 =========
// 获取补打卡状态
app.get('/api/checkins/makeup-status/:memberId', async (req, res) => {
  const data = await db.read();
  const memberId = parseInt(req.params.memberId);
  const member = data.members.find(m => m.id === memberId);
  if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

  const today = scheduler.getTodayStr();
  const yesterday = scheduler.getYesterdayStr();
  const currentMonth = today.substring(0, 7); // "2026-06"

  // 本月补打卡使用情况（统一为makeup类型，每月最多2次）
  const monthStart = currentMonth + '-01';
  const monthCheckins = data.checkins.filter(c =>
    c.memberId === memberId && c.date >= monthStart && c.date <= today
  );

  const makeupUsed = monthCheckins.filter(c => c.type === 'makeup').length;
  const makeupRemaining = Math.max(0, 2 - makeupUsed);

  // 昨日是否已打卡（正常或补打卡都算）
  const yesterdayCheckin = data.checkins.find(c => c.memberId === memberId && c.date === yesterday);

  // 是否可以补打卡（次日23:59前 = 今天全天都可以补昨天）
  const canMakeupYesterday = !yesterdayCheckin;

  res.json({
    ok: true,
    month: currentMonth,
    yesterday: yesterday,
    yesterdayChecked: !!yesterdayCheckin,
    canMakeupYesterday: canMakeupYesterday && makeupRemaining > 0,
    makeupUsed: makeupUsed,
    makeupRemaining: makeupRemaining,
    maxPerMonth: 2
  });
});

// 执行补打卡（通过录音打卡接口 /api/checkins/with-audio 传入 makeupDate 参数）
// 保留此接口用于兼容，但前端不再直接调用
app.post('/api/checkins/makeup', async (req, res) => {
  const { data } = await db.readFresh();
  const { memberId } = req.body;

  if (!memberId) return res.status(400).json({ ok: false, msg: '缺少参数' });

  const member = data.members.find(m => m.id === memberId);
  if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

  const today = scheduler.getTodayStr();
  const yesterday = scheduler.getYesterdayStr();
  const currentMonth = today.substring(0, 7);

  // 验证1：只能补昨天
  if (yesterday < currentMonth + '-01') {
    return res.status(400).json({ ok: false, msg: '只能补本月内的打卡' });
  }

  // 验证2：昨天是否已经打过卡
  const existingCheckin = data.checkins.find(c => c.memberId === memberId && c.date === yesterday);
  if (existingCheckin) {
    return res.json({ ok: false, msg: '昨日已有打卡记录，无需补打卡' });
  }

  // 验证3：本月补打卡次数（统一2次）
  const monthStart = currentMonth + '-01';
  const monthCheckins = data.checkins.filter(c =>
    c.memberId === memberId && c.date >= monthStart && c.date <= today
  );
  const makeupUsed = monthCheckins.filter(c => c.type === 'makeup').length;
  if (makeupUsed >= 2) {
    return res.status(400).json({ ok: false, msg: '本月补打卡机会已用完（2次/月）' });
  }

  // 内存防重复
  const cacheKey = memberId + '-' + yesterday + '-makeup';
  if (recentMakeups.has(cacheKey)) {
    return res.json({ ok: true, msg: '已补打卡', duplicate: true });
  }
  recentMakeups.set(cacheKey, true);

  // 创建补打卡记录
  const checkin = {
    id: data.nextCheckinId++,
    memberId: memberId,
    groupId: member.groupId,
    date: yesterday,
    time: new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }),
    type: 'makeup',
    hasAudio: false
  };
  data.checkins.push(checkin);

  // 先更新缓存+响应，再异步写入
  db.updateCache(data);
  res.json({
    ok: true,
    checkin: checkin,
    makeupRemaining: Math.max(0, 2 - makeupUsed - 1)
  });
  db.write(data).catch(e => console.error('[db] write error:', e.message));

  // 向群内发送补打卡通知
  try {
    const group = data.groups.find(g => g.id === member.groupId);
    if (group && group.webhookUrl) {
      const msg = '🌈📖✨ 恭喜' + member.name + ' 补打卡成功（' + yesterday + '）！\n本月剩余补打卡机会：' + Math.max(0, 2 - makeupUsed - 1) + '次\n以书为伴，共赴成长，感谢你的坚持与付出！';
      wecom.sendText(group.webhookUrl, msg).catch(err => {
        console.error('补打卡通知发送失败:', err.message);
      });
    }
  } catch (e) {
    console.error('补打卡通知异常:', e.message);
  }
});

// ========= API: 批量上传每日内容 =========
app.post('/api/content/upload', upload.array('files', 100), async (req, res) => {
  const uploaded = [];
  const errors = [];

  if (req.files && req.files.length > 0) {
    const filesToUpload = [];
    for (const file of req.files) {
      const match = file.originalname.match(/^(\d{8})([AB])\.(pdf|jpg|jpeg|png)$/i);
      if (!match) {
        errors.push(file.originalname + ' 文件名格式不正确，应为：20260610A.pdf 或 20260610B.jpg');
        continue;
      }
      filesToUpload.push({
        filename: file.originalname,
        buffer: file.buffer
      });
    }

    if (filesToUpload.length > 0) {
      try {
        const results = await githubFiles.uploadFiles(filesToUpload);
        for (const r of results) {
          const match = r.filename.match(/^(\d{8})([AB])\.(pdf|jpg|jpeg|png)$/i);
          uploaded.push({
            filename: r.filename,
            date: match[1],
            type: match[2].toUpperCase(),
            url: r.url
          });
        }
      } catch (e) {
        errors.push('GitHub上传失败: ' + e.message);
      }
    }
  }

  res.json({ ok: true, uploaded, errors });
});

// 列出已上传的内容文件
app.get('/api/content', async (req, res) => {
  const files = await githubFiles.listFiles();
  const dateMap = {};
  for (const f of files) {
    const match = f.match(/^(\d{8})([AB])\.(pdf|jpg|jpeg|png)$/i);
    if (match) {
      const date = match[1];
      const type = match[2].toUpperCase();
      if (!dateMap[date]) dateMap[date] = {};
      dateMap[date][type] = githubFiles.getFileUrl(f);
    }
  }
  const contents = [];
  for (const date of Object.keys(dateMap).sort()) {
    contents.push({
      date,
      pdfUrl: dateMap[date].A,
      jpgUrl: dateMap[date].B
    });
  }
  res.json({ ok: true, contents });
});

// 删除内容文件
app.delete('/api/content/:date', async (req, res) => {
  try {
    const date = req.params.date;
    const files = (await githubFiles.listFiles()).filter(f => f.startsWith(date));
    if (files.length > 0) {
      await githubFiles.deleteFiles(files);
    }
    res.json({ ok: true });
  } catch (e) {
    console.error('[delete content] 错误:', e.message);
    res.json({ ok: false, msg: e.message });
  }
});

// 批量删除内容文件（一次GitHub commit删除所有文件，避免422错误）
app.post('/api/content/batch-delete', async (req, res) => {
  try {
    const { dates } = req.body;
    if (!Array.isArray(dates) || dates.length === 0) {
      return res.json({ ok: false, msg: '缺少dates参数' });
    }

    // 收集所有需要删除的文件
    const allFiles = await githubFiles.listFiles();
    const toDelete = [];
    for (const date of dates) {
      const files = allFiles.filter(f => f.startsWith(date));
      toDelete.push(...files);
    }

    if (toDelete.length === 0) {
      return res.json({ ok: true, results: { success: dates, failed: [] } });
    }

    // 一次GitHub commit删除所有文件（避免多次updateRef导致422）
    await githubFiles.deleteFiles(toDelete);

    res.json({ ok: true, results: { success: dates, failed: [] } });
  } catch (e) {
    console.error('[batch-delete] 错误:', e.message);
    res.json({ ok: false, msg: e.message });
  }
});

// 获取今日内容
app.get('/api/content/today', async (req, res) => {
  const today = scheduler.getTodayStr().replace(/-/g, '');
  const result = { date: scheduler.getTodayStr(), pdfUrl: null, jpgUrl: null };

  const files = await githubFiles.listFiles();
  const pdf = files.find(f => f.match(new RegExp('^' + today + 'A\\.pdf$', 'i')));
  const jpg = files.find(f => f.match(new RegExp('^' + today + 'B\\.(jpg|jpeg|png)$', 'i')));

  if (pdf) result.pdfUrl = githubFiles.getFileUrl(pdf);
  if (jpg) result.jpgUrl = githubFiles.getFileUrl(jpg);

  res.json({ ok: true, ...result });
});

// 获取指定日期的读书内容
app.get('/api/date-content', async (req, res) => {
  try {
    const date = req.query.date; // YYYYMMDD格式
    if (!date || !/^\d{8}$/.test(date)) {
      return res.status(400).json({ ok: false, msg: '日期格式错误，需要YYYYMMDD' });
    }

    const files = await githubFiles.listFiles();
    const pdf = files.find(f => f.match(new RegExp('^' + date + 'A\\.pdf$', 'i')));
    const img = files.find(f => f.match(new RegExp('^' + date + 'B\\.(jpg|jpeg|png)$', 'i')));

    res.json({
      ok: true,
      date: date,
      imgFile: img || null,
      imgUrl: img ? githubFiles.getFileUrl(img) : null,
      pdfFile: pdf || null,
      pdfUrl: pdf ? githubFiles.getFileUrl(pdf) : null
    });
  } catch (e) {
    console.error('[date-content] 错误:', e.message);
    res.json({ ok: false, imgFile: null, imgUrl: null, pdfFile: null, pdfUrl: null });
  }
});

// ========= 报表数据生成（共享函数） =========
// 按日期查成员当时所在的组（季度换组后，历史报表仍按"当时的组"统计，数据不乱）
// 组历史为空的老成员：视为一直在当前组（从startDate起）
function getGroupAt(member, date) {
  const hist = (Array.isArray(member.groupHistory) && member.groupHistory.length > 0)
    ? member.groupHistory
    : [{ groupId: member.groupId, from: member.startDate || '2000-01-01' }];
  let gid = hist[0].groupId;
  for (const h of hist) {
    if (h.from <= date) gid = h.groupId;
  }
  return gid;
}

async function generateReportData(startDate, endDate, groupId) {
  // 使用readFresh确保报表数据是最新的（避免多实例缓存不一致）
  const { data } = await db.readFresh();

  if (!startDate || !endDate) {
    throw new Error('请提供日期范围');
  }

  const today = scheduler.getTodayStr();
  // 结束日期不能超过今天
  const effectiveEnd = endDate > today ? today : endDate;

  const dates = [];
  let d = new Date(startDate);
  const endD = new Date(effectiveEnd);
  while (d <= endD) {
    dates.push(d.toISOString().split('T')[0]);
    d.setDate(d.getDate() + 1);
  }

  const targetGroups = groupId
    ? data.groups.filter(g => g.id === parseInt(groupId))
    : data.groups;

  // 按中文数字“一组/二组/...”排序
  const cnNums = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10 };
  function getGroupNumber(name) {
    const m = (name || '').match(/([一二三四五六七八九十])\s*组/);
    return m ? (cnNums[m[1]] || 0) : 0;
  }
  targetGroups.sort((a, b) => getGroupNumber(a.name) - getGroupNumber(b.name));

  const result = [];

  for (const group of targetGroups) {
    // 季度换组兼容：按报表开始日期时成员所在的组归组（查历史月份，人还在当时的组）
    const members = data.members.filter(m => getGroupAt(m, startDate) === group.id);
    const groupCheckins = data.checkins.filter(c =>
      c.date >= startDate && c.date <= endDate && members.some(m => m.id === c.memberId)
    );

    const memberStats = members.map(member => {
      // 成员加入日期（没有startDate的旧成员默认为报表开始日期，不影响历史数据）
      const memberStart = member.startDate || startDate;
      
      const memberCheckins = groupCheckins.filter(c => c.memberId === member.id);
      
      const dailyStatus = {};
      for (const date of dates) {
        if (date < memberStart) {
          // 加入前的日期：显示"—"，不计入任何统计
          dailyStatus[date] = '—';
        } else {
          const ci = memberCheckins.find(c => c.date === date);
          if (ci) {
            if (ci.type === 'makeup' || ci.type === 'makeup-read' || ci.type === 'makeup-checkin') dailyStatus[date] = '补打卡';
            else dailyStatus[date] = '✓';
          } else {
            dailyStatus[date] = date > today ? '' : '✗';
          }
        }
      }

      const makeupUsed = memberCheckins.filter(c => c.type === 'makeup' || c.type === 'makeup-read' || c.type === 'makeup-checkin').length;
      // 非makeup类型都算正常打卡（防御type为undefined等异常情况）
      const normalCount = memberCheckins.filter(c => c.type !== 'makeup' && c.type !== 'makeup-read' && c.type !== 'makeup-checkin').length;
      const totalCount = memberCheckins.length;

      // 累计未打卡天数（只统计加入后的✗）
      const totalMissed = dates.filter(dd => dd >= memberStart && dd <= today && dailyStatus[dd] === '✗').length;

      // 有效天数 = 今天 - 加入日期 + 1（加入前的天数不计入分母）
      const eligibleDays = dates.filter(dd => dd >= memberStart && dd <= today).length;
      
      // 该成员在报表期间未加入（startDate晚于报表结束日期），不纳入统计
      if (eligibleDays === 0) {
        return {
          id: member.id,
          name: member.name,
          dailyStatus,
          normalCount: 0,
          makeupUsed: 0,
          totalCount: 0,
          rate: null,
          excluded: true,
          totalMissed: 0,
          alertLevel: 0,
          alertReason: [],
          qualified: true
        };
      }
      
      const rate = Math.round((normalCount + makeupUsed) / eligibleDays * 100);

      // === 按考核标准判断预警 ===
      // 规则：同一人累计2次未打卡，整组才不达标
      // 补卡只能补昨天，昨天之前的✗是永久性缺卡
      const yesterday = scheduler.getYesterdayStr();
      const remainingMakeup = 2 - makeupUsed; // 剩余补卡券
      // 永久性✗：只统计加入后的、昨天之前的✗
      const permanentMisses = dates.filter(dd => dd >= memberStart && dd < yesterday && dailyStatus[dd] === '✗').length;
      const fixableMisses = (memberStart <= yesterday && dailyStatus[yesterday] === '✗') ? 1 : 0;

      // 判断不可补救的缺卡数（永久性✗ + 补卡券不够补的✗）
      let unfixableMisses = permanentMisses;
      if (fixableMisses > 0) {
        const canFixYesterday = remainingMakeup > permanentMisses; // 减去补永久性缺卡后还有余券补昨天
        if (!canFixYesterday) unfixableMisses += fixableMisses;
      }
      // 补卡券用完后的缺卡也算不可补救
      if (remainingMakeup <= 0 && totalMissed > 0) {
        unfixableMisses = totalMissed; // 没券了，所有✗都不可补
      }

      // alertLevel: 0=正常, 1=风险(有✗但还能补救), 2=不达标(不可补救缺卡>=2)
      let alertLevel = 0;
      let alertReason = [];
      let qualified = true;

      if (totalMissed === 0) {
        alertLevel = 0;
      } else if (unfixableMisses >= 2) {
        // 不可补救缺卡>=2 → 不达标
        alertLevel = 2;
        alertReason.push('缺卡' + totalMissed + '次（不可补救' + unfixableMisses + '次）');
        qualified = false;
      } else if (unfixableMisses === 1 && remainingMakeup <= 0) {
        // 只有1天不可补救，但没补卡券了 → 这1天永远无法消除 → 不达标
        alertLevel = 2;
        alertReason.push('缺卡' + totalMissed + '次（不可补救' + unfixableMisses + '次，补卡券已用完）');
        qualified = false;
      } else if (unfixableMisses >= 1) {
        // 有1天不可补救缺卡，但还有补卡券可以补救其他 → 风险
        alertLevel = 1;
        alertReason.push('缺卡' + totalMissed + '次（其中' + unfixableMisses + '次已过补卡期限），剩余补卡券' + remainingMakeup + '张');
      } else {
        // 全部缺卡都还能补救 → 风险
        alertLevel = 1;
        alertReason.push('缺卡' + totalMissed + '次，剩余补卡券' + remainingMakeup + '张');
      }

      return {
        id: member.id,
        name: member.name,
        dailyStatus,
        normalCount,
        makeupUsed,
        totalCount,
        rate,
        excluded: false,
        totalMissed,
        alertLevel,
        alertReason,
        qualified
      };
    });

    // 团队连坐：一人不达标 → 整组无奖品
    const groupFailed = memberStats.some(m => !m.qualified);
    const failedMembers = memberStats.filter(m => !m.qualified).map(m => m.name);

    result.push({
      groupId: group.id,
      groupName: group.name,
      dates,
      members: memberStats,
      groupFailed,
      failedMembers
    });
  }

  return { startDate, endDate: effectiveEnd, reports: result };
}

// ========= API: 日报表（支持日期范围） =========
app.get('/api/report/monthly', async (req, res) => {
  try {
    const { startDate, endDate, groupId } = req.query;
    const result = await generateReportData(startDate, endDate, groupId);
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

// ========= API: 发送预警通知 =========
app.post('/api/report/send-alert', async (req, res) => {
  try {
    const { startDate, endDate, groupId } = req.body;
    if (!startDate || !endDate) {
      return res.status(400).json({ ok: false, msg: '请提供日期范围' });
    }
    const reportData = await generateReportData(startDate, endDate, groupId);
    const { data } = await db.readFresh();

    let sentCount = 0;
    const errors = [];

    for (const report of reportData.reports) {
      const alertMembers = report.members.filter(m => m.alertLevel > 0);
      if (alertMembers.length === 0) continue;

      // 格式化预警消息
      let msg = '📊 打卡考核预警（' + startDate + ' ~ ' + reportData.endDate + '）\n\n';
      msg += '【' + report.groupName + '】\n\n';

      // 团队连坐提醒
      if (report.groupFailed) {
        msg += '🚫 本组有人考核不达标，整组本月无法获得奖品！\n\n';
      }

      const failed = alertMembers.filter(m => m.alertLevel === 2);
      const risk = alertMembers.filter(m => m.alertLevel === 1);

      if (failed.length > 0) {
        msg += '🔴 不达标（无法再补救）：\n';
        for (const m of failed) {
          msg += '• ' + m.name + '：' + m.alertReason.join('，') + '\n';
        }
        msg += '\n';
      }

      if (risk.length > 0) {
        msg += '⚠️ 风险（尚可补救）：\n';
        for (const m of risk) {
          msg += '• ' + m.name + '：' + m.alertReason.join('，') + '\n';
        }
        msg += '\n';
      }

      // 规则提醒（2026-06-30简化版）
      msg += '📌 规则提醒：每人每月2次补卡机会，补卡需在次日24点前完成。一人不达标，整组无奖品！';

      // 发送到对应群组
      const group = data.groups.find(g => g.id === report.groupId);
      if (group && group.webhookUrl) {
        try {
          await wecom.sendText(group.webhookUrl, msg);
          sentCount++;
        } catch (e) {
          errors.push(group.name + '：' + e.message);
        }
      }
    }

    res.json({ ok: true, sentCount, errors: errors.length > 0 ? errors : undefined });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

// ========= API: 管理员批量修改打卡数据 =========
// 一次readFresh→改全部→一次writeWithData，彻底解决多实例并发覆盖问题
app.put('/api/checkins/admin-batch-update', async (req, res) => {
  const { changes } = req.body;
  // changes: [{memberId, date, action}]  action: 'add-normal' | 'add-makeup' | 'delete'

  if (!Array.isArray(changes) || changes.length === 0) {
    return res.status(400).json({ ok: false, msg: '缺少changes参数' });
  }

  // 校验所有action
  for (const c of changes) {
    if (!c.memberId || !c.date || !c.action) {
      return res.status(400).json({ ok: false, msg: '每条修改必须包含memberId, date, action' });
    }
    if (!['add-normal', 'add-makeup', 'delete'].includes(c.action)) {
      return res.status(400).json({ ok: false, msg: '无效的action: ' + c.action });
    }
  }

  // 最多重试5次
  for (let retry = 0; retry < 5; retry++) {
    try {
      const { data: dataRef, sha } = await db.readFresh();

      const results = [];
      for (const change of changes) {
        const { memberId, date, action } = change;
        const member = dataRef.members.find(m => m.id === memberId);
        if (!member) {
          results.push({ memberId, date, action, ok: false, msg: '成员不存在' });
          continue;
        }

        // 补打卡次数限制：每月最多2次（统计整月）
        if (action === 'add-makeup') {
          const monthPrefix = date.substring(0, 7); // e.g. '2026-06'
          const existingMakeup = dataRef.checkins.filter(c =>
            c.memberId === memberId &&
            (c.type === 'makeup' || c.type === 'makeup-read' || c.type === 'makeup-checkin') &&
            c.date.startsWith(monthPrefix) &&
            c.date !== date // 排除当天（当天可能是要修改的已有记录）
          );
          if (existingMakeup.length >= 2) {
            results.push({ memberId, date, action, ok: false, msg: member.name + '本月补打卡已用完（2次/月）' });
            continue;
          }
        }

        if (action === 'delete') {
          const idx = dataRef.checkins.findIndex(c => c.memberId === memberId && c.date === date);
          if (idx === -1) {
            results.push({ memberId, date, action, ok: false, msg: '该日期无打卡记录' });
            continue;
          }
          const removed = dataRef.checkins.splice(idx, 1)[0];
          // 清除内存防重复标记，允许该成员重新打卡
          recentCheckins.delete(memberId + '-' + date);
          recentCheckins.delete(memberId + '-' + date + '-audio');
          recentMakeups.delete(memberId + '-' + date + '-makeup');
          results.push({ memberId, date, action, ok: true, msg: '已删除' + member.name + date + '的记录', detail: removed.type });
          continue;
        }

        const typeMap = { 'add-normal': 'normal', 'add-makeup': 'makeup' };
        const existing = dataRef.checkins.find(c => c.memberId === memberId && c.date === date);
        if (existing) {
          const oldType = existing.type;
          existing.type = typeMap[action];
          existing.time = new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }) + '（管理员修改）';
          results.push({ memberId, date, action, ok: true, msg: '已修改' + member.name + date, detail: oldType + '→' + existing.type });
        } else {
          const checkin = {
            id: dataRef.nextCheckinId++,
            memberId: memberId,
            groupId: member.groupId,
            date: date,
            time: new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }) + '（管理员添加）',
            type: typeMap[action]
          };
          dataRef.checkins.push(checkin);
          results.push({ memberId, date, action, ok: true, msg: '已为' + member.name + '添加' + date, detail: typeMap[action] });
        }
      }

      // 一次性写入所有修改
      await db.writeWithData(dataRef, sha);
      console.log('[admin-batch] 批量修改完成：' + results.filter(r => r.ok).length + '/' + changes.length + '成功 sha=' + sha);
      return res.json({ ok: true, results: results });

    } catch (e) {
      if (e.message && e.message.includes('SHA_CONFLICT') && retry < 4) {
        console.log('[admin-batch] SHA冲突，第' + (retry + 1) + '次重试...');
        await new Promise(r => setTimeout(r, 500 * (retry + 1)));
        continue;
      }
      console.error('[admin-batch] 批量修改失败:', e.message);
      return res.status(500).json({ ok: false, msg: '保存失败，请刷新页面后重试：' + e.message });
    }
  }
  return res.status(500).json({ ok: false, msg: '多次重试仍失败，请稍后再试' });
});

// ========= API: 管理员单个修改打卡数据 =========
// 保留兼容，但前端已改用批量接口
app.put('/api/checkins/admin-update', async (req, res) => {
  const { memberId, date, action } = req.body;
  // action: 'add-normal' | 'add-makeup' | 'delete'

  if (!memberId || !date || !action) {
    return res.status(400).json({ ok: false, msg: '缺少参数（memberId, date, action）' });
  }
  if (!['add-normal', 'add-makeup', 'delete'].includes(action)) {
    return res.status(400).json({ ok: false, msg: '无效的action，可选：add-normal, add-makeup, delete' });
  }

  // 最多重试5次（应对多实例并发导致的SHA冲突）
  for (let retry = 0; retry < 5; retry++) {
    try {
      // readFresh返回 { data, sha } —— sha是读取时的精确版本号
      const { data: dataRef, sha } = await db.readFresh();
      const member = dataRef.members.find(m => m.id === memberId);
      if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

      // 补打卡次数限制：每月最多2次（统计整月）
      if (action === 'add-makeup') {
        const monthPrefix = date.substring(0, 7); // e.g. '2026-06'
        const existingMakeup = dataRef.checkins.filter(c =>
          c.memberId === memberId &&
          (c.type === 'makeup' || c.type === 'makeup-read' || c.type === 'makeup-checkin') &&
          c.date.startsWith(monthPrefix) &&
          c.date !== date // 排除当天（当天可能是要修改的已有记录）
        );
        if (existingMakeup.length >= 2) {
          return res.status(400).json({ ok: false, msg: member.name + '本月补打卡已用完（2次/月），无法再添加补打卡记录' });
        }
      }

      if (action === 'delete') {
        const idx = dataRef.checkins.findIndex(c => c.memberId === memberId && c.date === date);
        if (idx === -1) return res.status(404).json({ ok: false, msg: '该日期无打卡记录' });
        const removed = dataRef.checkins.splice(idx, 1)[0];
        // 清除内存防重复标记，允许该成员重新打卡
        recentCheckins.delete(memberId + '-' + date);
        recentCheckins.delete(memberId + '-' + date + '-audio');
        recentMakeups.delete(memberId + '-' + date + '-makeup');
        // 【关键】使用writeWithData传入读取时获取的sha，确保读写版本一致
        await db.writeWithData(dataRef, sha);
        console.log('[admin] 删除打卡记录：' + member.name + ' ' + date + ' type=' + removed.type + ' sha=' + sha);
        return res.json({ ok: true, msg: '已删除' + member.name + date + '的打卡记录' });
      }

      const typeMap = { 'add-normal': 'normal', 'add-makeup': 'makeup' };

      const existing = dataRef.checkins.find(c => c.memberId === memberId && c.date === date);
      if (existing) {
        const oldType = existing.type;
        existing.type = typeMap[action];
        existing.time = new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }) + '（管理员修改）';
        // 【关键】使用writeWithData传入读取时获取的sha
        await db.writeWithData(dataRef, sha);
        console.log('[admin] 修改打卡记录：' + member.name + ' ' + date + ' ' + oldType + '→' + existing.type + ' sha=' + sha);
        return res.json({ ok: true, msg: '已修改' + member.name + date + '的打卡记录' });
      }

      const checkin = {
        id: dataRef.nextCheckinId++,
        memberId: memberId,
        groupId: member.groupId,
        date: date,
        time: new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }) + '（管理员添加）',
        type: typeMap[action]
      };
      dataRef.checkins.push(checkin);
      // 【关键】使用writeWithData传入读取时获取的sha
      await db.writeWithData(dataRef, sha);
      console.log('[admin] 添加打卡记录：' + member.name + ' ' + date + ' type=' + checkin.type + ' sha=' + sha);
      return res.json({ ok: true, msg: '已为' + member.name + '添加' + date + '的打卡记录' });
    } catch (e) {
      // SHA冲突：其他实例在我们读和写之间更新了数据
      // 重试会重新readFresh（获取最新数据+新sha），基于最新数据重新修改
      if (e.message && e.message.includes('SHA_CONFLICT') && retry < 4) {
        console.log('[admin] SHA冲突（sha不匹配），第' + (retry + 1) + '次重试... 原因: ' + e.message);
        // 等待一小段时间让GitHub的变更传播稳定
        await new Promise(r => setTimeout(r, 500 * (retry + 1)));
        continue;
      }
      console.error('[admin] 修改打卡数据失败:', e.message);
      return res.status(500).json({ ok: false, msg: '保存失败，请刷新页面后重试：' + e.message });
    }
  }
  return res.status(500).json({ ok: false, msg: '多次重试仍失败（系统繁忙），请稍后再试' });
});

// ========= API: 带音频的打卡 =========
// 音频文件使用磁盘存储（避免内存溢出，Railway 512MB内存跑30+并发上传会OOM）
const audioStorage = multer.diskStorage({
  destination: (req, file, cb) => {
    const audioDir = path.join(__dirname, 'uploads', 'audio');
    if (!fs.existsSync(audioDir)) fs.mkdirSync(audioDir, { recursive: true });
    cb(null, audioDir);
  },
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname) || '.mp3';
    cb(null, 'audio_' + Date.now() + '_' + Math.random().toString(36).substr(2, 6) + ext);
  }
});
const audioUpload = multer({ storage: audioStorage, limits: { fileSize: 20 * 1024 * 1024 } });

app.post('/api/checkins/with-audio', (req, res, next) => {
  // 设置60秒超时（Railway默认30秒，录音上传需要更长时间）
  res.setTimeout(60000, () => {
    if (!res.headersSent) {
      res.status(408).json({ ok: false, msg: '上传超时，请稍后重试' });
    }
  });
  next();
}, audioUpload.single('audio'), async (req, res) => {
  try {
    // === 核心并发修复: 保留SHA用于乐观锁 ===
    const fresh = await db.readFresh();
    if (!fresh || !fresh.data) return res.status(500).json({ ok: false, msg: '读取数据失败' });
    let data = fresh.data;
    let writeSha = fresh.sha; // 保存SHA用于后续写入时的乐观锁
    const today = scheduler.getTodayStr();
    const yesterday = scheduler.getYesterdayStr();
    const memberId = parseInt(req.body.memberId);
    const makeupDate = req.body.makeupDate || null; // 补打卡日期（YYYY-MM-DD格式）
    if (!memberId) return res.status(400).json({ ok: false, msg: '缺少memberId' });

    const member = data.members.find(m => m.id === memberId);
    if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

    // 确定打卡日期
    const checkinDate = makeupDate || today;
    const isMakeup = !!makeupDate;

    // 补打卡验证
    if (isMakeup) {
      // 只能补昨天
      if (makeupDate !== yesterday) {
        return res.status(400).json({ ok: false, msg: '只能补前一天的打卡' });
      }
      // 本月补打卡次数（统一2次/月）
      const currentMonth = today.substring(0, 7);
      const monthStart = currentMonth + '-01';
      const monthMakeupUsed = data.checkins.filter(c =>
        c.memberId === memberId && c.type === 'makeup' && c.date >= monthStart && c.date <= today
      ).length;
      if (monthMakeupUsed >= 2) {
        return res.status(400).json({ ok: false, msg: '本月补打卡机会已用完（2次/月）' });
      }
    }

    const cacheKey = memberId + '-' + checkinDate + '-audio';
    const existing = data.checkins.find(c => c.memberId === memberId && c.date === checkinDate);

    if (existing) {
      if (existing.hasAudio) {
        // 已有录音打卡，直接返回
        return res.json({ ok: true, msg: '今日已录音打卡', duplicate: true, checkin: existing });
      } else {
        // 已有快捷打卡但无录音 → 升级为录音打卡！
        const audioFileName = req.file ? req.file.filename : null;
        existing.hasAudio = true;
        existing.audioFile = audioFileName;

        // 计算排名
        const groupMembers = data.members.filter(m => m.groupId === member.groupId);
        const todayChecked = data.checkins.filter(c => c.date === today && groupMembers.some(m => m.id === c.memberId));

        // 同步写入（等待GitHub写完再返回+发通知，防止数据丢失）
        // === 核心并发修复: 用writeWithData带SHA写入 ===
        let writeOk = false;
        for (let subRetry = 0; subRetry < 3; subRetry++) {
          try {
            await db.writeWithData(data, writeSha);
            writeOk = true;
            break;
          } catch (e) {
            if (e && e.message && e.message.includes('SHA_CONFLICT') && subRetry < 2) {
              console.log('[audio-checkin-upgrade] SHA冲突，重试 ' + (subRetry+1) + '/3');
              await new Promise(r => setTimeout(r, 200 * (subRetry+1)));
              const rf = await db.readFresh();
              if (rf && rf.data) { 
                // 重新应用修改到新数据
                Object.assign(rf.data.checkins.find(c => c.id === existing.id) || {}, { hasAudio: true, audioFile: existing.audioFile });
                data = rf.data;
                writeSha = rf.sha;
                continue;
              }
            }
            throw e;
          }
        }
        if (!writeOk) return res.status(500).json({ ok: false, msg: '保存失败，请重试' });

        const respData = {
          ok: true,
          checkin: existing,
          rank: todayChecked.length,
          total: groupMembers.length,
          upgraded: true,
          msg: '快捷打卡已升级为录音打卡'
        };

        // 队列备份到GitHub（从磁盘读取文件，串行执行，避免并发冲突）
        if (req.file && audioFileName) {
          const filePath = req.file.path;
          const fileBuffer = fs.readFileSync(filePath);
          queueAudioUpload(audioFileName, fileBuffer).catch(e => {
            console.error('[audio] GitHub队列备份失败(升级):', e.message);
          });
        }

        // 向群内发送打卡通知（写入成功后才发送）
        try {
          const group = data.groups.find(g => g.id === member.groupId);
          if (group && group.webhookUrl) {
            const msg = '🌈📖✨ 恭喜' + member.name + '完成今日读书打卡！\n你是本组今日第' + todayChecked.length + '位打卡的伙伴，当前本组打卡进度：' + todayChecked.length + '/' + groupMembers.length + '\n以书为伴，共赴成长，感谢你的坚持与付出！';
            wecom.sendText(group.webhookUrl, msg).catch(err => {
              console.error('[audio-checkin-upgrade] 打卡通知发送失败:', err.message);
            });
          }
        } catch (e) {
          console.error('[audio-checkin-upgrade] 打卡通知异常:', e.message);
        }

        return res.json(respData);
      }
    }

    if (recentCheckins.has(cacheKey)) {
      return res.json({ ok: true, msg: '今日已打卡', duplicate: true, checkin: existing || null });
    }

    // 创建新的录音打卡记录
    const audioFileName = req.file ? req.file.filename : null;
    const audioDuration = parseInt(req.body.audioDuration || '0', 10) || 0;
    const checkin = {
      id: data.nextCheckinId++,
      memberId: memberId,
      groupId: member.groupId,
      date: checkinDate,
      time: new Date().toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }),
      type: isMakeup ? 'makeup' : 'normal',
      hasAudio: !!req.file,
      audioFile: audioFileName,
      audioDuration: audioDuration,
      posterSent: false
    };
    data.checkins.push(checkin);

    // 计算排名
    const groupMembers = data.members.filter(m => m.groupId === member.groupId);
    const todayChecked = data.checkins.filter(c => c.date === checkinDate && groupMembers.some(m => m.id === c.memberId));
    const rank = todayChecked.length;

    // === 核心并发修复: 用writeWithData带SHA写入，冲突自动重试 ===
    let writeOk = false;
    let newCheckinId = checkin.id;
    for (let subRetry = 0; subRetry < 3; subRetry++) {
      try {
        await db.writeWithData(data, writeSha);
        writeOk = true;
        break;
      } catch (e) {
        if (e && e.message && e.message.includes('SHA_CONFLICT') && subRetry < 2) {
          console.log('[audio-checkin] SHA冲突，重试 ' + (subRetry+1) + '/3');
          await new Promise(r => setTimeout(r, 200 * (subRetry+1)));
          const rf = await db.readFresh();
          if (rf && rf.data) {
            // 重新应用修改：把我们的新打卡记录合并进去
            const alreadyExists = rf.data.checkins.find(c => c.memberId === memberId && c.date === checkinDate && c.hasAudio);
            if (!alreadyExists) {
              // 我们的打卡记录还没被写入，重新添加
              checkin.id = rf.data.nextCheckinId || 1;
              rf.data.checkins.push(checkin);
              rf.data.nextCheckinId = (rf.data.nextCheckinId || 1) + 1;
            }
            data = rf.data;
            writeSha = rf.sha;
            continue;
          }
        }
        throw e;
      }
    }
    // 只有写库成功后才占用内存去重标记，避免写失败(如SHA冲突)后
    // 用户再点提交永远返回"今日已打卡"却没建记录（此前丢记录的元凶）
    if (writeOk) recentCheckins.set(cacheKey, true);
    if (!writeOk) return res.status(500).json({ ok: false, msg: '系统繁忙，请稍后重试' });

    // 队列备份到GitHub（从磁盘读取文件，串行执行，避免并发冲突导致备份失败）
    if (req.file && audioFileName) {
      try {
        const filePath = req.file.path;
        const fileBuffer = fs.readFileSync(filePath);
        queueAudioUpload(audioFileName, fileBuffer).catch(e => {
          console.error('[audio] GitHub队列备份失败:', e.message);
        });
      } catch (e) {
        console.error('[audio] 读取磁盘文件失败:', e.message);
      }
    }

    // 向群内发送打卡通知（文字播报）— 写入成功后才发，确保数据和通知一致
    try {
      const group = data.groups.find(g => g.id === member.groupId);
      if (group && group.webhookUrl) {
        let msg;
        if (isMakeup) {
          const currentMonth = today.substring(0, 7);
          const monthStart = currentMonth + '-01';
          const makeupUsed = data.checkins.filter(c =>
            c.memberId === memberId && c.type === 'makeup' && c.date >= monthStart && c.date <= today
          ).length;
          const makeupRemaining = Math.max(0, 2 - makeupUsed);
          msg = '🌈📖✨ 恭喜' + member.name + ' 补打卡成功（' + makeupDate + '）！\n本月剩余补打卡机会：' + makeupRemaining + '次\n以书为伴，共赴成长，感谢你的坚持与付出！';
        } else {
          // 今日已打卡名单
          const checkedNames = todayChecked.map(c => {
            const m = groupMembers.find(m => m.id === c.memberId);
            return m ? m.name : '';
          }).filter(Boolean);
          // 未打卡名单
          const checkedIds = new Set(todayChecked.map(c => c.memberId));
          const uncheckedNames = groupMembers.filter(m => !checkedIds.has(m.id)).map(m => m.name);

          msg = '🌈📖✨ 恭喜' + member.name + '完成今日读书打卡！\n';
          msg += '你是本组今日第' + rank + '位打卡的伙伴，当前本组打卡进度：' + rank + '/' + groupMembers.length + '\n';
          msg += '<font color="green">今日已打卡：' + checkedNames.join('、') + '</font>\n';
          msg += '<font color="red">未打卡：' + uncheckedNames.join('、') + '</font>\n';
          msg += '以书为伴，共赴成长，感谢你的坚持与付出！';
        }
        wecom.sendMarkdown(group.webhookUrl, msg).catch(err => {
          console.error('[audio-checkin] 打卡通知发送失败:', err.message);
        });
      }
    } catch (e) {
      console.error('[audio-checkin] 打卡通知异常:', e.message);
    }

    // 生成海报（同步生成，用于前端展示）
    let posterDataUrl = null;
    try {
      // 直接使用本次请求已读取的最新数据 data，避免再发起一次 GitHub readFresh 增加延迟
      const posterData = data;

      const baseUrl = posterSender.getPosterBaseUrl();
      const stats = posterSender.buildPosterStats(member, checkinDate, posterData);

      // 记录海报统计数据（用于排查"海报显示缺卡但报表不缺"的问题）
      console.log('[poster] 统计:', member.name, 'date=' + checkinDate,
        'eligible=' + stats.monthEligibleDays, 'checkins=' + stats.monthTotalCheckins,
        'missed=' + stats.monthMissedDays, 'makeup=' + stats.remainingMakeup);

      const posterBuffer = await poster.generatePoster({
        memberName: member.name,
        isMakeup,
        makeupDateStr: isMakeup ? checkinDate : '',
        stats,
        checkinId: checkin.id,
        baseUrl,
        audioDuration
      });
      posterDataUrl = 'data:image/png;base64,' + posterBuffer.toString('base64');

      // 异步发送到企微群（不阻塞响应）
      // v4：generateAndSendPosterForCheckin 内部会先用 GitHub SHA 原子认领(posterSent=true)再发送，
      // 保证「立即发送」与「补偿任务」全局仅发一次，无需依赖第一个参数控制标记。
      // 🛑 紧急开关：仅数据标记 _posterDisabled=true 时跳过发送（可即时切换无需部署）
      const posterDisabled = !!(data && data._posterDisabled);
      if (!posterDisabled) {
        posterSender.generateAndSendPosterForCheckin(checkin.id, data, posterBuffer).catch(err => {
          console.error('[poster] 异步发送海报失败:', err.message);
        });
      } else {
        console.log('[poster] 🛑 海报发送已禁用，跳过打卡海报');
      }
    } catch (e) {
      console.error('[poster] 海报生成失败:', e.message);
    }

    // 最后返回成功响应
    res.json({
      ok: true,
      checkin: checkin,
      rank: rank,
      total: groupMembers.length,
      audioSent: false,
      posterDataUrl: posterDataUrl
    });

  } catch (e) {
    console.error('[audio-checkin] 错误:', e.message);
    // 将常见英文错误翻译成中文字段，方便用户理解
    let chineseMsg = '上传失败，请重试';
    const errMsg = (e.message || '').toLowerCase();
    if (errMsg.includes('heap out of memory') || errMsg.includes('out of memory')) {
      chineseMsg = '服务器内存不足，请稍后重试（多人同时上传时可能出现）';
    } else if (errMsg.includes('payload too large') || errMsg.includes('file too large')) {
      chineseMsg = '录音文件太大，请控制在20MB以内';
    } else if (errMsg.includes('timeout') || errMsg.includes('etimedout')) {
      chineseMsg = '上传超时，请检查网络后重试';
    } else if (errMsg.includes('econnreset') || errMsg.includes('socket hang up')) {
      chineseMsg = '网络连接中断，请重试';
    } else if (errMsg.includes('sha_conflict') || errMsg.includes('sha 冲突')) {
      chineseMsg = '数据保存冲突，正在自动重试，请稍候';
    }
    res.status(500).json({ ok: false, msg: chineseMsg, debug: e.message });
  }
});

// ========= API: 上传海报到群（兼容旧前端/手动补发） =========
app.post('/api/poster/send', express.json({ limit: '10mb' }), async (req, res) => {
  try {
    const { memberId, imageData, checkinId } = req.body;
    if (!imageData) return res.status(400).json({ ok: false, msg: '缺少图片数据' });

    let member, group, checkin;
    const { data } = await db.readFresh();

    if (checkinId) {
      checkin = data.checkins.find(c => c.id === parseInt(checkinId));
      if (!checkin) return res.status(404).json({ ok: false, msg: '打卡记录不存在' });
      member = data.members.find(m => m.id === checkin.memberId);
    } else if (memberId) {
      member = data.members.find(m => m.id === memberId);
    } else {
      return res.status(400).json({ ok: false, msg: '缺少memberId或checkinId' });
    }

    if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

    group = data.groups.find(g => g.id === member.groupId);
    if (!group || !group.webhookUrl) return res.status(400).json({ ok: false, msg: '群组未配置' });

    // base64图片转Buffer
    const base64Data = imageData.replace(/^data:image\/\w+;base64,/, '');
    const imageBuffer = Buffer.from(base64Data, 'base64');

    // 企微图片消息限制2MB，超过则用文件消息方式发送
    if (imageBuffer.length <= 2 * 1024 * 1024) {
      await wecom.sendImageBuffer(group.webhookUrl, imageBuffer);
    } else {
      // 超过2MB，改用文件消息发送
      const filename = member.name + '_' + scheduler.getTodayStr() + '_打卡海报.png';
      await wecom.uploadAndSendFile(group.webhookUrl, imageBuffer, filename);
    }

    // 标记 posterSent（复用统一的健壮标记函数，避免手动发送后被补偿任务重复发送）
    if (checkin) {
      try {
        await posterSender.markPosterSent(checkin.id);
      } catch (e) {
        console.error('[poster] 标记 posterSent 失败:', e.message);
      }
    }

    console.log('[poster] 海报已发送到群:', member.name, group.name, '(' + (imageBuffer.length / 1024 / 1024).toFixed(1) + 'MB)');
    res.json({ ok: true });
  } catch (e) {
    console.error('[poster-send] 错误:', e.message);
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// ========= 临时补发端点（用完即删） =========
app.get('/api/poster/resend/:checkinId', async (req, res) => {
  try {
    const checkinId = parseInt(req.params.checkinId);
    console.log('[resend] 手动补发海报, checkinId:', checkinId);
    const result = await posterSender.generateAndSendPosterForCheckin(checkinId);
    res.json({ ok: true, checkinId, result });
  } catch (e) {
    console.error('[resend] 错误:', e.message);
    res.status(500).json({ ok: false, checkinId: parseInt(req.params.checkinId), msg: e.message });
  }
});

// ========= API: 生成海报预览（用于页面重新打开后展示） =========
app.get('/api/poster/preview/:checkinId', async (req, res) => {
  try {
    const checkinId = parseInt(req.params.checkinId);
    const data = (await db.readFresh()).data;
    const checkin = data.checkins.find(c => c.id === checkinId);
    if (!checkin) return res.status(404).json({ ok: false, msg: '打卡记录不存在' });

    const member = data.members.find(m => m.id === checkin.memberId);
    if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

    const baseUrl = posterSender.getPosterBaseUrl();
    const stats = posterSender.buildPosterStats(member, checkin.date, data);
    const posterBuffer = await poster.generatePoster({
      memberName: member.name,
      isMakeup: checkin.type === 'makeup',
      makeupDateStr: checkin.type === 'makeup' ? checkin.date : '',
      stats,
      checkinId: checkin.id,
      baseUrl,
      audioDuration: checkin.audioDuration || 0
    });

    res.json({
      ok: true,
      posterDataUrl: 'data:image/png;base64,' + posterBuffer.toString('base64'),
      posterSent: !!checkin.posterSent
    });
  } catch (e) {
    console.error('[poster-preview] 错误:', e.message);
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// ========= API: 个人打卡统计（本月天数、累计打卡天数、未打卡天数、剩余补卡次数） =========
app.get('/api/checkins/stats/:memberId', async (req, res) => {
  try {
    // 使用 readFresh 确保个人统计数据跨实例一致（避免缓存导致海报数据错误）
    const { data } = await db.readFresh();
    const memberId = parseInt(req.params.memberId);
    const member = data.members.find(m => m.id === memberId);
    if (!member) return res.status(404).json({ ok: false, msg: '成员不存在' });

    const today = scheduler.getTodayStr();
    const memberCheckins = data.checkins.filter(c => c.memberId === memberId).sort((a, b) => a.date.localeCompare(b.date));

    // 本月起止日期
    const currentMonth = today.substring(0, 7);
    const monthStart = currentMonth + '-01';
    const monthEnd = today; // 本月天数只算到今天

    // 本月应打卡天数（从1号到今天）
    let monthEligibleDays = 0;
    const d = new Date(monthStart);
    while (d.toISOString().split('T')[0] <= monthEnd) {
      monthEligibleDays++;
      d.setDate(d.getDate() + 1);
    }

    // 本月打卡记录
    const monthCheckins = memberCheckins.filter(c => c.date >= monthStart && c.date <= monthEnd);
    const monthTotalCheckins = monthCheckins.length; // 本月累计打卡天数（正常+补卡）

    // 本月未打卡天数
    const monthMissedDays = Math.max(0, monthEligibleDays - monthTotalCheckins);

    // 本月补卡已用次数
    const makeupUsed = monthCheckins.filter(c => c.type === 'makeup' || c.type === 'makeup-read' || c.type === 'makeup-checkin').length;
    const remainingMakeup = Math.max(0, 2 - makeupUsed); // 剩余补卡次数

    // 实际打卡天数（正常+补卡，用于365天进度）
    const totalActualDays = memberCheckins.length;

    res.json({
      ok: true,
      monthEligibleDays,
      monthTotalCheckins,
      monthMissedDays,
      remainingMakeup,
      consecutiveDays: totalActualDays,
      member: { id: member.id, name: member.name, groupId: member.groupId }
    });
  } catch (e) {
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// ========= API: 音频播放（扫码验证用） =========
// 获取打卡录音信息（供播放页使用）
app.get('/api/audio/info/:checkinId', async (req, res) => {
  try {
    const data = await db.read();
    const checkinId = parseInt(req.params.checkinId);
    const checkin = data.checkins.find(c => c.id === checkinId);
    if (!checkin) return res.status(404).json({ ok: false, msg: '打卡记录不存在' });

    const member = data.members.find(m => m.id === checkin.memberId);
    const group = data.groups.find(g => g.id === checkin.groupId);

    res.json({
      ok: true,
      checkin: {
        id: checkin.id,
        date: checkin.date,
        time: checkin.time,
        hasAudio: checkin.hasAudio,
        audioFile: checkin.audioFile
      },
      member: member ? { name: member.name } : null,
      group: group ? { name: group.name } : null
    });
  } catch (e) {
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// 播放音频文件
app.get('/api/audio/play/:checkinId', async (req, res) => {
  try {
    const data = await db.read();
    const checkinId = parseInt(req.params.checkinId);
    const checkin = data.checkins.find(c => c.id === checkinId);
    if (!checkin || !checkin.audioFile) {
      return res.status(404).json({ ok: false, msg: '音频文件不存在' });
    }

    const ext = path.extname(checkin.audioFile).toLowerCase();
    const mimeTypes = {
      '.webm': 'audio/webm',
      '.mp3': 'audio/mpeg',
      '.mp4': 'audio/mp4',
      '.m4a': 'audio/mp4',
      '.ogg': 'audio/ogg',
      '.wav': 'audio/wav'
    };
    res.setHeader('Content-Type', mimeTypes[ext] || 'audio/mpeg');
    res.setHeader('Accept-Ranges', 'bytes');

    const audioPath = path.join(__dirname, 'uploads', 'audio', checkin.audioFile);
    let fileBuffer;

    if (fs.existsSync(audioPath)) {
      // 本地文件存在，直接读取
      fileBuffer = fs.readFileSync(audioPath);
      res.setHeader('Content-Length', fileBuffer.length);
      res.send(fileBuffer);
    } else {
      // 本地文件不存在（容器重启），尝试从GitHub获取
      console.log('[audio] 本地文件不存在，尝试从GitHub获取:', checkin.audioFile);
      try {
        fileBuffer = await githubFiles.getFileBuffer(checkin.audioFile);
        console.log('[audio] 从GitHub获取成功:', checkin.audioFile, 'size=' + fileBuffer.length);
        res.setHeader('Content-Length', fileBuffer.length);
        res.send(fileBuffer);
      } catch (e) {
        console.error('[audio] GitHub获取失败:', e.message);
        return res.status(404).json({ ok: false, msg: '音频文件已过期或不存在' });
      }
    }
  } catch (e) {
    console.error('[audio-play] 错误:', e.message);
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// 音频播放页面
app.get('/listen', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'listen.html'));
});

// 定期清理30天前的音频文件（保留30天供扫码验证）
setInterval(() => {
  try {
    const audioDir = path.join(__dirname, 'uploads', 'audio');
    if (!fs.existsSync(audioDir)) return;
    const now = Date.now();
    const maxAge = 30 * 24 * 60 * 60 * 1000; // 30天（扫码验证需要保留更久）
    const files = fs.readdirSync(audioDir);
    for (const file of files) {
      const filePath = path.join(audioDir, file);
      const stat = fs.statSync(filePath);
      if (now - stat.mtime.getTime() > maxAge) {
        fs.unlinkSync(filePath);
        console.log('[cleanup] 删除过期音频:', file);
      }
    }
  } catch (e) {
    console.error('[cleanup] 清理音频失败:', e.message);
  }
}, 24 * 60 * 60 * 1000); // 每天一次

// ========= API: 测试 =========
app.post('/api/test/webhook', async (req, res) => {
  const { webhookUrl } = req.body;
  if (!webhookUrl) return res.status(400).json({ ok: false, msg: '缺少webhookUrl' });
  try {
    await wecom.sendText(webhookUrl, '读书管家测试消息 - 连接成功！\n提升心性，磨炼灵魂，坚持每日精进！');
    res.json({ ok: true, msg: '测试消息已发送' });
  } catch (err) {
    res.status(500).json({ ok: false, msg: err.message });
  }
});

// 手动触发每日内容发送（不传groupId = 全部群组，sendMorning内部用tryAcquireCronLock防重复）
app.post('/api/test/morning', async (req, res) => {
  res.json({ ok: true, msg: '早报发送任务已启动（全部群组）。若今日已发送过将自动跳过' });
  scheduler.sendMorning().then(result => {
    if (result && !result.sent) {
      console.log('[test/morning] 早报未发送:', result.reason);
    }
  }).catch(err => {
    console.error('[test/morning] 早报发送失败:', err.message);
  });
});

// 手动触发提醒（不传groupId = 全部群组，sendEveningReminder内部用tryAcquireCronLock防重复）
app.post('/api/test/reminder', async (req, res) => {
  res.json({ ok: true, msg: '打卡提醒发送任务已启动（全部群组）。若今日已发送过将自动跳过' });
  scheduler.sendEveningReminder().then(result => {
    if (result && !result.sent) {
      console.log('[test/reminder] 提醒未发送:', result.reason);
    }
  }).catch(err => {
    console.error('[test/reminder] 提醒发送失败:', err.message);
  });
});

// 手动触发日报（默认预览，传 confirm:true 才真发送）
app.post('/api/test/report', async (req, res) => {
  const { groupId, confirm } = req.body;
  if (confirm === true) {
    // 真的发送
    res.json({ ok: true, msg: '日报发送任务已启动' + (groupId ? '（仅选中群组）' : '（全部群组）') });
    scheduler.sendDailyReport(groupId ? parseInt(groupId) : undefined).catch(err => {
      console.error('[test/report] 日报发送失败:', err.message);
    });
  } else {
    // 预览模式：返回消息内容但不发送
    try {
      const preview = await scheduler.sendDailyReport(groupId ? parseInt(groupId) : undefined, true);
      res.json({ ok: true, preview: true, msg: preview.msg, groups: preview.groups });
    } catch (err) {
      res.status(500).json({ ok: false, msg: err.message });
    }
  }
});


// 手动触发月报（默认预览，传 confirm:true 才真发送）
app.post('/api/test/monthly-report', async (req, res) => {
  const { confirm } = req.body;
  if (confirm === true) {
    res.json({ ok: true, msg: '月报发送任务已启动' });
    scheduler.sendMonthlyReport().catch(err => {
      console.error('[test/monthly-report] 月报发送失败:', err.message);
    });
  } else {
    try {
      const preview = await scheduler.sendMonthlyReport(undefined, true);
      res.json({
        ok: true,
        preview: true,
        msg: preview.msg,
        stats: {
          totalExpected: preview.totalExpected,
          totalActual: preview.totalActual,
          totalRate: preview.totalRate,
          groups: preview.groupReports.map(r => ({
            name: r.group.name,
            memberCount: r.memberCount,
            rate: r.rate,
            isCompliant: r.isCompliant,
            failedMembers: r.failedMembers.map(m => ({
              name: m.member.name,
              missedCount: m.missedCount
            }))
          }))
        }
      });
    } catch (err) {
      res.status(500).json({ ok: false, msg: err.message });
    }
  }
});

// 获取今日读书内容（图片+PDF URL）
app.get('/api/today-content', async (req, res) => {
  try {
    // 获取上海时区今日日期
    const now = new Date();
    const opts = { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' };
    const parts = new Intl.DateTimeFormat('zh-CN', opts).formatToParts(now);
    const today = parts.find(p => p.type === 'year').value +
      parts.find(p => p.type === 'month').value +
      parts.find(p => p.type === 'day').value; // e.g. "20260615"

    const files = await githubFiles.listFiles();
    const imgFile = files.find(f => f.match(new RegExp('^' + today + 'B\\.(jpg|jpeg|png)$', 'i')));
    const pdfFile = files.find(f => f.match(new RegExp('^' + today + 'A\\.pdf$', 'i')));

    res.json({
      ok: true,
      date: today,
      imgFile: imgFile || null,
      imgUrl: imgFile ? githubFiles.getFileUrl(imgFile) : null,
      pdfFile: pdfFile || null,
      pdfUrl: pdfFile ? githubFiles.getFileUrl(pdfFile) : null
    });
  } catch (e) {
    console.error('[today-content]', e.message);
    res.json({ ok: false, imgFile: null, imgUrl: null, pdfFile: null, pdfUrl: null });
  }
});

// 内容文件代理（私有仓库 raw URL 无法直接访问，通过服务器代理）
app.get('/content-proxy/:filename', async (req, res) => {
  try {
    const buffer = await githubFiles.getFileBuffer(req.params.filename);
    const ext = path.extname(req.params.filename).toLowerCase();
    const mimeTypes = { '.pdf': 'application/pdf', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png' };
    res.setHeader('Content-Type', mimeTypes[ext] || 'application/octet-stream');
    // PDF不设Content-Disposition（企微内置浏览器不支持下载，改为复制链接在系统浏览器打开）
    res.setHeader('Content-Length', buffer.length);
    res.send(buffer);
  } catch (err) {
    res.status(404).json({ ok: false, msg: '文件不存在或获取失败: ' + err.message });
  }
});

// ========= 版本检查API（调试用，无需登录）========
app.get('/version', (req, res) => {
  res.json({ ok: true, version: APP_VERSION });
});

// ========= 启动前数据迁移 =========
// 给没有startDate的旧成员补上默认值（2026-06-01，系统上线月份）
(async () => {
  try {
    const data = await db.read();
    let migrated = false;
    for (const m of data.members) {
      if (!m.startDate) {
        m.startDate = '2026-06-01';
        migrated = true;
      }
    }
    if (migrated) {
      console.log('[migrate] 已为旧成员补上startDate=2026-06-01');
      await db.write(data);
    }
  } catch (e) {
    console.error('[migrate] 数据迁移失败:', e.message);
  }
})();

// ========= 启动 =========
// SSL模式：设置了 SSL_KEY_PATH 和 SSL_CRT_PATH 时直接以HTTPS监听443（无需nginx），
// 同时80端口自动跳转到HTTPS。适合腾讯云国内服务器（录音需要HTTPS）。
const SSL_KEY_PATH = process.env.SSL_KEY_PATH;
const SSL_CRT_PATH = process.env.SSL_CRT_PATH;
const BASE_DOMAIN = process.env.BASE_DOMAIN || 'zhengpintang.cn';

if (SSL_KEY_PATH && SSL_CRT_PATH && fs.existsSync(SSL_KEY_PATH) && fs.existsSync(SSL_CRT_PATH)) {
  const https = require('https');
  const http = require('http');
  const sslOptions = {
    key: fs.readFileSync(SSL_KEY_PATH, 'utf8'),
    cert: fs.readFileSync(SSL_CRT_PATH, 'utf8')
  };
  https.createServer(sslOptions, app).listen(443, () => {
    console.log('读书打卡管家已启动(HTTPS): https://' + BASE_DOMAIN);
    console.log('管理后台: https://' + BASE_DOMAIN + '/admin.html');
    scheduler.startAll();
  });
  // HTTP 80 → HTTPS 301跳转
  http.createServer((req, res) => {
    res.writeHead(301, { Location: 'https://' + BASE_DOMAIN + req.url });
    res.end();
  }).listen(80, () => {
    console.log('HTTP→HTTPS跳转已启动(80端口)');
  });
} else {
  app.listen(PORT, () => {
    console.log('读书打卡管家已启动: http://localhost:' + PORT);
    console.log('管理后台: http://localhost:' + PORT + '/admin');
    scheduler.startAll();
  });
}
