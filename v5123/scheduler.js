const cron = require('node-cron');
const db = require('./db');
const wecom = require('./wecom');
const githubFiles = require('./github-files');
const posterSender = require('./poster-sender');

// 防止同一任务并发执行
const taskLocks = {};

// 用上海时区获取当前日期字符串
function getTodayStr() {
  const d = new Date();
  const options = { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' };
  const parts = new Intl.DateTimeFormat('zh-CN', options).formatToParts(d);
  const year = parts.find(p => p.type === 'year').value;
  const month = parts.find(p => p.type === 'month').value;
  const day = parts.find(p => p.type === 'day').value;
  return year + '-' + month + '-' + day;
}

// 获取昨天的日期字符串（上海时区）
function getYesterdayStr() {
  const d = new Date();
  // 用上海时区构建一个日期，然后减一天
  const options = { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' };
  const parts = new Intl.DateTimeFormat('zh-CN', options).formatToParts(d);
  const year = parseInt(parts.find(p => p.type === 'year').value);
  const month = parseInt(parts.find(p => p.type === 'month').value) - 1; // JS月份0-based
  const day = parseInt(parts.find(p => p.type === 'day').value);
  const shDate = new Date(year, month, day);
  shDate.setDate(shDate.getDate() - 1);
  const y = shDate.getFullYear();
  const m = String(shDate.getMonth() + 1).padStart(2, '0');
  const dd = String(shDate.getDate()).padStart(2, '0');
  return y + '-' + m + '-' + dd;
}

// 获取指定 Date 对象对应的上海日期字符串
function getShDateStr(dateObj) {
  const opts = { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' };
  const parts = new Intl.DateTimeFormat('zh-CN', opts).formatToParts(dateObj);
  return parts.find(p => p.type === 'year').value + '-' +
    parts.find(p => p.type === 'month').value + '-' +
    parts.find(p => p.type === 'day').value;
}

function getWeekdayName() {
  const names = ['日', '一', '二', '三', '四', '五', '六'];
  const shDateStr = getTodayStr();
  const weekday = new Date(shDateStr + 'T12:00:00+08:00').getDay();
  return '星期' + names[weekday];
}

async function getTodayContent() {
  const today = getTodayStr().replace(/-/g, '');
  const result = { date: getTodayStr(), pdfFile: null, jpgFile: null, pdfUrl: null, jpgUrl: null };

  const files = await githubFiles.listFiles();
  const pdf = files.find(f => f.match(new RegExp('^' + today + 'A\\.pdf$', 'i')));
  const jpg = files.find(f => f.match(new RegExp('^' + today + 'B\\.(jpg|jpeg|png)$', 'i')));

  if (pdf) {
    result.pdfFile = pdf;
    result.pdfUrl = githubFiles.getFileUrl(pdf);
  }
  if (jpg) {
    result.jpgFile = jpg;
    result.jpgUrl = githubFiles.getFileUrl(jpg);
  }

  return result;
}

// ===== 月度报表辅助函数 =====

// 获取上个月的信息（年、月、天数、起止日期）
function getPreviousMonthInfo() {
  const now = new Date();
  const options = { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit' };
  const parts = new Intl.DateTimeFormat('zh-CN', options).formatToParts(now);
  const year = parseInt(parts.find(p => p.type === 'year').value);
  const month = parseInt(parts.find(p => p.type === 'month').value);

  let prevYear = year;
  let prevMonth = month - 1;
  if (prevMonth === 0) {
    prevMonth = 12;
    prevYear = year - 1;
  }

  const daysInMonth = new Date(prevYear, prevMonth, 0).getDate();
  const monthStr = String(prevMonth).padStart(2, '0');
  const yearMonth = prevYear + '-' + monthStr;
  const startDate = yearMonth + '-01';
  const endDate = yearMonth + '-' + String(daysInMonth).padStart(2, '0');

  return {
    year: prevYear,
    month: prevMonth,
    yearMonth: yearMonth,
    daysInMonth: daysInMonth,
    startDate: startDate,
    endDate: endDate,
    chineseMonth: prevMonth + '月'
  };
}

// 中文数字排序辅助
const cnNums = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10 };
function getGroupNumber(name) {
  const m = (name || '').match(/([一二三四五六七八九十])\s*组/);
  return m ? (cnNums[m[1]] || 0) : 0;
}

// 按日期查成员当时所在的组（季度换组后，月报仍按"当时的组"统计）
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

// ===== 月度报表发送函数 =====
async function sendMonthlyReport(targetGroupId, dryRun) {
  console.log('[月报] 开始生成月度打卡报表...');
  const { data } = await db.readFresh();

  const monthInfo = getPreviousMonthInfo();
  const { yearMonth, daysInMonth, startDate, endDate } = monthInfo;

  // 生成上月日期列表
  const dates = [];
  for (let day = 1; day <= daysInMonth; day++) {
    dates.push(yearMonth + '-' + String(day).padStart(2, '0'));
  }

  let groups = targetGroupId
    ? data.groups.filter(g => g.id === targetGroupId)
    : data.groups.slice();
  groups.sort((a, b) => getGroupNumber(a.name) - getGroupNumber(b.name));

  // 收集每组数据
  const groupReports = [];
  let totalExpected = 0;
  let totalActual = 0;

  // 每月补卡券2次（v5.12.3: 提前定义，成员统计时要用）
  const MAKEUP_VOUCHERS = 2;

  for (const group of groups) {
    // 季度换组兼容：按上月1号时成员所在的组归组（换组后查历史月份，人还在当时的组）
    const members = data.members.filter(m => getGroupAt(m, startDate) === group.id);
    const memberStats = [];

    for (const member of members) {
      const memberStart = member.startDate || startDate;
      // 成员在上月结束后才加入，跳过
      if (memberStart > endDate) continue;

      // 有效日期：从 max(memberStart, monthStart) 到 endDate
      const effectiveStart = memberStart > startDate ? memberStart : startDate;
      const eligibleDates = dates.filter(d => d >= effectiveStart && d <= endDate);
      const eligibleDays = eligibleDates.length;

      if (eligibleDays === 0) continue;

      // 该成员上月的所有打卡记录
      const memberCheckins = data.checkins.filter(c =>
        c.memberId === member.id && c.date >= startDate && c.date <= endDate
      );

      // 唯一打卡天数（正常+补卡都算正常打卡）
      const checkedDates = new Set(memberCheckins.map(c => c.date));
      const checkedCount = checkedDates.size;
      const missedCount = eligibleDays - checkedCount;

      // v5.12.3 修复：不达标标准="用完2次补卡券后还有缺卡"。
      // 旧逻辑只看 missedCount>2，没扣掉已用的补卡券次数，导致
      // 补卡券已用完还缺卡的人（如缺1次+已用2张券）被误判达标。
      // 剩余补卡券 = 2 - makeupUsed；不可补救缺卡 = missedCount - 剩余补卡券。
      const makeupUsed = memberCheckins.filter(c =>
        c.type === 'makeup' || c.type === 'makeup-read' || c.type === 'makeup-checkin'
      ).length;
      const remainingVouchers = Math.max(0, MAKEUP_VOUCHERS - makeupUsed);
      const irrecoverableMisses = Math.max(0, missedCount - remainingVouchers);

      memberStats.push({
        member,
        eligibleDays,
        checkedCount,
        missedCount,
        makeupUsed,
        irrecoverableMisses
      });
    }

    // 组统计
    const groupEligible = memberStats.reduce((sum, m) => sum + m.eligibleDays, 0);
    const groupChecked = memberStats.reduce((sum, m) => sum + m.checkedCount, 0);
    const rate = groupEligible > 0 ? Math.round(groupChecked / groupEligible * 100) : 0;

    // 不达标：用完2次补卡券后还有缺卡（不可补救缺卡 >= 1次）
    // 补了卡的算正常打卡，月度报表中所有缺卡都是无任何打卡记录的天数
    const failedMembers = memberStats.filter(m => m.irrecoverableMisses > 0);
    const isCompliant = failedMembers.length === 0;

    groupReports.push({
      group,
      memberCount: memberStats.length,
      groupEligible,
      groupChecked,
      rate,
      isCompliant,
      failedMembers,
      allMemberStats: memberStats
    });

    totalExpected += groupEligible;
    totalActual += groupChecked;
  }

  // 按打卡率从高到低排名
  groupReports.sort((a, b) => b.rate - a.rate);

  // 构建消息
  const totalRate = totalExpected > 0 ? Math.round(totalActual / totalExpected * 100) : 0;
  const rankEmojis = ['🥇', '🥈', '🥉'];

  let msg = '📊 ' + monthInfo.year + '年' + monthInfo.chineseMonth + '打卡月报\n\n';
  msg += '📅 统计周期：' + monthInfo.startDate + ' — ' + monthInfo.endDate + '\n';
  msg += '👤 应打卡总人次：' + totalExpected.toLocaleString() + ' 人次\n';
  msg += '✅ 实际打卡总人次：' + totalActual.toLocaleString() + ' 人次\n';
  msg += '📈 整体打卡率：' + totalRate + '%\n';
  msg += '━━━━━━━━━━━━\n';
  msg += '🏆 小组打卡率排名\n\n';

  const compliantGroups = [];
  const nonCompliantGroups = [];

  for (let i = 0; i < groupReports.length; i++) {
    const r = groupReports[i];
    const rank = i + 1;
    const emoji = rank <= 3 ? rankEmojis[i] : (rank + '.');

    msg += emoji + ' ' + r.group.name + '（' + r.memberCount + '人）  打卡率 ' + r.rate + '%';
    msg += r.isCompliant ? ' ✅达标\n' : ' ❌不达标\n';

    if (r.isCompliant) {
      compliantGroups.push(r.group.name);
    } else {
      nonCompliantGroups.push(r);
    }
  }

  // 不达标组缺卡详情
  if (nonCompliantGroups.length > 0) {
    msg += '━━━━━━━━━━━━\n';
    msg += '⚠️ 不达标组缺卡详情\n\n';

    for (const r of nonCompliantGroups) {
      msg += '📌 ' + r.group.name + '（打卡率 ' + r.rate + '%）\n';
      for (const m of r.failedMembers) {
        const irrecoverable = m.irrecoverableMisses;
        const tip = m.makeupUsed >= MAKEUP_VOUCHERS
          ? '补卡券已用完，不可补救 ' + irrecoverable + ' 次'
          : '超补卡券 ' + irrecoverable + ' 次';
        msg += '  · ' + m.member.name + '  缺卡 ' + m.missedCount + ' 次（' + tip + '）\n';
      }
      msg += '\n';
    }
  }

  // 达标小组
  msg += '━━━━━━━━━━━━\n';
  if (compliantGroups.length > 0) {
    msg += '🎉 达标小组：' + compliantGroups.join('、') + '\n';
  }
  if (nonCompliantGroups.length > 0) {
    msg += '💪 未达标小组加油，下月继续努力！\n';
  }

  const todayStr = getTodayStr();
  msg += '\n📋 本报告由系统自动生成 · ' + todayStr + ' 06:00';

  if (dryRun) {
    return { msg, groupReports, totalExpected, totalActual, totalRate };
  }

  // 发送到每个群（同一条消息，不@人）
  for (const r of groupReports) {
    try {
      await wecom.sendText(r.group.webhookUrl, msg);
      console.log('[月报] 群"' + r.group.name + '"月报已发送');
    } catch (err) {
      console.error('[月报] 群"' + r.group.name + '"月报失败:', err.message);
    }
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
}

// ===== 月度报表定时任务（每月2号6点）=====
// v5.12.2 修复：改用 tryAcquireCronLock 原子锁（检查+标记一步写入），与日报/晚报一致。
// 根治"单台服务器也发两份"：旧逻辑是"检查_cronSent→发送(5个群耗时几十秒)→再标记"三步非原子，
// 发送期间第二次触发（进程重启后重入/手动重发）时标记还没写入，就会再发一份。
function scheduleMonthlyReport() {
  cron.schedule('0 6 2 * *', async () => {
    const now = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    console.log('[月报] ⚡ cron触发（时间: ' + now + '）');

    const monthInfo = getPreviousMonthInfo();
    try {
      // 原子锁：readFresh读最新→检查_cronSent→标记→writeWithData一步完成
      const canSend = await db.tryAcquireCronLock('monthly', monthInfo.yearMonth);
      if (!canSend) {
        console.log('[月报] ⚠️ ' + monthInfo.yearMonth + ' 月报已发送过（原子锁拦截），跳过');
        return;
      }
      console.log('[月报] ✅ 原子锁获取成功，开始发送 ' + monthInfo.yearMonth + ' 月报...');
      await sendMonthlyReport();
    } catch (e) {
      console.error('[月报] 执行失败:', e.message, e.stack);
    }
  }, { scheduled: true, timezone: 'Asia/Shanghai' });
}

// 手动触发月报（带原子锁）：返回 {sent:true} 已发送 / {sent:false, reason:'already_sent'} 本月已发过
// 供 /api/test/monthly-report 等手动入口使用，保证任何入口一个月只发一次
async function trySendMonthlyReport() {
  const monthInfo = getPreviousMonthInfo();
  const canSend = await db.tryAcquireCronLock('monthly', monthInfo.yearMonth);
  if (!canSend) {
    console.log('[月报] ⚠️ 手动触发被原子锁拦截：' + monthInfo.yearMonth + ' 月报已发送过');
    return { sent: false, reason: 'already_sent' };
  }
  await sendMonthlyReport();
  return { sent: true };
}

// 06:00 先发昨日打卡日报，再发今日读书内容+打卡入口
function scheduleMorningContent() {
  cron.schedule('0 6 * * *', async () => {
    const now = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    console.log('[06:00] ⚡ cron触发（时间: ' + now + '）');
    try { await sendMorning(); } catch(e) { console.error('[06:00] 执行失败:', e.message, e.stack); }
  }, { scheduled: true, timezone: 'Asia/Shanghai' });
}

async function sendMorning(targetGroupId) {
  // 第一重：内存标记（防同一进程内重复）
  const now = Date.now();
  if (taskLocks._lastMorningRun && (now - taskLocks._lastMorningRun) < 4 * 3600 * 1000) {
    const last = new Date(taskLocks._lastMorningRun).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    console.log('[06:00] ⚠️ 内存标记：距上次不足4小时（上次: ' + last + '），跳过');
    return { sent: false, reason: 'memory_lock' };
  }

  // 第二重：原子操作——检查_cronSent + 标记一步完成（防跨实例重复发送）
  // tryAcquireCronLock内部用readFresh读最新数据 + writeWithData带SHA写入，天然原子
  const today = getTodayStr();
  const canSend = await db.tryAcquireCronLock('morning', today);
  if (!canSend) {
    console.log('[06:00] ⚠️ 今日已发送过早报或原子锁获取失败，跳过');
    return { sent: false, reason: 'already_sent' };
  }

  taskLocks._lastMorningRun = now;
  console.log('[06:00] ✅ 原子锁获取成功，开始发送...');

  try {
    // 第一步：发送昨日打卡日报
    await sendDailyReport(targetGroupId);

    // 等待 2 秒后再发今日内容，让日报消息先展示
    await new Promise(r => setTimeout(r, 2000));

    // 第二步：发送今日读书内容和打卡入口
    await sendMorningContent(targetGroupId);

    console.log('[06:00] ✅ 早报发送完成');
    return { sent: true };
  } catch (e) {
    console.error('[06:00] 发送失败:', e.message, e.stack);
    return { sent: false, reason: 'error: ' + e.message };
  }
}

// 发送昨日打卡日报（汇总所有组，发到每个群）
async function sendDailyReport(targetGroupId, dryRun) {
  console.log('[06:00] 发送昨日读书日报...');
  const freshResult = await db.readFresh(); // 用readFresh避免缓存导致旧数据
  if (!freshResult || !freshResult.data || freshResult.fresh === false) {
    console.error('[06:00] ⚠️ readFresh返回非新鲜数据，跳过日报发送');
    return;
  }
  const { data } = freshResult;

  // 获取昨天的日期
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const reportDate = getShDateStr(yesterday);
  const currentMonth = reportDate.substring(0, 7);
  const monthStart = currentMonth + '-01';

  let groups = targetGroupId
    ? data.groups.filter(g => g.id === targetGroupId)
    : data.groups.slice();

  // 按组名中的"一组/二组/..."数字排序（支持中文数字）
  function getGroupNumber(name) {
    const m = (name || '').match(/([一二三四五六七八九十])\s*组/);
    return m ? (cnNums[m[1]] || 0) : 0;
  }
  function normalizeTime(timeStr) {
    const m = (timeStr || '').match(/(\d{1,2}):(\d{2})/);
    if (!m) return '';
    return String(m[1]).padStart(2, '0') + ':' + m[2];
  }
  groups.sort((a, b) => getGroupNumber(a.name) - getGroupNumber(b.name));

  // 计算某人本月补卡次数（含昨天）
  function getMakeupUsed(memberId) {
    return data.checkins.filter(c =>
      c.memberId === memberId &&
      c.type === 'makeup' &&
      c.date >= monthStart &&
      c.date <= reportDate
    ).length;
  }

  // 判断成员昨日状态
  function getMemberStatus(member) {
    const checkins = data.checkins.filter(c =>
      c.memberId === member.id && c.date === reportDate
    );
    const normal = checkins.find(c => c.type !== 'makeup' && c.type !== 'makeup-read' && c.type !== 'makeup-checkin');
    const makeup = checkins.find(c => c.type === 'makeup' || c.type === 'makeup-read' || c.type === 'makeup-checkin');

    if (normal) {
      return { type: 'normal', time: normal.time || '' };
    }
    if (makeup) {
      return { type: 'makeup', time: makeup.time || '' };
    }
    return { type: 'missed', makeupUsed: getMakeupUsed(member.id) };
  }

  // 收集所有小组数据
  const groupReports = [];
  for (const group of groups) {
    const members = data.members.filter(m => m.groupId === group.id);
    const total = members.length;

    const normalMembers = [];
    const makeupMembers = [];
    const missedMembers = [];

    let lastCheckinTime = '';
    for (const member of members) {
      const status = getMemberStatus(member);
      if (status.type === 'normal') {
        normalMembers.push(member);
        if (status.time && status.time > lastCheckinTime) {
          lastCheckinTime = status.time;
        }
      } else if (status.type === 'makeup') {
        makeupMembers.push(member);
      } else {
        missedMembers.push({ member, makeupUsed: status.makeupUsed });
      }
    }

    const normalCount = normalMembers.length;
    const rate = total > 0 ? Math.round(normalCount / total * 100) : 0;

    groupReports.push({
      group, total, normalCount, rate,
      lastCheckinTime: normalizeTime(lastCheckinTime),
      makeupMembers,
      missedMembers
    });
  }

  // 计算冠军组：100%完成且完成时间<22:00中最早的那个
  let championGroupId = null;
  const fullGroupsBefore22 = groupReports.filter(r =>
    r.rate === 100 && r.lastCheckinTime && r.lastCheckinTime < '22:00'
  );
  if (fullGroupsBefore22.length > 0) {
    fullGroupsBefore22.sort((a, b) => a.lastCheckinTime.localeCompare(b.lastCheckinTime));
    championGroupId = fullGroupsBefore22[0].group.id;
  }

  // 构建汇总消息
  let msg = '📊 昨日读书打卡汇总日报 ' + reportDate + '\n';
  let totalNormal = 0;
  let totalMembers = 0;

  for (const r of groupReports) {
    totalNormal += r.normalCount;
    totalMembers += r.total;

    msg += '\n【' + r.group.name + '】' + r.normalCount + '/' + r.total + '  ';
    if (r.rate === 100) {
      msg += '✅ 100%  完成时间 ' + r.lastCheckinTime;
      if (r.group.id === championGroupId) {
        msg += ' 🏆';
      }
    } else {
      msg += '⚠️ ' + r.rate + '%';
      // 未正常打卡的人都要列出来
      const names = [];
      for (const m of r.missedMembers) {
        let suffix = '';
        if (m.makeupUsed >= 2) suffix = '（本月补卡次数已用完）';
        names.push(m.member.name + suffix);
      }
      for (const m of r.makeupMembers) {
        names.push(m.name + '（已补卡）');
      }
      if (names.length > 0) {
        msg += '  未打卡：' + names.join('，');
      }
    }
    msg += '\n';
  }

  const totalRate = totalMembers > 0 ? Math.round(totalNormal / totalMembers * 100) : 0;
  msg += '——————————————————\n';
  msg += '合计：' + totalNormal + '/' + totalMembers + '（' + totalRate + '%）';

  // 原版提醒文案（仅当有未正常打卡的人时显示）
  const hasAnyMissed = groupReports.some(r => r.missedMembers.length > 0 || r.makeupMembers.length > 0);
  if (hasAnyMissed) {
    msg += '\n\n⚠️ 请昨日未打卡的伙伴在今天24点前进行补打卡，逾期无法补卡！';
  }

  // 同一条消息发到每个群，@只针对本群未正常打卡且未补卡的人
  const isMobile = (v) => /^1\d{10}$/.test(v);
  const sendResults = [];
  for (const r of groupReports) {
    const toMention = r.missedMembers.map(m => m.member);

    const mentionedUserids = toMention.filter(m => m.userid && !isMobile(m.userid)).map(m => m.userid);
    const useridAsMobile = toMention.filter(m => m.userid && isMobile(m.userid)).map(m => m.userid);
    const explicitMobile = toMention.filter(m => m.mobile).map(m => m.mobile);
    const mentionedMobiles = [...new Set([...useridAsMobile, ...explicitMobile])];

    if (dryRun) {
      sendResults.push({
        group: r.group.name,
        mentionCount: mentionedUserids.length + mentionedMobiles.length,
        mentionNames: toMention.map(m => m.name)
      });
      continue;
    }

    try {
      await wecom.sendText(r.group.webhookUrl, msg,
        mentionedUserids.length > 0 ? mentionedUserids : undefined,
        mentionedMobiles.length > 0 ? mentionedMobiles : undefined
      );
      console.log('[06:00] 群"' + r.group.name + '"日报已发送(Text)，@' + (mentionedUserids.length + mentionedMobiles.length) + '人');
    } catch (err) {
      console.error('[06:00] 群"' + r.group.name + '"日报失败:', err.message);
    }

    await new Promise(resolve => setTimeout(resolve, 1000));
  }

  if (dryRun) {
    return { msg, groups: sendResults };
  }
}

// 发送今日打卡入口
async function sendMorningContent(targetGroupId) {
  console.log('[06:00] 发送今日打卡入口...');
  const data = await db.read();
  const today = getTodayStr();

  const groups = targetGroupId
    ? data.groups.filter(g => g.id === targetGroupId)
    : data.groups;

  for (const group of groups) {
    try {
      const baseUrl = process.env.BASE_URL || process.env.RAILWAY_PUBLIC_URL || 'https://web-production-d6162.up.railway.app';
      const checkinUrl = baseUrl + '/checkin.html?group=' + group.id;

      await wecom.sendText(group.webhookUrl,
        '🌅 早上好，正品堂的各位家人！\n今天是 ' + today + ' ' + getWeekdayName() + '，我们的读书打卡继续进行～\n请点开下方链接，完成今日的阅读打卡：\n\n打卡入口：' + checkinUrl + '\n\n以书润心，以知养性，日日沉淀，日日成长！'
      );
      console.log('[06:00] 群"' + group.name + '"打卡入口已发送');

      await new Promise(r => setTimeout(r, 1000));
    } catch (err) {
      console.error('[06:00] 群"' + group.name + '"发送失败:', err.message);
    }
  }
}

// 22:00 提醒未打卡的人
function scheduleEveningReminder() {
  cron.schedule('0 22 * * *', async () => {
    const now = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    console.log('[22:00] ⚡ cron触发（时间: ' + now + '）');
    try { await sendEveningReminder(); } catch(e) { console.error('[22:00] 执行失败:', e.message, e.stack); }
  }, { scheduled: true, timezone: 'Asia/Shanghai' });
}

async function sendEveningReminder(targetGroupId) {
  // 第一重：内存标记（防同一进程内重复）
  const now = Date.now();
  if (taskLocks._lastEveningRun && (now - taskLocks._lastEveningRun) < 4 * 3600 * 1000) {
    const last = new Date(taskLocks._lastEveningRun).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    console.log('[22:00] ⚠️ 内存标记：距上次不足4小时（上次: ' + last + '），跳过');
    return { sent: false, reason: 'memory_lock' };
  }

  // 第二重：原子操作——检查_cronSent + 标记一步完成（防跨实例重复发送）
  const today = getTodayStr();
  const canSend = await db.tryAcquireCronLock('evening', today);
  if (!canSend) {
    console.log('[22:00] ⚠️ 今日已发送过提醒或原子锁获取失败，跳过');
    return { sent: false, reason: 'already_sent' };
  }

  taskLocks._lastEveningRun = now;
  console.log('[22:00] ✅ 原子锁获取成功，开始发送...');

  try {
    // 关键：必须用readFresh且检查fresh标记，避免用旧数据发错误消息@所有人
    const freshResult = await db.readFresh();
    if (!freshResult || !freshResult.data || freshResult.fresh === false) {
      console.error('[22:00] ⚠️ readFresh返回非新鲜数据（GitHub不可用），跳过发送避免用旧数据@所有人');
      await db.addLog('evening-send', 'skipped', 'readFresh非新鲜数据，跳过发送避免错误@all');
      return { sent: false, reason: 'stale_data' };
    }

    const { data } = freshResult;

    const groups = targetGroupId
      ? data.groups.filter(g => g.id === targetGroupId)
      : data.groups;

    for (const group of groups) {
      const members = data.members.filter(m => m.groupId === group.id);
      const checkedIds = data.checkins
        .filter(c => c.date === today && members.some(m => m.id === c.memberId))
        .map(c => c.memberId);
      const unchecked = members.filter(m => !checkedIds.includes(m.id));

      if (unchecked.length === 0) {
        try {
          await wecom.sendText(group.webhookUrl,
            '🎉 今日全员已打卡！太棒了！\n提升心性，磨炼灵魂，坚持每日精进！'
          );
        } catch (err) { console.error(err.message); }
        continue;
      }

      const names = unchecked.map(m => m.name).join('，');
      const baseUrl = process.env.BASE_URL || process.env.RAILWAY_PUBLIC_URL || 'https://web-production-d6162.up.railway.app';
      const checkinUrl = baseUrl + '/checkin.html?group=' + group.id;
      const msg = '📢 读书打卡提醒\n以下小伙伴今日尚未完成打卡:\n' + names + '\n打卡入口：' + checkinUrl + '\n每一次打卡都是成长的脚印，坚持下去，和团队一起在精进中遇见更好的自己！';

      // 用 userid + 手机号让企微真正@到人
      const isMobile = (v) => /^\d{11}$/.test(v);
      const mentionedUserids = unchecked.filter(m => m.userid && !isMobile(m.userid)).map(m => m.userid);
      const useridAsMobile = unchecked.filter(m => m.userid && isMobile(m.userid)).map(m => m.userid);
      const explicitMobile = unchecked.filter(m => m.mobile).map(m => m.mobile);
      const mentionedMobiles = [...new Set([...useridAsMobile, ...explicitMobile])];

      try {
        await wecom.sendText(group.webhookUrl, msg,
          mentionedUserids.length > 0 ? mentionedUserids : undefined,
          mentionedMobiles.length > 0 ? mentionedMobiles : undefined
        );
        console.log('[22:00] 群"' + group.name + '"提醒已发送，' + unchecked.length + '人未打卡，@了' + (mentionedUserids.length + mentionedMobiles.length) + '人');
      } catch (err) {
        console.error('[22:00] 群"' + group.name + '"提醒失败:', err.message);
      }

      await new Promise(r => setTimeout(r, 1000));
    }

    console.log('[22:00] ✅ 提醒发送完成');
    return { sent: true };
  } catch (e) {
    console.error('[22:00] 发送失败:', e.message, e.stack);
    return { sent: false, reason: 'error: ' + e.message };
  }
}

async function resendMissingPosters() {
  // 分布式锁：防止多实例同时执行补偿任务
  const lockAcquired = await db.acquireDistributedLock('poster-compensation', 300); // 5分钟锁
  if (!lockAcquired) {
    console.log('[poster] 补偿任务：未获取分布式锁，跳过');
    return;
  }

  try {
    const today = getTodayStr();
    const { data } = await db.readFresh();
    // 🛑 全局海报发送紧急开关
    if (data && data._posterDisabled) {
      console.log('[poster] 🛑 海报发送已通过开关禁用，跳过补偿发送');
      return;
    }

    const now = Date.now();
    const GRACE_PERIOD = 5 * 60 * 1000; // 5分钟宽限期

    // 只处理5分钟前创建的打卡（给即时发送7次重试足够时间完成）
    // 这是从根本上避免补偿任务与即时发送冲突导致重复刷屏
    const missing = data.checkins.filter(c => {
      if (c.date !== today || c.posterSent) return false;

      // 构建打卡时间戳
      let checkinTime = null;
      if (c.createdAt) {
        checkinTime = new Date(c.createdAt).getTime();
      }
      if (!checkinTime || isNaN(checkinTime)) {
        // 回退：用 date + time 字段构建（格式 "2026-07-27" + "07:27:55"）
        if (c.time) {
          checkinTime = new Date(c.date + 'T' + c.time + '+08:00').getTime();
        }
      }

      // 有有效时间戳且在宽限期内 → 跳过（即时发送可能还在重试中）
      if (checkinTime && !isNaN(checkinTime) && (now - checkinTime) < GRACE_PERIOD) {
        return false;
      }
      // 没有时间戳的旧记录 或 已过宽限期 → 需要补偿
      return true;
    });

    if (missing.length === 0) return;

    console.log('[poster] 补偿任务：发现 ' + missing.length + ' 条未发送海报（已过5分钟宽限期），开始补偿...');
    for (const checkin of missing) {
      try {
        await posterSender.generateAndSendPosterForCheckin(checkin.id);
        // 每条间隔3秒，避免企微频率限制（v4.6刷屏原因之一是1秒太快）
        await new Promise(r => setTimeout(r, 3000));
      } catch (e) {
        console.error('[poster] 补偿发送失败 checkinId=' + checkin.id + ':', e.message);
      }
    }
  } catch (e) {
    console.error('[poster] 补偿任务异常:', e.message);
  } finally {
    await db.releaseDistributedLock('poster-compensation');
  }
}

function schedulePosterResend() {
  // 每5分钟检查一次今日未发送海报的打卡（配合5分钟宽限期，不会与即时发送冲突）
  cron.schedule('*/5 * * * *', async () => {
    const now = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
    console.log('[poster] ⚡ 补偿任务触发（时间: ' + now + '）');
    await resendMissingPosters();
  }, { scheduled: true, timezone: 'Asia/Shanghai' });
}

function startAll() {
  scheduleMorningContent();
  scheduleEveningReminder();
  scheduleMonthlyReport();
  // v5.3: 重新启用海报补偿任务（5分钟间隔 + 5分钟宽限期 + 分布式锁 + 3秒发送间隔）
  // 之前v4.6禁用是因为无宽限期导致补偿与即时发送冲突→重复刷屏
  // 现在加了5分钟宽限期，即时发送(7次重试最多~64秒)早已完成，补偿只处理真正漏发的
  schedulePosterResend();
  console.log('[version] reading-checkin v2026-08-28-v5.12.3 (月报达标判定修复: 补卡券用完还有缺卡才算不达标, 与后台预警一致)');
  console.log('[定时任务] 已启动: 06:00日报+内容 | 22:00提醒 | 月报(每月2号6点) | 海报补偿(5min间隔,5min宽限期)');
}

module.exports = { startAll, getTodayStr, getYesterdayStr, getWeekdayName, sendMorning, sendMorningContent, sendDailyReport, sendEveningReminder, resendMissingPosters, sendMonthlyReport, trySendMonthlyReport, getPreviousMonthInfo };
