'use strict';

const { isIP } = require('node:net');
const { createHmac, randomBytes, randomUUID } = require('node:crypto');

const FEEDBACK_PATH = '/api/wifiusage/feedback';
const DIAGNOSTICS_FILENAME = 'WiFiUsage-diagnostics.txt';
const DIAGNOSTICS_FORMAT = 'wifiusage-log-v1';
const MAX_DIAGNOSTICS_BYTES = 32 * 1024;
const MAX_REQUEST_BYTES = 48 * 1024;
const REPORT_DEDUP_WINDOW_MS = 24 * 60 * 60 * 1000;
const DELIVERY_TIMEOUT_MS = 30 * 1000;
const MAX_REPORT_RECEIPTS = 1_000;
const MAX_COMPLETED_REPORT_RECEIPTS = 10_000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const SAFE_DELIVERY_ERROR_CODES = new Set([
  'EAI_AGAIN',
  'EAUTH',
  'ECONNECTION',
  'ECONNREFUSED',
  'ECONNRESET',
  'EDNS',
  'EENVELOPE',
  'EMESSAGE',
  'ENOTFOUND',
  'ESOCKET',
  'ETIMEDOUT',
]);

const FEEDBACK_TYPES = new Set([
  '无法打开应用',
  '无法识别 Wi-Fi',
  '用量显示不准确',
  '套餐或计费问题',
  '网页或下载问题',
  '功能建议',
  '其他问题',
]);

