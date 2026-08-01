(() => {
  'use strict';

  const root = document.documentElement;
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const revealItems = Array.from(document.querySelectorAll('.reveal'));

  if (!reducedMotion.matches && 'IntersectionObserver' in window) {
    revealItems.forEach((item, index) => {
      item.style.setProperty('--reveal-delay', `${Math.min(index % 3, 2) * 55}ms`);
    });

    root.classList.add('reveal-enabled');
    const revealObserver = new IntersectionObserver((entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    revealItems.forEach((item) => revealObserver.observe(item));
  } else {
    revealItems.forEach((item) => item.classList.add('is-visible'));
  }

  let scrollFrame = 0;
  const updateScrollSignal = () => {
    scrollFrame = 0;
    if (reducedMotion.matches) {
      root.style.setProperty('--scroll-progress', '1');
      return;
    }
    const maxScroll = Math.max(document.documentElement.scrollHeight - window.innerHeight, 1);
    const progress = Math.min(Math.max(window.scrollY / maxScroll, 0), 1);
    root.style.setProperty('--scroll-progress', progress.toFixed(4));
  };

  const requestScrollSignal = () => {
    if (scrollFrame) return;
    scrollFrame = window.requestAnimationFrame(updateScrollSignal);
  };

  window.addEventListener('scroll', requestScrollSignal, { passive: true });
  window.addEventListener('resize', requestScrollSignal, { passive: true });
  reducedMotion.addEventListener?.('change', updateScrollSignal);
  updateScrollSignal();

  const form = document.querySelector('#feedback-form');
  if (!form) return;

  const type = form.querySelector('#feedback-type');
  const message = form.querySelector('#feedback-message');
  const system = form.querySelector('#feedback-system');
  const device = form.querySelector('#feedback-device');
  const wantsReply = form.querySelector('#feedback-reply');
  const contactWrap = form.querySelector('#feedback-contact-wrap');
  const contact = form.querySelector('#feedback-contact');
  const honeypot = form.querySelector('#feedback-company');
  const count = form.querySelector('#feedback-count');
  const submit = form.querySelector('#feedback-submit');
  const status = form.querySelector('#feedback-status');

  const setStatus = (text, kind = '') => {
    status.textContent = text;
    status.className = `form-status${kind ? ` is-${kind}` : ''}`;
  };

  const updateContact = () => {
    const enabled = wantsReply.checked;
    contactWrap.hidden = !enabled;
    contact.required = enabled;
    wantsReply.setAttribute('aria-expanded', String(enabled));
    if (!enabled) {
      contact.value = '';
      contact.removeAttribute('aria-invalid');
    }
  };

  const markValidity = (field) => {
    if (field.checkValidity()) {
      field.removeAttribute('aria-invalid');
    } else {
      field.setAttribute('aria-invalid', 'true');
    }
  };

  wantsReply.addEventListener('change', updateContact);
  message.addEventListener('input', () => {
    message.setCustomValidity(message.value.trim() ? '' : '请填写问题描述。');
    count.textContent = String(message.value.length);
    markValidity(message);
  });
  contact.addEventListener('input', () => markValidity(contact));

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    setStatus('');
    message.setCustomValidity(message.value.trim() ? '' : '请填写问题描述。');
    markValidity(message);
    markValidity(contact);

    if (!form.checkValidity()) {
      form.reportValidity();
      setStatus('请先补全标记为必填的内容。', 'error');
      return;
    }

    submit.disabled = true;
    submit.textContent = '正在发送…';

    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);

    try {
      const response = await fetch('/api/wifiusage/feedback', {
        method: 'POST',
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        credentials: 'omit',
        signal: controller.signal,
        body: JSON.stringify({
          type: type.value,
          message: message.value.trim(),
          system: system.value.trim(),
          device: device.value.trim(),
          wantsReply: wantsReply.checked,
          contact: wantsReply.checked ? contact.value.trim() : '',
          company: honeypot.value
        })
      });

      let result = {};
      try {
        result = await response.json();
      } catch (_) {
        result = {};
      }

      if (!response.ok) {
        const fallback = response.status === 429
          ? '发送得有点频繁，请稍后再试。'
          : '反馈暂时没有发送成功，请稍后再试，或前往 GitHub 提 Issue。';
        throw new Error(result.message || fallback);
      }

      form.reset();
      updateContact();
      count.textContent = '0';
      setStatus('反馈已发送。谢谢你把问题告诉我。', 'success');
    } catch (error) {
      const messageText = error.name === 'AbortError'
        ? '发送超时了，请检查网络后重试，或前往 GitHub 提 Issue。'
        : error.message;
      setStatus(messageText, 'error');
    } finally {
      window.clearTimeout(timeout);
      submit.disabled = false;
      submit.textContent = '发送反馈';
    }
  });

  updateContact();
})();
