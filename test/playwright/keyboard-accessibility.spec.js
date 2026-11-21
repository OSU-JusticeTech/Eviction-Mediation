const { test, expect } = require('@playwright/test');
const { fictionalEmail, signup, initiate, intake, token } = require('./helpers');

async function activeControl(page) {
  return page.evaluate(() => {
    let element = document.activeElement;
    while (element?.contentDocument?.activeElement) element = element.contentDocument.activeElement;
    return element && {
      tag: element.tagName,
      id: element.id,
      label: element.getAttribute('aria-label') || element.textContent.trim().replace(/\s+/g, ' ').slice(0, 80),
    };
  });
}

// Reach controls through the browser's actual tab order, including inside iframes.
async function tabTo(page, target, direction = 'Tab') {
  await expect(target).toBeVisible();
  const visited = [];
  for (let step = 0; step < 120; step++) {
    if (await target.evaluate(element => element.ownerDocument.activeElement === element)) return;
    await page.keyboard.press(direction);
    if (step < 12 || step % 10 === 0) visited.push(await activeControl(page));
  }
  throw new Error(`Could not reach ${target} using ${direction}. Sampled focus stops: ${JSON.stringify(visited)}`);
}

async function activate(page, target, key = 'Enter') {
  await tabTo(page, target);
  await page.keyboard.press(key);
}

async function type(page, target, value) {
  await tabTo(page, target);
  await page.keyboard.press('ControlOrMeta+a');
  await page.keyboard.insertText(value);
}

async function submitLogin(page, email, password = 'Fictional-QA-Password123!') {
  await page.goto('/login');
  await type(page, page.locator('#email'), email);
  await type(page, page.locator('#login-password'), password);
  await activate(page, page.getByRole('button', { name: 'Log In', exact: true }));
}

async function keyboardLogin(page, ...credentials) {
  await submitLogin(page, ...credentials);
  await expect(page).toHaveURL('/dashboard');
}

async function checkExposed(locator) {
  const exposed = await locator.evaluate(element => {
    const rect = element.getBoundingClientRect();
    for (const x of [0.15, 0.5, 0.85]) {
      for (const y of [0.15, 0.5, 0.85]) {
        const hit = element.ownerDocument.elementFromPoint(rect.left + rect.width * x, rect.top + rect.height * y);
        if (hit?.closest('html') && (element.contains(hit) || hit.contains(element))) return true;
      }
    }
    return false;
  });
  expect(exposed, `Focused control should be exposed in the viewport: ${locator}`).toBe(true);
}

async function chatFixture(page, browser, operation) {
  const landlord = await browser.newPage();
  try {
    const email = await signup(landlord, 'landlord');
    await signup(page, 'tenant');
    await initiate(page, 'tenant', email);
    await intake(page, 'tenant');
    await landlord.goto('/messages');
    await landlord.getByRole('button', { name: 'Accept', exact: true }).click();
    await landlord.getByRole('link', { name: 'Complete Intake Questions' }).click();
    await intake(landlord, 'landlord');
    const chat = await landlord.getByRole('link', { name: 'Open Messages' }).getAttribute('href');
    await operation(landlord, chat);
  } finally {
    await landlord.close();
  }
}

async function keyboardChat(page, path) {
  await page.goto(path);
  const confirm = page.getByRole('button', { name: 'I Understand' });
  if (await confirm.isVisible()) await activate(page, confirm, 'Space');
  await expect(page.locator('#message_contents')).toBeVisible();
}