const DIAGNOSTIC_EVENTS = new Set([
  'app.launch',
  'database.open.succeeded',
  'database.open.failed',
  'database.refresh.failed',
  'database.write.failed',
  'wifi.resolve.changed',
  'wifi.sampler.started',
  'wifi.sampler.failed',
  'application_sampler.started',
  'application_sampler.running',
  'application_sampler.stopped',
  'application_sampler.failed',
  'application_sampler.save.failed',
  'plan.assignment.failed',
  'plan.save.failed',
  'login_item.update.failed',
  'database.legacy_import.failed',
  'feedback.send.started',
  'feedback.send.succeeded',
  'feedback.send.failed',
  'diagnostics.logs.cleared',
]);
const DIAGNOSTIC_LEVELS = new Set(['info', 'warning', 'error']);
const DIAGNOSTIC_ERROR_DOMAINS = new Set([
  'sqlite', 'interface_counters', 'process_sampler', 'launch_at_login',
  'feedback_network', 'filesystem', 'unknown',
]);
const DIAGNOSTIC_WIFI_SOURCES = new Set(['none', 'corewlan', 'ipconfig']);
const DIAGNOSTIC_APP_FAILURES = new Set([
  'unavailable', 'command_failed', 'incomplete_output', 'unknown',
]);
const DIAGNOSTIC_METADATA_KEYS = new Set([
  'errorDomain', 'numericCode', 'retryCount', 'connected', 'wifiNameIdentified',
  'wifiResolutionSource', 'applicationFailureKind', 'preciseMode',
  'diagnosticsIncluded', 'httpStatusClass',
]);
const ISO8601_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/;
const SAFE_VERSION_PATTERN = /^(?:unknown|[0-9]{1,4}(?:\.[0-9]{1,4}){0,3}(?:-[0-9A-Za-z.-]{1,20})?)$/;
const SAFE_BUILD_PATTERN = /^(?:unknown|[0-9]{1,9})$/;
const SAFE_OS_PATTERN = /^macOS [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/;

const LIMIT_WINDOW_MS = 10 * 60 * 1000;
const LIMIT_PER_WINDOW = 5;

function cleanText(value, maxLength) {
  return typeof value === 'string'
    ? value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim().slice(0, maxLength)
    : '';
}

function redactDiagnostics(value) {
  const redacted = value
    .replace(/\bhttps?:\/\/[^\s<>'"]+/gi, '<redacted-url>')
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '<redacted-email>')
    .replace(/\/Users\/[^/\s]+/g, '~')
    .replace(/\b(?:SSID|BSSID)\s*[:=]\s*[^\r\n]+/gi, (match) => `${match.split(/\s*[:=]\s*/, 1)[0]}=<redacted>`)
    .replace(/\b(?:DEVELOPMENT_TEAM|TeamIdentifier|com\.apple\.developer\.team-identifier)\s*[:=]\s*[A-Z0-9.-]+/gi, (match) => `${match.split(/\s*[:=]\s*/, 1)[0]}=<redacted>`)
    .replace(/\b(?:Developer ID(?: Application| Installer)?|Signing Identity|Authority)\s*[:=]\s*[^\r\n]+/gi, (match) => `${match.split(/\s*[:=]\s*/, 1)[0]}=<redacted>`)
    .replace(/\([A-Z0-9]{10}\)/g, '(<redacted-team>)')
    .replace(/\b(?:user(?:name)?)\s*[:=]\s*[^\s,;]+/gi, (match) => `${match.split(/\s*[:=]\s*/, 1)[0]}=<redacted>`)
    .replace(/\b(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\b/gi, '<redacted-mac>');

  return redacted.replace(/[0-9A-F:.]+/gi, (candidate) => (
    isIP(candidate) ? '<redacted-ip>' : candidate
  ));
}

function isISO8601(value) {
  return typeof value === 'string'
    && ISO8601_PATTERN.test(value)
    && Number.isFinite(Date.parse(value));
}

function isBooleanText(value) {
  return value === 'true' || value === 'false';
}

function validateDiagnosticMetadata(metadata) {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) return false;
  if (Object.keys(metadata).some((key) => !DIAGNOSTIC_METADATA_KEYS.has(key))) return false;
  if (metadata.errorDomain !== undefined && !DIAGNOSTIC_ERROR_DOMAINS.has(metadata.errorDomain)) return false;
  if (metadata.numericCode !== undefined
    && (!Number.isSafeInteger(metadata.numericCode) || Math.abs(metadata.numericCode) > 2_147_483_647)) return false;
  if (metadata.retryCount !== undefined
    && (!Number.isSafeInteger(metadata.retryCount) || metadata.retryCount < 0 || metadata.retryCount > 1_000_000)) return false;
  for (const key of ['connected', 'wifiNameIdentified', 'preciseMode', 'diagnosticsIncluded']) {
    if (metadata[key] !== undefined && typeof metadata[key] !== 'boolean') return false;
  }
  if (metadata.wifiResolutionSource !== undefined
    && !DIAGNOSTIC_WIFI_SOURCES.has(metadata.wifiResolutionSource)) return false;
  if (metadata.applicationFailureKind !== undefined
    && !DIAGNOSTIC_APP_FAILURES.has(metadata.applicationFailureKind)) return false;
  if (metadata.httpStatusClass !== undefined
    && (!Number.isSafeInteger(metadata.httpStatusClass)
      || metadata.httpStatusClass < 1 || metadata.httpStatusClass > 5)) return false;
  return true;
}

function validateDiagnosticEvent(line) {
  let event;
  try {
    event = JSON.parse(line);
  } catch (_) {
    return false;
  }
  if (!event || typeof event !== 'object' || Array.isArray(event)) return false;
  const keys = Object.keys(event);
  const required = ['timestamp', 'level', 'event', 'metadata', 'repeatCount'];
  if (keys.length !== required.length || required.some((key) => !keys.includes(key))) return false;
  return isISO8601(event.timestamp)
    && DIAGNOSTIC_LEVELS.has(event.level)
    && DIAGNOSTIC_EVENTS.has(event.event)
    && validateDiagnosticMetadata(event.metadata)
    && Number.isSafeInteger(event.repeatCount)
    && event.repeatCount >= 1
    && event.repeatCount <= 1_000_000;
}

function validateDiagnosticReport(value, generatedAt) {
  if (typeof value !== 'string' || !value || value.includes('\r')) {
    return validationError('诊断日志格式无效。');
  }
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(value)) {
    return validationError('诊断日志包含无效字符。');
  }
  if (!isISO8601(generatedAt)) {
    return validationError('诊断日志生成时间无效。');
  }

  const lines = value.split('\n');
  if (lines.at(-1) === '') lines.pop();
  let cursor = 0;
  const take = (prefix, validator) => {
    const line = lines[cursor++];
    if (typeof line !== 'string' || !line.startsWith(prefix)) return false;
    const fieldValue = line.slice(prefix.length);
    return validator(fieldValue);
  };

  if (!take('format=', (item) => item === DIAGNOSTICS_FORMAT)
    || !take('generated_at=', (item) => item === generatedAt && isISO8601(item))
    || !take('app_version=', (item) => SAFE_VERSION_PATTERN.test(item))
    || !take('app_build=', (item) => SAFE_BUILD_PATTERN.test(item))
    || !take('distribution=', (item) => ['Personal', 'PublicTest', 'PublicRelease'].includes(item))
    || !take('os_version=', (item) => SAFE_OS_PATTERN.test(item))
    || !take('architecture=', (item) => ['arm64', 'x86_64', 'unknown'].includes(item))
    || !take('repository_ready=', isBooleanText)
    || !take('wifi_state=', (item) => ['disconnected', 'connected_without_name', 'identified'].includes(item))
    || !take('physical_sampling=', isBooleanText)
    || !take('application_sampling=', (item) => ['stopped', 'starting', 'running', 'failed'].includes(item))
    || !take('privacy=', (item) => item === 'sensitive_names,paths,traffic,plans,contact_not_collected')
    || lines[cursor++] !== 'events:') {
    return validationError('诊断日志格式无效。');
  }

  let eventCount = 0;
  if (lines[cursor] === 'none') {
    cursor += 1;
  } else {
    while (cursor < lines.length && !lines[cursor].startsWith('truncated=')) {
      if (eventCount >= 1_000 || !validateDiagnosticEvent(lines[cursor])) {
        return validationError('诊断日志事件格式无效。');
      }
      eventCount += 1;
      cursor += 1;
    }
  }

  if (!/^truncated=(?:true|false)$/.test(lines[cursor] || '') || cursor !== lines.length - 1) {
    return validationError('诊断日志结尾无效。');
  }

  return { value: redactDiagnostics(value) };
}

function requestByteLength(body) {
  try {
    return Buffer.byteLength(JSON.stringify(body), 'utf8');
  } catch (_) {
    return Number.POSITIVE_INFINITY;
  }
}

function validationError(message, code = 'validation_error', status = 400) {
  return { error: message, code, status };
}

function safeDeliveryErrorCode(error) {
  return SAFE_DELIVERY_ERROR_CODES.has(error?.code) ? error.code : 'delivery_failed';
}

function withTimeout(promise, timeoutMs) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error('delivery timed out');
      error.code = 'ETIMEDOUT';
      reject(error);
    }, timeoutMs);
  });
  return Promise.race([Promise.resolve(promise), timeout]).finally(() => clearTimeout(timer));
}

