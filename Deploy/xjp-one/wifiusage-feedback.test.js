'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  DIAGNOSTICS_FILENAME,
  MAX_DIAGNOSTICS_BYTES,
  MAX_REQUEST_BYTES,
  REPORT_DEDUP_WINDOW_MS,
  createWiFiUsageFeedbackErrorHandler,
  createWiFiUsageFeedbackHandler,
  formatFeedbackText,
  registerWiFiUsageFeedback,
  validateDiagnosticReport,
  validateFeedback,
} = require('./wifiusage-feedback');

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function responseRecorder() {
  return {
    statusCode: 200,
    headers: {},
    body: null,
    headersSent: false,
    set(name, value) { this.headers[name] = value; return this; },
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
}

function request(body, overrides = {}) {
  const headers = {
    'content-type': 'application/json',
    ...(overrides.headers || {}),
  };
  return {
    body,
    headers,
    ip: '127.0.0.1',
    socket: { remoteAddress: '127.0.0.1' },
    originalUrl: '/api/wifiusage/feedback',
    get(name) { return headers[name.toLowerCase()] || ''; },
    ...overrides,
    headers,
  };
}

function handlerOptions(deliveries = []) {
  return {
    transporter: { sendMail: async (mail) => deliveries.push(mail) },
    fromAddress: 'sender@example.test',
    toAddress: 'private-recipient@example.test',
    logger: { info() {}, error() {} },
  };
}

function nativeFeedback(overrides = {}) {
  return {
    schemaVersion: 1,
    source: 'mac-app',
    system: 'macOS 26.5.2',
    device: 'arm64',
    appVersion: '1.1.0',
    appBuild: '2',
    ...overrides,
  };
}

function diagnosticReport(generatedAt = '2026-08-01T12:00:00Z') {
  return [
    'format=wifiusage-log-v1',
    `generated_at=${generatedAt}`,
    'app_version=1.1.0',
    'app_build=2',
    'distribution=PublicRelease',
    'os_version=macOS 26.5.2',
    'architecture=arm64',
    'repository_ready=true',
    'wifi_state=connected_without_name',
    'physical_sampling=true',
    'application_sampling=running',
    'privacy=sensitive_names,paths,traffic,plans,contact_not_collected',
    'events:',
    JSON.stringify({
      timestamp: generatedAt,
      level: 'error',
      event: 'wifi.sampler.failed',
      metadata: { errorDomain: 'interface_counters', numericCode: 5 },
      repeatCount: 2,
    }),
    'truncated=false',
    '',
  ].join('\n');
}

test('keeps the original website schema compatible', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));
  const response = responseRecorder();

  await handler(request({
    type: '网页或下载问题',
    message: '下载按钮点击以后没有开始下载',
    wantsReply: false,
  }, { headers: { 'content-type': 'application/json', origin: 'https://xjp.one' } }), response);

  assert.equal(response.statusCode, 202);
  assert.equal(response.body.success, true);
  assert.match(response.body.feedbackID, UUID_PATTERN);
  assert.equal(deliveries.length, 1);
  assert.equal(deliveries[0].to, 'private-recipient@example.test');
  assert.equal(deliveries[0].attachments, undefined);
  assert.match(deliveries[0].text, /反馈来源：官网/);
});

test('requires a non-empty message and keeps unknown types out of the subject', () => {
  assert.equal(validateFeedback({ message: '   ' }).error, '请填写问题描述。');
  assert.equal(validateFeedback({ message: '卡' }).error, undefined);
  assert.match(validateFeedback({ message: '卡', wantsReply: true }).error, /联系方式/);
  const result = validateFeedback({ type: 'Bad\r\nBcc: x', message: '卡' });
  assert.equal(result.value.type, '其他问题');
});

