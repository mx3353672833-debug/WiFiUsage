'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  createWiFiUsageFeedbackHandler,
  formatFeedbackText,
  validateFeedback,
} = require('./wifiusage-feedback');

function responseRecorder() {
  return {
    statusCode: 200,
    headers: {},
    body: null,
    set(name, value) { this.headers[name] = value; return this; },
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
}

test('requires a non-empty message and keeps unknown types out of the subject', () => {
  assert.equal(validateFeedback({ message: '   ' }).error, '请填写问题描述。');
  assert.equal(validateFeedback({ message: '卡' }).error, undefined);
  assert.match(validateFeedback({ message: '卡', wantsReply: true }).error, /联系方式/);
  const result = validateFeedback({ type: 'Bad\r\nBcc: x', message: '卡' });
  assert.equal(result.value.type, '其他问题');
});

test('formats contact only when a reply is requested', () => {
  const text = formatFeedbackText({
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

test('sends one plain-text email to the server-configured recipient', async () => {
  const deliveries = [];
  const handler = createWiFiUsageFeedbackHandler({
    transporter: { sendMail: async (mail) => deliveries.push(mail) },
    fromAddress: 'sender@example.test',
    toAddress: 'private-recipient@example.test',
    logger: { info() {}, error() {} },
  });
  const request = {
    body: { type: '网页或下载问题', message: '下载按钮点击以后没有开始下载' },
    headers: {},
    socket: { remoteAddress: '127.0.0.1' },
    get: () => 'https://xjp.one',
  };
  const response = responseRecorder();

  await handler(request, response);

  assert.equal(response.statusCode, 202);
  assert.equal(deliveries.length, 1);
  assert.equal(deliveries[0].to, 'private-recipient@example.test');
  assert.match(deliveries[0].subject, /网页或下载问题/);
});

test('silently accepts honeypot submissions without sending mail', async () => {
  let sent = false;
  const handler = createWiFiUsageFeedbackHandler({
    transporter: { sendMail: async () => { sent = true; } },
    fromAddress: 'sender@example.test',
    toAddress: 'private-recipient@example.test',
  });
  const request = {
    body: { message: '这是一条机器人自动填写的反馈', company: 'https://spam.test' },
    headers: {},
    socket: { remoteAddress: '127.0.0.1' },
    get: () => 'https://xjp.one',
  };
  const response = responseRecorder();

  await handler(request, response);

  assert.equal(response.statusCode, 202);
  assert.equal(sent, false);
});