function validateFeedback(body = {}) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return validationError('请求内容无效。');
  }

  const requestedSource = cleanText(body.source, 24);
  if (requestedSource && requestedSource !== 'website' && requestedSource !== 'mac-app') {
    return validationError('请求来源类型无效。');
  }

  const source = requestedSource || 'website';
  const hasReportID = body.reportID !== undefined && body.reportID !== null;
  if (hasReportID && (typeof body.reportID !== 'string' || !UUID_PATTERN.test(body.reportID))) {
    return validationError('报告编号格式无效。');
  }
  const reportID = hasReportID ? body.reportID.toLowerCase() : '';
  const type = FEEDBACK_TYPES.has(body.type) ? body.type : '其他问题';
  const message = cleanText(body.message, 2000);
  const system = cleanText(body.system, 80);
  const device = cleanText(body.device, 80);
  const wantsReply = body.wantsReply === true;
  const contact = wantsReply ? cleanText(body.contact, 160) : '';
  const company = cleanText(body.company, 200);
  const appVersion = source === 'mac-app' ? cleanText(body.appVersion, 40) : '';
  const appBuild = source === 'mac-app' ? cleanText(body.appBuild, 40) : '';
  const includeDiagnostics = source === 'mac-app' && body.includeDiagnostics === true;

  if (!message) {
    return validationError('请填写问题描述。');
  }
  if (wantsReply && contact.length < 3) {
    return validationError('希望收到回复时，请留下有效联系方式。');
  }
  if (source === 'mac-app') {
    if (body.schemaVersion !== 1) {
      return validationError('反馈格式版本无效。');
    }
    if (!SAFE_OS_PATTERN.test(system)
      || !['arm64', 'x86_64', 'unknown'].includes(device)
      || !SAFE_VERSION_PATTERN.test(appVersion)
      || !SAFE_BUILD_PATTERN.test(appBuild)) {
      return validationError('软件环境信息格式无效。');
    }
  }

  let diagnostics = null;
  if (includeDiagnostics) {
    if (!body.diagnostics || typeof body.diagnostics !== 'object' || Array.isArray(body.diagnostics)) {
      return validationError('诊断日志格式无效。');
    }

    const rawContent = body.diagnostics.content;
    if (typeof rawContent !== 'string' || !rawContent) {
      return validationError('没有可以发送的诊断日志。');
    }
    if (Buffer.byteLength(rawContent, 'utf8') > MAX_DIAGNOSTICS_BYTES) {
      return validationError('诊断日志过大，请缩短后重试。', 'diagnostics_too_large', 413);
    }

    if (body.diagnostics.format !== DIAGNOSTICS_FORMAT) {
      return validationError('诊断日志格式无效。');
    }
    const generatedAt = cleanText(body.diagnostics.generatedAt, 40);
    const diagnosticResult = validateDiagnosticReport(rawContent, generatedAt);
    if (diagnosticResult.error) return diagnosticResult;
    diagnostics = {
      generatedAt,
      format: DIAGNOSTICS_FORMAT,
      content: diagnosticResult.value,
    };
  }

  return {
    value: {
      source,
      reportID,
      type,
      message,
      system,
      device,
      wantsReply,
      contact,
      company,
      appVersion,
      appBuild,
      includeDiagnostics,
      diagnostics,
    },
  };
}

