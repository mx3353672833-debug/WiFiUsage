'use strict';

const FEEDBACK_TYPES = new Set([
  '无法打开应用',
  '无法识别 Wi-Fi',
  '用量显示不准确',
  '套餐或计费问题',
  '网页或下载问题',
  '功能建议',
  '其他问题',
]);

const LIMIT_WINDOW_MS = 10 * 60 * 1000;
const LIMIT_PER_WINDOW = 5;

function cleanText(value, maxLength) {
  return typeof value === 'string'
    ? value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim().slice(0, maxLength)
    : '';
}

function validateFeedback(body = {}) {
  const type = FEEDBACK_TYPES.has(body.type) ? body.type : '其他问题';
  const message = cleanText(body.message, 2000);
  const system = cleanText(body.system, 80);
  const device = cleanText(body.device, 80);
  const wantsReply = body.wantsReply === true;
  const contact = wantsReply ? cleanText(body.contact, 160) : '';
  const company = cleanText(body.company, 200);

  if (!message) {
    return { error: '请填写问题描述。' };
  }
  if (wantsReply && contact.length < 3) {
    return { error: '希望收到回复时，请留下有效联系方式。' };
  }

  return { value: { type, message, system, device, wantsReply, contact, company } };
}

function formatFeedbackText(feedback) {
  return [
    'WiFiUsage 官网收到一条新反馈',
    '',
    `问题类型：${feedback.type}`,
    `希望回复：${feedback.wantsReply ? '是' : '否'}`,
    `联系方式：${feedback.wantsReply ? feedback.contact : '未留下'}`,
    `macOS 版本：${feedback.system || '未填写'}`,
    `Mac 型号或芯片：${feedback.device || '未填写'}`,
    '',
    '问题描述：',
    feedback.message,
    '',
    '此邮件由 xjp.one 的 WiFiUsage 反馈接口发送。',
  ].join('\n');
}

function clientKey(req) {
  const forwarded = req.headers?.['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded) return forwarded.split(',')[0].trim();
  return req.socket?.remoteAddress || 'unknown';
}

function createWiFiUsageFeedbackHandler(options) {
  const {
    transporter,
    fromAddress,
    toAddress,
    allowedOrigin = 'https://xjp.one',
    logger = console,
    now = () => Date.now(),
  } = options || {};
  const attempts = new Map();

  return async function wifiUsageFeedback(req, res) {
    res.set('Cache-Control', 'no-store');

    const origin = req.get?.('origin');
    if (origin && origin !== allowedOrigin) {
      return res.status(403).json({ success: false, message: '请求来源无效。' });
    }

    const result = validateFeedback(req.body);
    if (result.error) {
      return res.status(400).json({ success: false, message: result.error });
    }

    const feedback = result.value;
    if (feedback.company) {
      return res.status(202).json({ success: true });
    }

    if (!transporter || !fromAddress || !toAddress) {
      return res.status(503).json({ success: false, message: '反馈服务暂时不可用，请稍后再试。' });
    }

    const timestamp = now();
    const cutoff = timestamp - LIMIT_WINDOW_MS;
    const key = clientKey(req);
    const recent = (attempts.get(key) || []).filter((item) => item > cutoff);
    if (recent.length >= LIMIT_PER_WINDOW) {
      return res.status(429).json({ success: false, message: '发送得有点频繁，请稍后再试。' });
    }
    recent.push(timestamp);
    attempts.set(key, recent);

    if (attempts.size > 5000) {
      for (const [storedKey, values] of attempts) {
        const active = values.filter((item) => item > cutoff);
        if (active.length) attempts.set(storedKey, active);
        else attempts.delete(storedKey);
      }
    }

    try {
      await transporter.sendMail({
        from: `WiFiUsage 反馈 <${fromAddress}>`,
        to: toAddress,
        subject: `[WiFiUsage 反馈] ${feedback.type}`,
        text: formatFeedbackText(feedback),
      });
      logger.info?.(`[WiFiUsage feedback] accepted type=${feedback.type} wantsReply=${feedback.wantsReply}`);
      return res.status(202).json({ success: true });
    } catch (error) {
      logger.error?.('[WiFiUsage feedback] delivery failed:', error?.message || error);
      return res.status(502).json({ success: false, message: '邮件没有送达，请稍后再试。' });
    }
  };
}

function registerWiFiUsageFeedback(app, options) {
  app.post('/api/wifiusage/feedback', createWiFiUsageFeedbackHandler(options));
}

module.exports = {
  createWiFiUsageFeedbackHandler,
  formatFeedbackText,
  registerWiFiUsageFeedback,
  validateFeedback,
};