test('formats contact only when a reply is requested', () => {
  const text = formatFeedbackText({
    source: 'website',
    type: '功能建议',
    message: '希望增加菜单栏显示方式',
    system: '',
    device: '',
    wantsReply: false,
    contact: 'should-not-appear',
  });
  assert.match(text, /联系方式：未留下/);
  assert.doesNotMatch(text, /should-not-appear/);
});

test('accepts a native request without Origin and attaches the exact validated report', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));
  const response = responseRecorder();
  const generatedAt = '2026-08-01T12:00:00Z';
  const safeLog = diagnosticReport(generatedAt);

  await handler(request({
    schemaVersion: 1,
    source: 'mac-app',
    reportID: '01234567-89ab-4cde-8f01-23456789abcd',
    type: '无法识别 Wi-Fi',
    message: '切换网络后没有识别',
    system: 'macOS 26.5.2',
    device: 'arm64',
    appVersion: '1.1.0',
    appBuild: '12',
    wantsReply: false,
    includeDiagnostics: true,
    diagnostics: {
      generatedAt,
      format: 'wifiusage-log-v1',
      content: safeLog,
      filename: '../../not-allowed.txt',
      contentType: 'application/octet-stream',
    },
  }), response);

  assert.equal(response.statusCode, 202);
  assert.match(response.body.feedbackID, UUID_PATTERN);
  assert.equal(deliveries.length, 1);
  assert.match(deliveries[0].text, /反馈来源：macOS 应用/);
  assert.match(deliveries[0].text, new RegExp(`反馈编号：${response.body.feedbackID}`));
  assert.match(deliveries[0].text, /应用版本：1\.1\.0/);
  assert.equal(deliveries[0].attachments.length, 1);
  assert.equal(deliveries[0].attachments[0].filename, DIAGNOSTICS_FILENAME);
  assert.equal(deliveries[0].attachments[0].contentType, 'text/plain; charset=utf-8');
  assert.equal(deliveries[0].attachments[0].content, safeLog);
});

test('rejects arbitrary diagnostic text and unknown event fields', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));
  const unsafeResponse = responseRecorder();
  const generatedAt = '2026-08-01T12:00:00Z';

  await handler(request(nativeFeedback({
    message: '日志校验',
    includeDiagnostics: true,
    diagnostics: {
      generatedAt,
      format: 'wifiusage-log-v1',
      content: '~/Documents/secret.xlsx Safari pid=42 com.apple.Safari traffic=999 plan=private',
    },
  })), unsafeResponse);

  assert.equal(unsafeResponse.statusCode, 400);
  assert.equal(deliveries.length, 0);

  const valid = diagnosticReport(generatedAt);
  const lines = valid.trimEnd().split('\n');
  const event = JSON.parse(lines[13]);
  event.processName = 'Safari';
  lines[13] = JSON.stringify(event);
  const unknownField = validateDiagnosticReport(`${lines.join('\n')}\n`, generatedAt);
  assert.match(unknownField.error, /事件格式/);
});

test('requires diagnostics format and matching generated time', () => {
  const generatedAt = '2026-08-01T12:00:00Z';
  const missingFormat = validateFeedback(nativeFeedback({
    message: '格式测试',
    includeDiagnostics: true,
    diagnostics: { generatedAt, content: diagnosticReport(generatedAt) },
  }));
  assert.match(missingFormat.error, /格式/);

  const mismatched = validateDiagnosticReport(
    diagnosticReport(generatedAt),
    '2026-08-01T12:00:01Z',
  );
  assert.match(mismatched.error, /格式/);
});

test('requires the native schema version and fixed environment formats', () => {
  for (const payload of [
    nativeFeedback({ schemaVersion: undefined, message: '缺少格式版本' }),
    nativeFeedback({ schemaVersion: 2, message: '未知格式版本' }),
    nativeFeedback({ system: 'MyHomeWiFi', message: '伪造系统信息' }),
    nativeFeedback({ device: 'MacBook Air / arm64', message: '伪造设备信息' }),
    nativeFeedback({ appVersion: 'ABCDEFGHIJ', message: '伪造版本信息' }),
    nativeFeedback({ appBuild: 'private-build', message: '伪造构建信息' }),
  ]) {
    assert.match(validateFeedback(payload).error, /格式|环境/);
  }
  assert.equal(validateFeedback(nativeFeedback({ message: '有效反馈' })).error, undefined);
});