function formatFeedbackText(feedback) {
  const sourceLabel = feedback.source === 'mac-app' ? 'macOS 应用' : '官网';
  const lines = [
    'WiFiUsage 收到一条新反馈',
    '',
    `反馈编号：${feedback.feedbackID || '未生成'}`,
    `反馈来源：${sourceLabel}`,
    `问题类型：${feedback.type}`,
    `希望回复：${feedback.wantsReply ? '是' : '否'}`,
    `联系方式：${feedback.wantsReply ? feedback.contact : '未留下'}`,
    `macOS 版本：${feedback.system || '未填写'}`,
    `Mac 型号或芯片：${feedback.device || '未填写'}`,
  ];

  if (feedback.source === 'mac-app') {
    lines.push(
      `应用版本：${feedback.appVersion || '未知'}`,
      `应用构建：${feedback.appBuild || '未知'}`,
      `附带诊断日志：${feedback.includeDiagnostics ? '是' : '否'}`,
    );
    if (feedback.includeDiagnostics && feedback.diagnostics?.generatedAt) {
      lines.push(`日志生成时间：${feedback.diagnostics.generatedAt}`);
    }
  }

  lines.push(
    '',
    '问题描述：',
    feedback.message,
    '',
    '此邮件由 xjp.one 的 WiFiUsage 反馈接口发送。',
  );
  return lines.join('\n');
}

function clientKey(req, salt) {
  const address = String(req.ip || req.socket?.remoteAddress || 'unknown').slice(0, 256);
  return createHmac('sha256', salt).update(address).digest('hex');
}

function requestHeader(req, name) {
  const fromExpress = req.get?.(name);
  if (typeof fromExpress === 'string') return fromExpress;
  const value = req.headers?.[name.toLowerCase()];
  return typeof value === 'string' ? value : '';
}

function isJSONRequest(req) {
  return /^application\/json(?:\s*;|\s*$)/i.test(requestHeader(req, 'content-type'));
}

function respondError(res, status, code, message) {
  res.set('Cache-Control', 'no-store');
  return res.status(status).json({ success: false, code, message });
}

