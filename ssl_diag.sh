#!/bin/bash
echo "==========================="
echo " 证书 + HTTPS 诊断脚本"
echo "==========================="

echo "[1] SSL目录文件:"
ls -la /opt/reading-checkin/ssl/

echo ""
echo "[2] 证书文件前30字节HEX（前30字符防止不可见字符干扰）:"
head -c 30 /opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt | od -An -tx1

echo ""
echo "[3] 证书文件后30字节HEX:"
tail -c 30 /opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt | od -An -tx1

echo ""
echo "[4] 证书字节数:"
wc -c /opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt

echo ""
echo "[5] openssl 验证证书（如果有错下面会显示）:"
openssl x509 -in /opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt -noout -subject -dates 2>&1 | head -5

echo ""
echo "[6] Node直接测试HTTPS.createServer（避开一切）:"
node -e "
const fs = require('fs');
const https = require('https');
try {
  const opts = {
    key: fs.readFileSync('/opt/reading-checkin/ssl/zhengpintang.cn.key'),
    cert: fs.readFileSync('/opt/reading-checkin/ssl/zhengpintang.cn_bundle.crt')
  };
  console.log('  key长度:', opts.key.length);
  console.log('  cert长度:', opts.cert.length);
  console.log('  cert前40:', JSON.stringify(opts.cert.slice(0, 40).toString()));
  console.log('  cert后40:', JSON.stringify(opts.cert.slice(-40).toString()));
  const s = https.createServer(opts, (req, res) => res.end('ok'));
  s.on('error', e => { console.error('  ❌ HTTPS错误:', e.message); process.exit(1); });
  s.listen(0, () => { console.log('  ✅ HTTPS.createServer成功'); s.close(() => process.exit(0)); });
} catch (e) {
  console.error('  ❌ 读取或创建失败:', e.message);
  process.exit(1);
}
" 2>&1