test('drops diagnostics unless the native user explicitly includes them', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));
  const response = responseRecorder();

  await handler(request(nativeFeedback({
    message: '只发送描述',
    includeDiagnostics: false,
    diagnostics: { content: 'must-not-be-sent' },
  })), response);

  assert.equal(response.statusCode, 202);
  assert.equal(deliveries[0].attachments, undefined);
  assert.doesNotMatch(deliveries[0].text, /must-not-be-sent/);
});

test('requires reportID to be a strict UUID when supplied', async () => {
  const handler = createWiFiUsageFeedbackHandler(handlerOptions());
  const response = responseRecorder();

  await handler(request(nativeFeedback({
    reportID: ' 01234567-89ab-4cde-8f01-23456789abcd ',
    message: '编号不合法',
  })), response);

  assert.equal(response.statusCode, 400);
  assert.equal(response.body.code, 'validation_error');
  assert.match(response.body.message, /报告编号/);
});

test('deduplicates the same reportID for 24 hours and returns the same feedbackID', async () => {
  const deliveries = [];
  let timestamp = 1_000_000;
  const handler = createWiFiUsageFeedbackHandler({
    ...handlerOptions(deliveries),
    now: () => timestamp,
  });
  const body = nativeFeedback({
    reportID: '11234567-89ab-4cde-8f01-23456789abcd',
    message: '同一个问题自动重试',
  });

  const first = responseRecorder();
  await handler(request(body), first);
  timestamp += REPORT_DEDUP_WINDOW_MS - 1;
  const duplicate = responseRecorder();
  await handler(request({ ...body, message: '重试时描述即使变化也不应重复发信' }), duplicate);

  assert.equal(first.statusCode, 202);
  assert.equal(duplicate.statusCode, 202);
  assert.equal(duplicate.body.feedbackID, first.body.feedbackID);
  assert.equal(deliveries.length, 1);

  timestamp += 2;
  const expired = responseRecorder();
  await handler(request(body, { ip: '127.0.0.2' }), expired);
  assert.equal(expired.statusCode, 202);
  assert.notEqual(expired.body.feedbackID, first.body.feedbackID);
  assert.equal(deliveries.length, 2);
});

test('coalesces concurrent retries for the same reportID into one delivery', async () => {
  const deliveries = [];
  let releaseDelivery;
  const pendingDelivery = new Promise((resolve) => { releaseDelivery = resolve; });
  const handler = createWiFiUsageFeedbackHandler({
    ...handlerOptions(deliveries),
    transporter: {
      sendMail: async (mail) => {
        deliveries.push(mail);
        await pendingDelivery;
      },
    },
  });
  const body = nativeFeedback({
    reportID: '21234567-89ab-4cde-8f01-23456789abcd',
    message: '并发重试',
  });
  const first = responseRecorder();
  const duplicate = responseRecorder();

  const firstRequest = handler(request(body), first);
  await Promise.resolve();
  const duplicateRequest = handler(request(body, { ip: '127.0.0.2' }), duplicate);
  releaseDelivery();
  await Promise.all([firstRequest, duplicateRequest]);

  assert.equal(deliveries.length, 1);
  assert.equal(first.statusCode, 202);
  assert.equal(duplicate.statusCode, 202);
  assert.equal(duplicate.body.feedbackID, first.body.feedbackID);
});

