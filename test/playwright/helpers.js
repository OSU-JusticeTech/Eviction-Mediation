const { expect } = require('@playwright/test');
const { randomUUID } = require('node:crypto');

const password = 'Fictional-QA-Password123!';
const token = () => randomUUID().slice(0, 12);
const fictionalEmail = (label) => `eviction-qa-${label}-${token()}@example.com`;

async function acceptTerms(page) {
  await page.waitForURL(/\/(dashboard|terms-of-use)(?:[/?]|$)/);
  if (!new URL(page.url()).pathname.startsWith('/terms-of-use')) {
    await page.waitForURL(/\/terms-of-use(?:[?]|$)/);
  }
  const agree = page.locator('.terms-page__agree');
  await expect(agree).toBeDisabled();
  await page.locator('.terms-page__text').evaluate((panel) => {
    panel.scrollTop = panel.scrollHeight;
  });
  await agree.click();
  await expect(page).toHaveURL(/\/dashboard(?:[/?]|$)/);
}

async function signup(page, role, email = fictionalEmail(role)) {
  const firstName = role === 'tenant' ? 'Alice' : 'Bob';
  await page.goto('/signup');
  await page.locator('#user_FName').fill(firstName);
  await page.locator('#user_LName').fill('Fictional QA');
  await page.locator('#user_Email').fill(email);
  await page.locator('#user_password').fill(password);
  await page.locator('#user_password_confirmation').fill(password);
  await page.getByRole("radio", { name: role === 'tenant' ? 'Tenant' : 'Landlord', exact: true }).check();
  if (role === 'tenant') {
    await page.locator('#address-line-1').fill('123 Fictional QA Lane');
    await page.locator('#city').fill('Columbus');
    await page.locator('#state').selectOption({ label: 'Ohio' });
    await page.locator('#zip-code').fill('43215');
  } else {
    await page.locator('#user_CompanyName').fill('Fictional QA Properties');
  }
  await page.locator('#phone-number').fill('6145550100');
  await page.locator('main').getByRole('button', { name: 'Legal Disclaimer', exact: true }).click();
  await page.locator('#agreeButton').click();
  await page.getByRole('button', { name: 'Sign Up', exact: true }).click();
  await acceptTerms(page);
  await expect(page.getByRole('heading', { level: 1 })).toContainText(firstName);
  return email;
}

async function login(page, email, secret = password) {
  await page.goto('/login');
  await page.locator('#email').fill(email);
  await page.locator('#login-password').fill(secret);
  await page.getByRole('button', { name: 'Log In', exact: true }).click();
}

async function initiate(page, role, email) {
  await page.goto('/mediations/new');
  await page.locator(role === 'tenant' ? '#landlord_email' : '#tenant-email').fill(email);
  await page.getByRole('button', { name: 'Request Negotiation' }).click();
}

async function intake(page, role) {
  await expect(page.getByRole('heading', { name: 'Start Your Intake Questions' })).toBeVisible();
  await page.locator('.reason-multiselect__toggle').click();
  await page.locator('#reason_failure_to_pay_rent').check();
  const today = new Date().toISOString().slice(0, 10);
  if (role === 'tenant') {
    await page.locator('#intake_question_DescribeCause').fill('Fictional QA missed rent');
    await page.locator('#intake_question_BestOption').selectOption({ label: 'Pay Missed Rent' });
    await page.locator("#intake_question_Section8_false").check();
    await page.locator('#intake_question_MoneyOwed').fill('1000');
    await page.locator("#total_cost_no").check();
    await page.locator('#monthly_rent_field').fill('900');
    await page.locator('#intake_question_DateDue').fill(today);
    await page.locator('#intake_question_PayableToday').fill('300');
  } else {
    await page.locator('#landlord_intake_question_LandlordDescribeCause').fill('Fictional QA missed rent');
    await page.locator('#landlord_intake_question_DesiredOutcome').selectOption({ label: 'Receive Payment' });
    await page.locator('#landlord_intake_question_AmountClaimed').fill('2000');
    await page.locator('#landlord_intake_question_DateDue').fill(today);
    await page.locator("#landlord_intake_question_AcceptPaymentPlan_false").check();
  }
  await page.getByRole('button', { name: 'Submit', exact: true }).click();
  await expect(page).toHaveURL(/\/messages$/);
}

async function openChat(page, path) {
  await page.goto(path);
  const confirm = page.getByRole('button', { name: 'I Understand' });
  if (await confirm.isVisible()) await confirm.click();
  await expect(page.locator('#message_contents')).toBeVisible();
}

module.exports = { acceptTerms, fictionalEmail, initiate, intake, login, openChat, signup, token };