for (const width of [1280, 390]) {
  test(`landing and login tab order at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 800 });
    await page.goto('/');
    const login = page.getByRole('link', { name: /log in$/i }).first();
    await activate(page, login);
    await expect(page).toHaveURL('/login');
    const email = page.locator('#email');
    const password = page.locator('#login-password');
    await tabTo(page, email);
    await checkExposed(email);
    await info.attach('email-keyboard-focus', { body: await page.screenshot(), contentType: 'image/png' });
    await tabTo(page, password);
    await page.keyboard.press('Shift+Tab');
    await expect(email).toBeFocused();
  });
}

async function fillSignupWithKeyboard(page, role, name) {
  await page.goto('/signup');
  for (const [id, text] of Object.entries({
    user_FName: name, user_LName: 'Fictional QA', user_Email: fictionalEmail(role),
    user_password: 'Fictional-QA-Password123!', user_password_confirmation: 'Fictional-QA-Password123!',
  })) await type(page, page.locator(`#${id}`), text);

  await tabTo(page, page.getByRole('radio', { name: 'Tenant', exact: true }));
  await page.keyboard.press(role === 'Tenant' ? 'Space' : 'ArrowRight');
  await expect(page.getByRole('radio', { name: role, exact: true })).toBeChecked();
  if (role === 'Tenant') {
    await type(page, page.locator('#address-line-1'), '123 Fictional QA Lane');
    await type(page, page.locator('#city'), 'Columbus');
    const state = page.getByLabel('State', { exact: true });
    await tabTo(page, state);
    await page.keyboard.press('o');
    await expect(state).toHaveValue('Ohio');
    await type(page, page.locator('#zip-code'), '43215');
  } else {
    await type(page, page.locator('#user_CompanyName'), 'Fictional QA Properties');
  }
  await type(page, page.locator('#phone-number'), '6145550100');
}

for (const width of [1280, 390]) {
  for (const [role, name] of [['Tenant', 'Alice'], ['Landlord', 'Bob']]) {
    test(`${role} keyboard registration requires the disclaimer and consent at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 800 });
      await fillSignupWithKeyboard(page, role, name);
      const trigger = page.locator('main').getByRole('button', { name: 'Legal Disclaimer', exact: true });
      const consent = page.getByRole('checkbox', { name: 'I have read and agree to the Legal Disclaimer', exact: true });
      const signupButton = page.getByRole('button', { name: 'Sign Up', exact: true });
      const dialog = page.getByRole('dialog', { name: 'Legal Disclaimer', exact: true });
      const signupPosts = [];
      page.on('request', request => {
        if (request.method() === 'POST' && new URL(request.url()).pathname === '/signup') signupPosts.push(request);
      });

      await tabTo(page, trigger);
      await page.keyboard.press('Tab');
      await expect(consent).toBeFocused();
      await checkExposed(consent);
      const outline = await consent.evaluate(element => getComputedStyle(element).outlineStyle);
      expect(outline).toBe('solid');
      await page.keyboard.press('Space');
      await expect(consent).toBeChecked();
      await activate(page, signupButton);
      await expect(page.getByRole('alert')).toContainText('You must open and read the Legal Disclaimer');
      await expect(trigger).toBeFocused();
      expect(signupPosts).toHaveLength(0);

      await activate(page, consent, 'Space');
      await expect(consent).not.toBeChecked();
      const close = dialog.getByRole('button', { name: 'Close legal disclaimer' });
      for (const dismiss of ['Escape', 'Space']) {
        await activate(page, trigger, 'Space');
        await expect(close).toBeFocused();
        await page.keyboard.press(dismiss);
        await expect(dialog).toBeHidden();
        await expect(trigger).toBeFocused();
        await expect(consent).not.toBeChecked();
      }
      await activate(page, signupButton);
      await expect(consent).toBeFocused();
      expect(await consent.evaluate(element => element.validity.valueMissing)).toBe(true);
      await expect(page).toHaveURL('/signup');
      expect(signupPosts).toHaveLength(0);

      await activate(page, trigger);
      await activate(page, dialog.getByRole('button', { name: 'I Agree' }), 'Space');
      await expect(dialog).toBeHidden();
      await expect(trigger).toBeFocused();
      await expect(consent).toBeChecked();
      await activate(page, signupButton);
      await expect(page).toHaveURL(/\/terms-of-use/);
      await tabTo(page, page.locator('.terms-page__text'));
      await page.keyboard.press('End');
      const agreeToTerms = page.locator('.terms-page__agree');
      await expect(agreeToTerms).toBeEnabled();
      await activate(page, agreeToTerms, 'Space');
      await expect(page).toHaveURL('/dashboard');
      await expect(page.getByRole('heading', { level: 1 })).toContainText(name);
      expect(signupPosts).toHaveLength(1);
    });
  }
}

for (const role of ['tenant', 'landlord', 'mediator', 'administrator']) {
  test(`${role} keyboard login and dashboard navigation`, async ({ page }) => {
    const { QA_ADMIN_EMAIL, QA_ASSIGNMENT_PASSWORD, QA_MEDIATOR_EMAIL, QA_MEDIATOR_PASSWORD } = process.env;
    const credentials = {
      administrator: [QA_ADMIN_EMAIL, QA_ASSIGNMENT_PASSWORD],
      mediator: [QA_MEDIATOR_EMAIL, QA_MEDIATOR_PASSWORD],
    };
    if (credentials[role]) test.skip(!credentials[role].every(Boolean), 'Requires the existing fictional role fixture');
    let account = credentials[role];
    if (!account) {
      const email = await signup(page, role, fictionalEmail(role));
      await page.context().clearCookies();
      account = [email];
    }
    await keyboardLogin(page, ...account);
    const destination = {
      tenant: 'a[href="/messages"]',
      landlord: 'a[href="/messages"]',
      mediator: 'a[href="/mediator/schedule"]',
      administrator: 'a[href*="/admin/"]',
    };
    const link = page.locator(destination[role]).filter({ visible: true }).first();
    await tabTo(page, link);
    await checkExposed(link);
    await page.keyboard.press('Enter');
    if (role === 'mediator') {
      await expect(page).toHaveURL('/mediator/schedule');
      await tabTo(page, page.locator('#avail-day'));
      await page.keyboard.press('Home');
      await page.keyboard.press('ArrowDown');
      await tabTo(page, page.locator('#btn-add-avail'));
      await checkExposed(page.locator('#btn-add-avail'));
      await tabTo(page, page.locator('#avail-end'), 'Shift+Tab');
      await tabTo(page, page.locator('#btn-add-block'));
    } else {
      await expect(page).not.toHaveURL('/dashboard');
    }
  });
}

test('notification bell opens with Space and Escape restores focus', async ({ page }) => {
  await signup(page, 'tenant');
  const bell = page.locator('.notification-bell');
  await activate(page, bell, 'Space');
  const menu = page.locator('.notification-menu');
  const viewAll = page.locator('.notification-view-all');
  await expect(menu).toHaveAttribute('open', '');
  await tabTo(page, viewAll);
  await page.keyboard.press('Escape');
  const remainedOpen = await menu.getAttribute('open') !== null;
  expect.soft(remainedOpen, 'Escape should dismiss the notification popover').toBe(false);
  expect.soft(await bell.evaluate(element => element.matches(':focus')), 'Focus returns to the bell').toBe(true);
  if (!remainedOpen) await activate(page, bell, 'Space');
  await activate(page, viewAll);
  await expect(page).toHaveURL(/\/notifications/);
});

for (const width of [1280, 390]) {
  test(`Conversation Details modal and chat at ${width}px`, async ({ page, browser }, info) => {
    await chatFixture(page, browser, async (_, chat) => {
      await page.setViewportSize({ width, height: 800 });
      await keyboardChat(page, chat);
      const trigger = page.getByRole('button', { name: 'Conversation details', exact: true });
      await tabTo(page, trigger);
      expect.soft(await trigger.evaluate(element => element.matches(':focus-visible'))).toBe(true);
      await checkExposed(trigger);
      await info.attach('details-trigger-focus', { body: await page.screenshot(), contentType: 'image/png' });
      await page.keyboard.press('Enter');
      const dialog = page.getByRole('dialog', { name: 'Conversation details' });
      await expect(dialog).toBeVisible();
      const close = dialog.getByRole('button', { name: 'Close conversation details' });
      const terms = dialog.getByRole('link', { name: 'Terms of Use' });
      await expect(close).toBeFocused();
      await checkExposed(close);
      await expect.poll(() => dialog.evaluate(element => element.matches(':modal'))).toBe(true);

      // Walk past both ends of the modal. Chromium may briefly pass focus
      // to browser chrome, but must never focus a control behind the modal.
      for (const [key, boundary, next] of [['Shift+Tab', close, terms], ['Tab', terms, close]]) {
        await tabTo(page, boundary);
        await page.keyboard.press(key);
        if ((await activeControl(page)).tag === 'BODY') await page.keyboard.press(key);
        await expect(next).toBeFocused();
      }
      await page.keyboard.press('Escape');
      await expect(dialog).toBeHidden();
      await expect(trigger).toBeFocused();

      await activate(page, trigger, 'Space');
      await expect(close).toBeFocused();
      await page.keyboard.press('Space');
      await expect(dialog).toBeHidden();
      await expect(trigger).toBeFocused();

      await activate(page, trigger);
      await dialog.click({ position: { x: 5, y: 5 } });
      await expect(dialog).toBeHidden();
      await expect(trigger).toBeFocused();
      const message = `Fictional keyboard audit ${token()}`;
      const composer = page.locator('#message_contents');
      await type(page, composer, message);
      await expect(composer).toHaveValue(message);
      const savedMessage = page.waitForResponse(response => response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/messages');
      await activate(page, page.getByRole('button', { name: 'Send', exact: true }), 'Space');
      expect((await savedMessage).status()).toBe(201);
      await page.reload();
      await expect(page.getByText(message, { exact: true })).toBeVisible();
    });
  });
}

async function editField(page, frame, field, value) {
  await activate(page, frame.locator(`[data-agreement-field="${field}"]`));
  const editor = frame.locator('.agreement-inline-input');
  await expect(editor).toBeFocused();
  const commit = await editor.evaluate(element => element.tagName === 'TEXTAREA' ? 'Tab' : 'Enter');
  // Chromium's segmented controls respond to digit keys, not text insertion.
  const inputType = await editor.getAttribute('type');
  const temporalKeys = { date: '12012099', time: '1200p' };
  if (temporalKeys[inputType]) {
    for (const key of temporalKeys[inputType]) {
      if (!(await editor.count())) break;
      await page.keyboard.press(key);
    }
  } else {
    await type(page, editor, value);
  }
  if (await editor.count()) await page.keyboard.press(commit);
  await expect(page.locator(`[data-agreement-term="${field}"]`)).toHaveValue(value);
}

test('keyboard generation, suggestion, review and two signatures', async ({ page, browser }) => {
  test.setTimeout(120000);
  await chatFixture(page, browser, async (landlord, chat) => {
    await keyboardChat(page, chat);
    const attach = page.getByRole('button', { name: 'Attach a document' });
    await activate(page, attach, 'Space');
    await activate(page, page.getByRole('link', { name: 'Generate a document' }));
    await activate(page, page.getByRole('link', { name: 'Select Template A' }));
    const frame = page.frameLocator('iframe.document-iframe');
    for (const [field, value] of Object.entries({
      reason: 'Fictional overdue rent', vacate_date: '2099-12-01', move_out_time: '12:00',
      possession_notice: 'Notify by fictional email', attachments: 'None',
    })) await editField(page, frame, field, value);
    for (const [field, value] of Object.entries({
      case_status: 'unfiled', case_conditions: 'none', deposit_choice: 'none',
      move_out_payment: 'none', additional_choice: 'none',
    })) {
      await activate(page, frame.locator(`[data-agreement-choice="${field}"][data-agreement-value="${value}"]`), 'Space');
      await expect(page.locator(`[data-agreement-term="${field}"]`)).toHaveValue(value);
    }
    await activate(page, page.getByRole('button', { name: 'Generate Document' }), 'Space');
    await expect(page.getByText('Document generated successfully.')).toBeVisible();
    await activate(page, attach);
    await tabTo(page, page.getByLabel('Attach an existing file'));
    await page.keyboard.press('Home');
    await page.keyboard.press('ArrowDown');
    await type(page, page.locator('#message_contents'), 'Fictional keyboard agreement review');
    await activate(page, page.getByRole('button', { name: 'Send', exact: true }));
    await keyboardChat(landlord, chat);
    const review = landlord.getByRole('link', { name: 'Review & Sign', exact: true });
    const documentPath = await review.getAttribute('href');
    await activate(landlord, review);
    await activate(landlord, landlord.getByRole('link', { name: 'Suggest Changes' }));
    const editUrl = new URL(documentPath, landlord.url());
    editUrl.searchParams.set('edit', '1');
    await expect(landlord).toHaveURL(editUrl.href);
    await expect(landlord.locator('[data-agreement-editor]')).toHaveAttribute('data-editor-ready', 'true');
    const editablePreview = landlord.frameLocator('iframe.document-iframe[src*="editable_preview=1"]');
    await editField(landlord, editablePreview, 'possession_notice', 'Notify by fictional written notice');
    await activate(landlord, landlord.getByRole('button', { name: 'Finish & Send Suggested Changes' }));
    await page.goto(documentPath);
    await expect(page.getByRole('heading', { name: 'Signing Paused' })).toBeVisible();
    await activate(page, page.locator('.suggestion-item').getByRole('button', { name: /^Accept / }));
    for (const signer of [page, landlord]) {
      if (signer === landlord) await signer.goto(documentPath);
      const preview = signer.locator('iframe[title="Agreement document preview"]');
      // Approval reloads the page, so wait for the accepted revision in the preview.
      await expect(preview.contentFrame().getByText(/fictional written notice/)).toBeVisible();
      const sign = signer.getByRole('button', { name: 'Sign Document', exact: true });
      const role = signer === page ? 'tenant' : 'landlord';
      let keyboardFailure;
      try {
        await tabTo(signer, preview);
        await signer.keyboard.press('End');
        await expect(sign).toBeEnabled({ timeout: 3000 });
      } catch (error) {
        keyboardFailure = error.message;
      }
      expect.soft(keyboardFailure, `${role} can reach the preview and unlock signing with the keyboard`).toBeUndefined();
      if (keyboardFailure) {
        // Prepare only the scroll state so the sign control can be tested independently.
        await signer.frameLocator('iframe[title="Agreement document preview"]').locator('body').evaluate(body => {
          const scroller = body.ownerDocument.scrollingElement;
          body.ownerDocument.defaultView.scrollTo(0, scroller.scrollHeight);
        });
        await expect(sign).toBeEnabled();
      }
      await activate(signer, sign, 'Space');
      await expect(signer.locator(`[data-signature-role="${signer === page ? 'tenant' : 'landlord'}"] .signed`)).toBeVisible();
    }
    await expect(landlord.getByText('Document Fully Executed')).toBeVisible();
  });
});

test('authenticated terms of use acceptance using keyboard scrolling', async ({ page, browser }) => {
  const email = await signup(page, 'tenant');
  const freshSession = await browser.newPage({ viewport: { width: 390, height: 620 } });
  try {
    await submitLogin(freshSession, email);
    await expect(freshSession).toHaveURL(/\/terms-of-use/);
    const panel = freshSession.locator('.terms-page__text');
    const agree = freshSession.locator('.terms-page__agree');
    await expect(agree).toBeDisabled();
    await tabTo(freshSession, panel);
    await freshSession.keyboard.press('End');
    await expect(agree).toBeEnabled();
    await activate(freshSession, agree, 'Space');
    await expect(freshSession).toHaveURL('/dashboard');
  } finally {
    await freshSession.close();
  }
});

test('mediator meeting dialog keyboard navigation and Escape', async ({ page }) => {
  const { QA_ASSIGNMENT_MEDIATOR_EMAIL, QA_ASSIGNMENT_PASSWORD } = process.env;
  test.skip(!QA_ASSIGNMENT_MEDIATOR_EMAIL || !QA_ASSIGNMENT_PASSWORD, 'Requires an assigned fictional mediator');
  await keyboardLogin(page, QA_ASSIGNMENT_MEDIATOR_EMAIL, QA_ASSIGNMENT_PASSWORD);
  const previous = page.getByRole('button', { name: 'Previous month', exact: true });
  const next = page.getByRole('button', { name: 'Next month', exact: true });
  await activate(page, previous, 'Space');
  await activate(page, next);
  await page.goto('/third_party_mediations');
  const qaCase = page.locator('article').filter({ hasText: /Fictional QA/i }).first();
  await activate(page, qaCase.getByRole('link', { name: 'View Mediation' }));
  await activate(page, page.getByRole('link', { name: 'Open Chat' }));
  const trigger = page.getByRole('button', { name: 'Schedule Meeting', exact: true });
  await activate(page, trigger, 'Space');
  const dialog = page.getByRole('dialog', { name: 'Schedule Zoom Session' });
  await expect(dialog).toBeVisible();
  expect(await dialog.evaluate(element => element.contains(document.activeElement))).toBe(true);
  await tabTo(page, dialog.getByLabel('Meeting Date'));
  await tabTo(page, dialog.getByLabel('Start Time'));
  const duration = dialog.getByLabel('Duration');
  await tabTo(page, duration);
  await page.keyboard.press('ArrowDown');
  await expect(duration).toHaveValue('45');
  await activate(page, dialog.getByRole('button', { name: 'Create Meeting' }), 'Space');
  await expect(dialog.getByRole('status')).toHaveText('Please select both a date and start time.');
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
  await expect(trigger).toBeFocused();
});

for (const viewport of [{ width: 320, height: 180 }, { width: 390, height: 800 }]) {
  test(`dashboard menu follows the toggle in tab order at ${viewport.width}px`, async ({ page }) => {
    await signup(page, 'tenant');
    await page.setViewportSize(viewport);
    const toggle = page.getByRole('button', { name: 'Toggle navigation menu' });
    const nav = page.locator('#navbar-menu');
    await expect(nav).toBeHidden();
    await activate(page, toggle, 'Enter');
    await expect(toggle).toHaveAttribute('aria-expanded', 'true');
    await page.keyboard.press('Tab');
    const home = nav.getByRole('link', { name: 'Home' });
    await expect(home).toBeFocused();
    await checkExposed(home);
    await page.keyboard.press('Tab');
    const messages = nav.getByRole('link', { name: /Messages/ });
    await expect(messages).toBeFocused();
    await checkExposed(messages);
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL('/messages');
  });
}