test('rejects diagnostics over 32 KiB by UTF-8 bytes', async () => {
  const handler = createWiFiUsageFeedbackHandler(handlerOptions());
  const response = responseRecorder();
  const oversized = '界'.repeat(Math.floor(MAX_DIAGNOSTICS_BYTES / 3) + 1);

  await handler(request(nativeFeedback({
    message: '日志太大',
    includeDiagnostics: true,
    diagnostics: { content: oversized },
  })), response);

  assert.equal(response.statusCode, 413);
  assert.equal(response.body.code, 'diagnostics_too_large');
});

test('rejects an estimated request over 48 KiB before validation', async () => {
  const handler = createWiFiUsageFeedbackHandler(handlerOptions());
  const response = responseRecorder();

  await handler(request({ message: '卡', ignoredPadding: 'x'.repeat(MAX_REQUEST_BYTES) }), response);

  assert.equal(response.statusCode, 413);
  assert.equal(response.body.code, 'payload_too_large');
});

test('requires application/json and uses a machine-readable error code', async () => {
  const handler = createWiFiUsageFeedbackHandler(handlerOptions());
  const response = responseRecorder();

  await handler(request({ message: '卡' }, { headers: { 'content-type': 'text/plain' } }), response);

  assert.equal(response.statusCode, 415);
  assert.equal(response.body.code, 'invalid_content_type');
});

test('rejects a foreign browser Origin but permits the absent native Origin', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));
  const foreignResponse = responseRecorder();
  const nativeResponse = responseRecorder();

  await handler(request({ message: '卡' }, {
    ip: '127.0.0.2',
    headers: { 'content-type': 'application/json', origin: 'https://evil.example' },
  }), foreignResponse);
  await handler(request(nativeFeedback({ message: '卡' }), { ip: '127.0.0.3' }), nativeResponse);

  assert.equal(foreignResponse.statusCode, 403);
  assert.equal(foreignResponse.body.code, 'invalid_origin');
  assert.equal(nativeResponse.statusCode, 202);
  assert.equal(deliveries.length, 1);
});

test('silently accepts honeypot submissions without sending mail', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));
  const response = responseRecorder();

  await handler(request({ message: '机器人反馈', company: 'https://spam.test' }), response);

  assert.equal(response.statusCode, 202);
  assert.equal(deliveries.length, 0);
});

test('rate limits the sixth accepted attempt for one Express client IP', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler(handlerOptions(deliveries));

  for (let index = 0; index < 6; index += 1) {
    const response = responseRecorder();
    await handler(request({ message: `问题 ${index}` }, {
      ip: '203.0.113.8',
      headers: {
        'content-type': 'application/json',
        'x-forwarded-for': `${index}.example.invalid`,
      },
    }), response);
    if (index < 5) assert.equal(response.statusCode, 202);
    else {
      assert.equal(response.statusCode, 429);
      assert.equal(response.body.code, 'rate_limited');
    }
  }

  assert.equal(deliveries.length, 5);
});

test('returns coded service and delivery failures without exposing internals', async () => {
  const unavailable = createWiFiUsageFeedbackHandler({});
  const unavailableResponse = responseRecorder();
  await unavailable(request({ message: '卡' }), unavailableResponse);
  assert.equal(unavailableResponse.statusCode, 503);
  assert.equal(unavailableResponse.body.code, 'service_unavailable');

  const errorLogs = [];
  const privateError = new Error('SMTP password was rejected');
  privateError.code = 'EAUTH';
  const failed = createWiFiUsageFeedbackHandler({
    ...handlerOptions(),
    logger: { info() {}, error(...items) { errorLogs.push(items.join(' ')); } },
    transporter: { sendMail: async () => { throw privateError; } },
  });
  const failedResponse = responseRecorder();
  await failed(request({ message: '卡' }), failedResponse);
  assert.equal(failedResponse.statusCode, 502);
  assert.equal(failedResponse.body.code, 'delivery_failed');
  assert.doesNotMatch(JSON.stringify(failedResponse.body), /SMTP|password/i);
  assert.deepEqual(errorLogs, ['[WiFiUsage feedback] delivery failed code=EAUTH']);
  assert.doesNotMatch(errorLogs.join('\n'), /SMTP|password|rejected/i);
});