function createWiFiUsageFeedbackHandler(options) {
  const {
    transporter,
    fromAddress,
    toAddress,
    allowedOrigin = 'https://xjp.one',
    logger = console,
    now = () => Date.now(),
    deliveryTimeoutMs = DELIVERY_TIMEOUT_MS,
    maximumReportReceipts = MAX_REPORT_RECEIPTS,
    maximumCompletedReportReceipts = MAX_COMPLETED_REPORT_RECEIPTS,
  } = options || {};
  const attempts = new Map();
  const reportReceipts = new Map();
  const clientKeySalt = randomBytes(32);
  const pendingLimit = Number.isSafeInteger(maximumReportReceipts)
    ? Math.max(1, maximumReportReceipts)
    : MAX_REPORT_RECEIPTS;
  const completedLimit = Number.isSafeInteger(maximumCompletedReportReceipts)
    ? Math.max(1, maximumCompletedReportReceipts)
    : MAX_COMPLETED_REPORT_RECEIPTS;
  const responseTimeoutMs = Number.isFinite(deliveryTimeoutMs)
    ? Math.max(1, deliveryTimeoutMs)
    : DELIVERY_TIMEOUT_MS;
  let pendingDeliveryCount = 0;
  let lastReceiptCleanup = 0;
  let lastAttemptCleanup = 0;

  function trimCompletedReceipts() {
    const completed = [];
    for (const [reportID, receipt] of reportReceipts) {
      if (receipt.state === 'delivered') completed.push([reportID, receipt]);
    }
    if (completed.length <= completedLimit) return;
    completed.sort((left, right) => left[1].expiresAt - right[1].expiresAt);
    for (let index = 0; index < completed.length - completedLimit; index += 1) {
      reportReceipts.delete(completed[index][0]);
    }
  }

  return async function wifiUsageFeedback(req, res) {
    res.set('Cache-Control', 'no-store');

    if (!isJSONRequest(req)) {
      return respondError(res, 415, 'invalid_content_type', '请使用 application/json 提交反馈。');
    }

    const declaredLength = Number(requestHeader(req, 'content-length'));
    if ((Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES)
      || requestByteLength(req.body) > MAX_REQUEST_BYTES) {
      return respondError(res, 413, 'payload_too_large', '反馈内容过大，请缩短后重试。');
    }

    const origin = requestHeader(req, 'origin');
    if (origin && origin !== allowedOrigin) {
      return respondError(res, 403, 'invalid_origin', '请求来源无效。');
    }

    const result = validateFeedback(req.body);
    if (result.error) {
      return respondError(res, result.status || 400, result.code || 'validation_error', result.error);
    }

    const feedback = result.value;
    if (feedback.company) {
      return res.status(202).json({ success: true, feedbackID: randomUUID() });
    }

    const timestamp = now();
    const cutoff = timestamp - LIMIT_WINDOW_MS;
    if (timestamp - lastReceiptCleanup >= LIMIT_WINDOW_MS) {
      for (const [storedReportID, receipt] of reportReceipts) {
        if (receipt.expiresAt <= timestamp) reportReceipts.delete(storedReportID);
      }
      lastReceiptCleanup = timestamp;
    }

    if (timestamp - lastAttemptCleanup >= 60 * 1000) {
      for (const [storedKey, values] of attempts) {
        const active = values.filter((item) => item > cutoff);
        if (active.length) attempts.set(storedKey, active);
        else attempts.delete(storedKey);
      }
      lastAttemptCleanup = timestamp;
    }

    const existingReceipt = feedback.reportID ? reportReceipts.get(feedback.reportID) : null;
    if (existingReceipt && existingReceipt.expiresAt > timestamp) {
      try {
        await withTimeout(existingReceipt.delivery, responseTimeoutMs);
        return res.status(202).json({ success: true, feedbackID: existingReceipt.feedbackID });
      } catch (_) {
        return respondError(res, 502, 'delivery_failed', '邮件没有送达，请稍后再试。');
      }
    }

    if (!transporter || !fromAddress || !toAddress) {
      return respondError(res, 503, 'service_unavailable', '反馈服务暂时不可用，请稍后再试。');
    }
    if (pendingDeliveryCount >= pendingLimit) {
      return respondError(res, 503, 'service_busy', '反馈服务暂时繁忙，请稍后再试。');
    }

    const key = clientKey(req, clientKeySalt);
    const recent = (attempts.get(key) || []).filter((item) => item > cutoff);
    if (recent.length >= LIMIT_PER_WINDOW) {
      return respondError(res, 429, 'rate_limited', '发送得有点频繁，请稍后再试。');
    }
    recent.push(timestamp);
    attempts.set(key, recent);

    const feedbackID = randomUUID();
    const mail = {
      from: `WiFiUsage 反馈 <${fromAddress}>`,
      to: toAddress,
      subject: `[WiFiUsage 反馈] ${feedback.type}`,
      text: formatFeedbackText({ ...feedback, feedbackID }),
    };
    if (feedback.includeDiagnostics && feedback.diagnostics) {
      mail.attachments = [{
        filename: DIAGNOSTICS_FILENAME,
        content: feedback.diagnostics.content,
        contentType: 'text/plain; charset=utf-8',
      }];
    }

    // The response timeout below cannot cancel Nodemailer. Keep the raw delivery
    // attached to its report ID until it definitively settles so a retry cannot
    // start a second email while the first one may still be accepted upstream.
    const delivery = Promise.resolve().then(() => transporter.sendMail(mail));
    pendingDeliveryCount += 1;
    let receipt = null;
    if (feedback.reportID) {
      receipt = {
        feedbackID,
        delivery,
        state: 'pending',
        expiresAt: Number.POSITIVE_INFINITY,
      };
      reportReceipts.set(feedback.reportID, receipt);
    }

    delivery.then(
      () => {
        pendingDeliveryCount = Math.max(0, pendingDeliveryCount - 1);
        if (feedback.reportID && reportReceipts.get(feedback.reportID) === receipt) {
          receipt.state = 'delivered';
          receipt.expiresAt = now() + REPORT_DEDUP_WINDOW_MS;
          trimCompletedReceipts();
        }
        logger.info?.(`[WiFiUsage feedback] accepted source=${feedback.source} type=${feedback.type} wantsReply=${feedback.wantsReply} diagnostics=${feedback.includeDiagnostics}`);
      },
      (error) => {
        pendingDeliveryCount = Math.max(0, pendingDeliveryCount - 1);
        if (feedback.reportID && reportReceipts.get(feedback.reportID) === receipt) {
          reportReceipts.delete(feedback.reportID);
        }
        logger.error?.(`[WiFiUsage feedback] delivery failed code=${safeDeliveryErrorCode(error)}`);
      },
    );

    try {
      await withTimeout(delivery, responseTimeoutMs);
      return res.status(202).json({ success: true, feedbackID });
    } catch (_) {
      return respondError(res, 502, 'delivery_failed', '邮件没有送达，请稍后再试。');
    }
  };
}

