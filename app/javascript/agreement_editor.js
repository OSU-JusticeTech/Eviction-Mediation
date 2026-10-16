// The preview is a saved HTML agreement. Edits stay in this page until the user sends them.
const initializedEditors = new WeakSet();

function startAgreementEditor() {
  const guide = document.querySelector('[data-agreement-editor]');
  if (!guide || initializedEditors.has(guide)) return;
  initializedEditors.add(guide);

  const frame = document.querySelector('.document-iframe');
  const form = document.getElementById('agreement-editor-form');
  const count = guide.querySelector('[data-agreement-edit-count]');
  const finish = guide.querySelector('[data-agreement-finish]');
  const error = guide.querySelector('[data-agreement-editor-error]');
  const inputs = new Map(Array.from(form.querySelectorAll('[data-agreement-term]')).map(input => [input.dataset.agreementTerm, input]));
  const original = new Map(Array.from(inputs, ([key, input]) => [key, input.value]));
  let activeEdit = null;
  let movedToPreview = false;

  function report(message) {
    error.textContent = message;
    error.hidden = !message;
  }

  function refreshCount() {
    const changed = Array.from(inputs).filter(([key, input]) => input.value !== original.get(key)).length;
    count.textContent = changed === 0 ? 'No changes yet' : `${changed} changed ${changed === 1 ? 'field' : 'fields'} ready to send`;
    finish.disabled = changed === 0;
  }

  function displayValue(field, value, node) {
    if (!value) return field === 'additional_terms' ? '___________' : (node.dataset.agreementFormat === 'long-date' ? 'TBD' : '___________');
    if (node.dataset.agreementFormat === 'long-date') {
      const date = new Date(`${value}T12:00:00`);
      if (!Number.isNaN(date.getTime())) return new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric' }).format(date);
    }
    return value;
  }

  function writeField(doc, field, value) {
    const input = inputs.get(field);
    if (!input) return;
    input.value = value;
    doc.querySelectorAll(`[data-agreement-field="${field}"]`).forEach(node => {
      if (node !== activeEdit?.node) node.textContent = displayValue(field, value, node);
      node.classList.toggle('agreement-changed', value !== original.get(field));
    });
    refreshCount();
  }

  function inputType(field) {
    if (/^(date[1-6]|negotiation_date|vacate_date|lump_sum_date|monthly_payment_start|final_payment_date)$/.test(field)) return 'date';
    if (/^(amount[1-6]|money_owed|monthly_rent|rent_owed|late_fees|utilities|other_charges|lump_sum_amount|monthly_payment_amount|final_payment_amount)$/.test(field)) return 'number';
    return 'text';
  }

  function editField(doc, node) {
    if (activeEdit) activeEdit.finish(true);
    const field = node.dataset.agreementField;
    const type = inputType(field);
    const editor = doc.createElement(field === 'additional_terms' || field === 'reason' ? 'textarea' : 'input');
    if (editor.tagName === 'INPUT') editor.type = type;
    if (type === 'number') { editor.min = '0'; editor.step = '0.01'; }
    editor.value = inputs.get(field)?.value || '';
    editor.className = 'agreement-inline-input';
    editor.setAttribute('aria-label', `Edit ${field.replaceAll('_', ' ')}`);
    node.textContent = '';
    node.append(editor);
    const finish = save => {
      if (activeEdit?.node !== node) return;
      const value = save ? editor.value.trim() : inputs.get(field).value;
      activeEdit = null;
      node.textContent = displayValue(field, value, node);
      if (save) writeField(doc, field, value);
    };
    activeEdit = { node, finish };
    editor.addEventListener('blur', () => finish(true), { once: true });
    editor.addEventListener('keydown', event => {
      if (event.key === 'Escape') { event.preventDefault(); finish(false); }
      if (event.key === 'Enter' && editor.tagName !== 'TEXTAREA') { event.preventDefault(); finish(true); }
    });
    editor.focus();
    if (type !== 'date') editor.select();
  }

  function markChoices(doc) {
    doc.querySelectorAll('[data-agreement-choice]').forEach(node => {
      const field = node.dataset.agreementChoice;
      const selected = inputs.get(field)?.value === node.dataset.agreementValue;
      node.querySelector('.checkbox')?.classList.toggle('checked', selected);
      node.classList.toggle('agreement-changed', inputs.get(field)?.value !== original.get(field));
    });
  }

  function makeEditable(container) {
    container.querySelectorAll('[data-agreement-field], [data-agreement-choice]').forEach(node => {
      node.tabIndex = 0;
      node.setAttribute('role', 'button');
      node.setAttribute('aria-label', node.dataset.agreementField ?
        `Edit ${node.dataset.agreementField.replaceAll('_', ' ')}` :
        `Choose ${node.dataset.agreementChoice.replaceAll('_', ' ')}: ${node.dataset.agreementValue.replaceAll('_', ' ')}`);
    });
  }

  function addPaymentControls(doc) {
    doc.querySelectorAll('[data-agreement-payment-row]').forEach(row => {
      const number = Number(row.dataset.agreementPaymentRow);
      const remove = doc.createElement('button');
      remove.type = 'button';
      remove.className = 'agreement-remove-payment';
      remove.textContent = 'Remove payment';
      remove.addEventListener('click', () => {
        if (activeEdit) activeEdit.finish(true);
        writeField(doc, `amount${number}`, '');
        writeField(doc, `date${number}`, '');
        row.remove();
      });
      (row.tagName === 'TR' ? row.lastElementChild : row).append(remove);
    });
    const anchor = doc.querySelector('[data-agreement-payment-anchor]');
    if (!anchor) return;
    anchor.style.display = 'block';
    const add = doc.createElement('button');
    add.type = 'button';
    add.className = 'agreement-add-payment';
    add.textContent = '+ Add payment';
    add.addEventListener('click', () => {
      const number = Array.from({ length: 6 }, (_, index) => index + 1).find(index =>
        !inputs.get(`amount${index}`)?.value && !inputs.get(`date${index}`)?.value);
      if (!number) { report('The payment schedule supports up to six payments.'); return; }
      report('');
      let row;
      if (guide.dataset.agreementTemplate === 'a') {
        let list = doc.querySelector('.payment-list');
        if (!list) {
          const section = doc.createElement('li');
          section.textContent = 'Tenant agrees to pay Landlord in the following manner:';
          list = doc.createElement('ol');
          list.className = 'payment-list';
          section.append(list);
          anchor.before(section);
        }
        row = doc.createElement('li');
        row.innerHTML = `$<span class="inline-underline" data-agreement-field="amount${number}">___________</span> on or before <span class="inline-underline" data-agreement-field="date${number}" data-agreement-format="long-date">TBD</span> by 5:00 PM`;
        list.append(row);
      } else {
        let table = anchor.parentElement.querySelector('table');
        if (!table) {
          table = doc.createElement('table');
          table.innerHTML = '<thead><tr><th>Installment</th><th>Amount</th><th>Due Date</th></tr></thead><tbody></tbody>';
          anchor.before(table);
        }
        row = doc.createElement('tr');
        row.innerHTML = `<td>${number}</td><td>$<span data-agreement-field="amount${number}">___________</span></td><td><span data-agreement-field="date${number}" data-agreement-format="long-date">TBD</span></td>`;
        table.querySelector('tbody').append(row);
      }
      row.className = 'agreement-new-payment';
      row.dataset.agreementPaymentRow = String(number);
      addPaymentControlsForRow(doc, row, number);
      makeEditable(row);
      editField(doc, row.querySelector(`[data-agreement-field="amount${number}"]`));
    });
    anchor.append(add);
  }

  function addPaymentControlsForRow(doc, row, number) {
    const remove = doc.createElement('button');
    remove.type = 'button';
    remove.className = 'agreement-remove-payment';
    remove.textContent = 'Remove payment';
    remove.addEventListener('click', () => {
      if (activeEdit) activeEdit.finish(true);
      writeField(doc, `amount${number}`, '');
      writeField(doc, `date${number}`, '');
      row.remove();
    });
    (row.tagName === 'TR' ? row.lastElementChild : row).append(remove);
  }

  function initializeFrame() {
    let doc;
    try { doc = frame.contentDocument; } catch (_) { /* The preview must be same origin. */ }
    // The browser exposes an empty about:blank frame before the requested document loads.
    // It is not an editor failure, and its load event must not show an error.
    if (doc?.URL !== frame.src) return;
    if (!doc?.body || !doc.querySelector('[data-agreement-field]')) {
      report('The document preview could not be edited. Reload the page and try again.');
      return;
    }
    report('');
    if (doc.body.dataset.agreementEditing) return;
    doc.body.dataset.agreementEditing = 'true';
    const style = doc.createElement('style');
    style.textContent = `
      [data-agreement-field], [data-agreement-choice] { cursor: pointer; outline: 1px dashed #4b83bd; outline-offset: 2px; background: #eff7ff; }
      [data-agreement-field]:hover, [data-agreement-choice]:hover { background: #dceefe; }
      [data-agreement-field].agreement-changed, [data-agreement-choice].agreement-changed { background: #e6f6e9; }
      .agreement-inline-input { box-sizing: border-box; max-width: 100%; min-width: 110px; font: inherit; padding: 3px; border: 2px solid #2463a3; border-radius: 4px; }
      textarea.agreement-inline-input { min-width: 220px; min-height: 50px; }
      .agreement-add-payment, .agreement-remove-payment { cursor: pointer; color: #164c82; background: #f2f7fd; border: 1px solid #9ebbd8; border-radius: 5px; padding: 4px 8px; margin: 5px; font: 13px Arial, sans-serif; }
      .agreement-new-payment { margin: 8px 0; }
      @media print { .agreement-add-payment, .agreement-remove-payment { display: none; } }
    `;
    doc.head.append(style);
    makeEditable(doc);
    doc.addEventListener('keydown', event => {
      if ((event.key === 'Enter' || event.key === ' ') &&
          event.target.matches('[data-agreement-field], [data-agreement-choice]')) {
        event.preventDefault();
        event.target.click();
      }
    });
    doc.addEventListener('click', event => {
      const field = event.target.closest('[data-agreement-field]');
      if (field && !event.target.closest('.agreement-inline-input')) { editField(doc, field); return; }
      const choice = event.target.closest('[data-agreement-choice]');
      if (!choice || !inputs.has(choice.dataset.agreementChoice)) return;
      const choiceField = choice.dataset.agreementChoice;
      const input = inputs.get(choiceField);
      input.value = input.value === choice.dataset.agreementValue ?
        (choiceField === 'payment_method' ? '' : (original.get(choiceField) === '' ? '' : '0')) : choice.dataset.agreementValue;
      markChoices(doc);
      refreshCount();
    });
    if (guide.dataset.agreementTemplate !== 'b') addPaymentControls(doc);
    markChoices(doc);
    guide.dataset.editorReady = 'true';
    if (!movedToPreview) {
      movedToPreview = true;
      requestAnimationFrame(() => {
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
      });
    }
  }

  frame.addEventListener('load', initializeFrame);
  if (frame.contentDocument?.readyState === 'complete') initializeFrame();
  form.addEventListener('submit', event => {
    if (activeEdit) activeEdit.finish(true);
    const dateWithoutAmount = Array.from({ length: 6 }, (_, index) => index + 1).some(number =>
      inputs.get(`date${number}`)?.value && !inputs.get(`amount${number}`)?.value);
    if (dateWithoutAmount) {
      event.preventDefault();
      report('A payment date needs a payment amount. Add an amount or remove the date.');
      guide.scrollIntoView({ block: 'start', behavior: 'auto' });
      return;
    }
    if (Array.from(inputs).every(([key, input]) => input.value === original.get(key))) event.preventDefault();
  });
  refreshCount();
}

document.addEventListener('DOMContentLoaded', startAgreementEditor);
document.addEventListener('turbo:load', startAgreementEditor);