test('keeps a timed-out receipt bound to its original delivery and never sends a duplicate', async () => {
  let calls = 0;
  let releaseDelivery;
  const pendingDelivery = new Promise((resolve) => { releaseDelivery = resolve; });
  const handler = createWiFiUsageFeedbackHandler({
    ...handlerOptions(),
    deliveryTimeoutMs: 5,
    transporter: {
      sendMail: () => {
        calls += 1;
        return pendingDelivery;
      },
    },
  });
  const body = nativeFeedback({
    reportID: '31234567-89ab-4cde-8f01-23456789abcd',
    message: '投递超时后重试',
  });

  const first = responseRecorder();
  await handler(request(body), first);
  const retry = responseRecorder();
  await handler(request(body), retry);

  assert.equal(first.statusCode, 502);
  assert.equal(retry.statusCode, 502);
  assert.equal(calls, 1);

  releaseDelivery();
  await pendingDelivery;
  const afterLateSuccess = responseRecorder();
  await handler(request(body, { ip: '127.0.0.3' }), afterLateSuccess);

  assert.equal(afterLateSuccess.statusCode, 202);
  assert.match(afterLateSuccess.body.feedbackID, UUID_PATTERN);
  assert.equal(calls, 1);
});

test('allows a new delivery only after the original timed-out delivery definitively fails', async () => {
  let calls = 0;
  let rejectOriginal;
  const originalDelivery = new Promise((_, reject) => { rejectOriginal = reject; });
  const handler = createWiFiUsageFeedbackHandler({
    ...handlerOptions(),
    deliveryTimeoutMs: 5,
    transporter: {
      sendMail: () => {
        calls += 1;
        return calls === 1 ? originalDelivery : Promise.resolve();
      },
    },
  });
  const body = nativeFeedback({
    reportID: '81234567-89ab-4cde-8f01-23456789abcd',
    message: '原投递明确失败后重试',
  });

  const timedOut = responseRecorder();
  await handler(request(body), timedOut);
  assert.equal(timedOut.statusCode, 502);
  assert.equal(calls, 1);

  const failure = new Error('definitive transport failure');
  failure.code = 'ECONNECTION';
  rejectOriginal(failure);
  await assert.rejects(originalDelivery, /definitive/);
  await Promise.resolve();

  const retry = responseRecorder();
  await handler(request(body, { ip: '127.0.0.3' }), retry);

  assert.equal(retry.statusCode, 202);
  assert.equal(calls, 2);
});

test('caps in-flight report receipts while preserving the active delivery', async () => {
  let releaseDelivery;
  const pendingDelivery = new Promise((resolve) => { releaseDelivery = resolve; });
  const handler = createWiFiUsageFeedbackHandler({
    ...handlerOptions(),
    deliveryTimeoutMs: 1_000,
    maximumReportReceipts: 1,
    transporter: { sendMail: () => pendingDelivery },
  });
  const firstResponse = responseRecorder();
  const firstRequest = handler(request(nativeFeedback({
    reportID: '41234567-89ab-4cde-8f01-23456789abcd',
    message: '第一条投递',
  })), firstResponse);
  await Promise.resolve();

  const busyResponse = responseRecorder();
  await handler(request(nativeFeedback({
    reportID: '51234567-89ab-4cde-8f01-23456789abcd',
    message: '第二条投递',
  }), { ip: '127.0.0.2' }), busyResponse);

  assert.equal(busyResponse.statusCode, 503);
  assert.equal(busyResponse.body.code, 'service_busy');
  releaseDelivery();
  await firstRequest;
  assert.equal(firstResponse.statusCode, 202);
});