function isFeedbackRequest(req, routePath) {
  const rawPath = req.originalUrl || req.url || req.path || '';
  const requestPath = rawPath.split('?', 1)[0].replace(/\/+$/, '') || '/';
  const expectedPath = routePath.replace(/\/+$/, '') || '/';
  return requestPath === expectedPath;
}

function createWiFiUsageFeedbackErrorHandler(options = {}) {
  const {
    logger = console,
    routePath = FEEDBACK_PATH,
  } = options;

  return function wifiUsageFeedbackErrorHandler(error, req, res, next) {
    if (!isFeedbackRequest(req, routePath) || res.headersSent) {
      return next(error);
    }

    if (error?.status === 413 || error?.statusCode === 413 || error?.type === 'entity.too.large') {
      return respondError(res, 413, 'payload_too_large', '反馈内容过大，请缩短后重试。');
    }
    if (error?.status === 400 && (error?.type === 'entity.parse.failed' || error instanceof SyntaxError)) {
      return respondError(res, 400, 'invalid_json', '反馈内容不是有效的 JSON。');
    }

    logger.error?.('[WiFiUsage feedback] request failed code=internal_error');
    return respondError(res, 500, 'internal_error', '反馈服务暂时出现错误，请稍后再试。');
  };
}

function registerWiFiUsageFeedback(app, options) {
  app.post(FEEDBACK_PATH, createWiFiUsageFeedbackHandler(options));
  app.use(createWiFiUsageFeedbackErrorHandler({
    logger: options?.logger,
    routePath: FEEDBACK_PATH,
  }));
}

module.exports = {
  DIAGNOSTICS_FILENAME,
  DIAGNOSTICS_FORMAT,
  DELIVERY_TIMEOUT_MS,
  FEEDBACK_PATH,
  MAX_COMPLETED_REPORT_RECEIPTS,
  MAX_DIAGNOSTICS_BYTES,
  MAX_REQUEST_BYTES,
  MAX_REPORT_RECEIPTS,
  REPORT_DEDUP_WINDOW_MS,
  createWiFiUsageFeedbackErrorHandler,
  createWiFiUsageFeedbackHandler,
  formatFeedbackText,
  redactDiagnostics,
  registerWiFiUsageFeedback,
  validateDiagnosticReport,
  validateFeedback,
};