test('does not count completed 24-hour receipts against the in-flight limit', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler({
    ...handlerOptions(deliveries),
    maximumReportReceipts: 1,
  });

  const first = responseRecorder();
  await handler(request(nativeFeedback({
    reportID: '61234567-89ab-4cde-8f01-23456789abcd',
    message: '第一条已完成投递',
  })), first);
  const second = responseRecorder();
  await handler(request(nativeFeedback({
    reportID: '71234567-89ab-4cde-8f01-23456789abcd',
    message: '第二条新投递',
  }), { ip: '127.0.0.2' }), second);

  assert.equal(first.statusCode, 202);
  assert.equal(second.statusCode, 202);
  assert.equal(deliveries.length, 2);

  const firstDuplicate = responseRecorder();
  await handler(request(nativeFeedback({
    reportID: '61234567-89ab-4cde-8f01-23456789abcd',
    message: '第一条的幂等重试',
  }), { ip: '127.0.0.3' }), firstDuplicate);

  assert.equal(firstDuplicate.statusCode, 202);
  assert.equal(firstDuplicate.body.feedbackID, first.body.feedbackID);
  assert.equal(deliveries.length, 2);
});

test('mountable error middleware converts parser failures to safe JSON', () => {
  const middleware = createWiFiUsageFeedbackErrorHandler({ logger: { error() {} } });
  const oversizedResponse = responseRecorder();
  const invalidJSONResponse = responseRecorder();

  middleware({
    status: 413,
    type: 'entity.too.large',
    stack: 'secret stack /www/wwwroot/xjp.one',
  }, request(undefined, { originalUrl: '/api/wifiusage/feedback/?source=app' }), oversizedResponse, () => assert.fail('must not call next'));
  assert.equal(oversizedResponse.statusCode, 413);
  assert.equal(oversizedResponse.body.code, 'payload_too_large');
  assert.doesNotMatch(JSON.stringify(oversizedResponse.body), /stack|wwwroot/i);

  middleware({ status: 400, type: 'entity.parse.failed' }, request(undefined), invalidJSONResponse, () => assert.fail('must not call next'));
  assert.equal(invalidJSONResponse.statusCode, 400);
  assert.equal(invalidJSONResponse.body.code, 'invalid_json');
});

test('error middleware passes unrelated routes to the host application', () => {
  const middleware = createWiFiUsageFeedbackErrorHandler({ logger: { error() {} } });
  const error = new Error('other route failure');
  let passed = null;

  middleware(error, request(undefined, { originalUrl: '/api/other' }), responseRecorder(), (value) => { passed = value; });

  assert.equal(passed, error);
});

test('error middleware never logs a raw request exception', () => {
  const errorLogs = [];
  const middleware = createWiFiUsageFeedbackErrorHandler({
    logger: { error(...items) { errorLogs.push(items.join(' ')); } },
  });
  const response = responseRecorder();

  middleware(new Error('private token abc123'), request(undefined), response, () => assert.fail('must not call next'));

  assert.equal(response.statusCode, 500);
  assert.equal(response.body.code, 'internal_error');
  assert.deepEqual(errorLogs, ['[WiFiUsage feedback] request failed code=internal_error']);
  assert.doesNotMatch(errorLogs.join('\n'), /private|token|abc123/i);
});

test('registers both the route and its parser error middleware', () => {
  const registrations = [];
  const app = {
    post(path, handler) { registrations.push(['post', path, handler]); },
    use(handler) { registrations.push(['use', handler]); },
  };

  registerWiFiUsageFeedback(app, handlerOptions());

  assert.equal(registrations.length, 2);
  assert.equal(registrations[0][0], 'post');
  assert.equal(registrations[0][1], '/api/wifiusage/feedback');
  assert.equal(typeof registrations[0][2], 'function');
  assert.equal(registrations[1][0], 'use');
  assert.equal(typeof registrations[1][1], 'function');
});
