// The preview is a saved HTML agreement. Edits stay in this page until the user sends them.
const initializedGenerationEditors = new WeakSet();

function startDocumentGenerationEditor() {
  const guide = document.querySelector('[data-document-generation-editor]');
  if (!guide || initializedGenerationEditors.has(guide)) return;
  initializedGenerationEditors.add(guide);

  const frame = guide.querySelector('.document-iframe');
  const form = document.getElementById('document-generation-form');
  if (!frame || !form) return;
  const count = guide.querySelector('[data-agreement-edit-count]');
  const finish = guide.querySelector('[data-generation-finish]');
  const error = guide.querySelector('[data-agreement-editor-error]');
  const inputs = new Map(Array.from(form.querySelectorAll('[data-agreement-term]')).map(input => [input.dataset.agreementTerm, input]));
  const original = new Map(Array.from(inputs, ([key, input]) => [key, input.value]));
  const template = guide.dataset.agreementTemplate;

  const customResolution = template === 'custom_resolution_v1';
  const customFields = new Map();
  let customIssues = [];
  const requiredFields = guide.dataset.requiredAgreementFields?.split(' ') ?? [
    'landlord_name',
    'tenant_name',
    'address',
    'negotiation_date',
    'reason',
    'money_owed',
    ...(template === 'a' ? ['vacate_date'] : []),
    ...(template === 'b' ? [
      'monthly_rent', 'regular_rent_due_day', 'payment_recipient_instructions',
      'satisfaction_business_days', 'attachments'
    ] : [])
  ];
  const moveOutRules = guide.dataset.moveOutRules && JSON.parse(guide.dataset.moveOutRules);
  const value = field => inputs.get(field)?.value.trim() || '';
  let activeEdit = null;
  let movedToPreview = false;

  function report(message) {
    error.textContent = message;
    error.hidden = !message;
  }

  function moveOutChecks() {
    const { conditional, representation, methods, rows, instructions, choices, dates, counts, labels } = moveOutRules;
    const fields = [
      ...requiredFields,
      ...conditional.filter(([, conditions]) =>
        Object.entries(conditions).every(([field, options]) => options.includes(value(field)))).flatMap(([fields]) => fields),
      ...representation.filter(fields => fields.some(field => value(field))).flat()
    ];
    const validDate = date => {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date.startsWith('0000')) return false;
      const parsed = new Date(`${date}T00:00:00Z`);
      return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(date);
    };
    const validTime = time => /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(time);
    const validAmount = amount => /^\d+(?:\.\d{1,2})?$/.test(amount);
    const checks = fields.map(field => {
      const current = value(field);
      const label = labels[field] || field.replaceAll('_', ' ');
      if (!current) return `Complete the ${label}.`;
      if (current.length > 5000 || (choices[field] && !choices[field].includes(current))) return `Enter a valid value for ${label}.`;
      if (dates.includes(field) && !validDate(current)) return `Enter a valid date for ${label}.`;
      if (counts.includes(field) && !/^[1-9]\d*$/.test(current)) return `Enter the ${label} as a whole number greater than zero.`;
      if (field === 'move_out_time' && !validTime(current)) return `Enter a valid time for ${label}.`;
      if (field === 'move_out_amount' && !validAmount(current)) return `Enter the ${label} in dollars with up to two decimal places.`;
      return '';
    });
    if (['payment', 'both'].includes(value('move_out_payment'))) {
      checks.push(methods.some(field => value(field) === 'yes') ? '' : 'Select at least one payment method.');
      const activeRows = rows.map((fields, index) => [index + 1, fields.map(value)])
        .filter(([, values]) => values.some(Boolean));
      if (value('move_out_schedule')) {
        const lines = value('move_out_schedule').split(/\r?\n/).map(line => line.trim()).filter(Boolean);
        const valid = lines.every(line => {
          const [amount, date, time, extra] = line.split(/\s*\|\s*/);
          return value('move_out_schedule').length <= 30000 && !activeRows.length && extra === undefined && validAmount(amount) && validDate(date) && (!time || validTime(time));
        });
        checks.push(valid ? '' : 'Enter a valid amount, due date, and optional due time on each saved payment schedule line.');
      } else if (!activeRows.length) {
        checks.push('Add at least one payment with an amount and due date.');
      } else {
        activeRows.forEach(([number, [amount, date, time]]) => {
          checks.push(amount.length <= 5000 && validAmount(amount) ? '' : `Enter a valid amount for payment ${number} in dollars with up to two decimal places.`);
          checks.push(validDate(date) ? '' : `Enter a valid due date for payment ${number}.`);
          if (time) checks.push(validTime(time) ? '' : `Enter a valid due time for payment ${number}.`);
        });
      }
    }
    instructions.forEach(field => {
      if (value(field).length > 5000) checks.push(`Enter a valid value for ${field.replaceAll('_', ' ')}.`);
    });
    return checks;
  }

  function moveOutSignerError() {
    const signers = value('move_out_additional_signers').toLowerCase();
    return signers && signers !== moveOutRules.noAdditionalSigners ? moveOutRules.additionalSignersError : '';
  }

  function matchesConditions(conditions) {
    return Object.entries(conditions).every(([field, options]) => [options].flat().includes(value(field)));
  }

  function customChecks({ includeOptional = false } = {}) {
    const checks = [
      [...inputs.keys()].some(field => /^cr_action_.*_present$/.test(field) && value(field) === 'yes') ?
        '' : 'Add at least one agreed action.',
      customIssues.some(field => value(field) === 'yes') ? '' : 'Select at least one issue being resolved.'
    ];
    const representativePairs = ['landlord', 'tenant'].map(role =>
      [`${role}_representative`, `cr_${role}_capacity`]);
    const required = new Set(representativePairs.filter(pair => pair.some(field => value(field))).flat());

    customFields.forEach(({ agreementInput, agreementOptions, customRequired, customRule, label }, field) => {
      if (!matchesConditions(customRule)) return;

      const current = value(field);
      const isRequired = customRequired || required.has(field);
      if (!isRequired && (!includeOptional || !current)) return;
      if (!current) {
        checks.push(`Complete ${label.toLowerCase()}.`);
        return;
      }
      const valid = {
        select: () => Object.hasOwn(agreementOptions, current),
        date: () => /^\d{4}-\d{2}-\d{2}$/.test(current) && !current.startsWith('0000') &&
          new Date(`${current}T00:00:00Z`).toJSON()?.startsWith(current),
        time: () => /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(current),
        number: () => /^\d{1,9}(?:\.\d{1,2})?$/.test(current),
        'positive-integer': () => /^[1-9]\d{0,5}$/.test(current)
      };
      checks.push((valid[agreementInput]?.() ?? current.length <= 4000) ? '' : `Enter a valid value for ${label.toLowerCase()}.`);
    });
    return checks;
  }

  function registerCustomFields(container) {
    container.querySelectorAll('[data-agreement-field]').forEach(node => {
      const { agreementField, agreementInput, agreementOptions, customRequired, customRule } = node.dataset;
      if (!inputs.has(agreementField)) {
        const input = document.createElement('input');
        input.type = 'hidden';
        input.name = agreementField;
        input.dataset.agreementTerm = agreementField;
        form.append(input);
        inputs.set(agreementField, input);
        original.set(agreementField, '');
      }
      customFields.set(agreementField, {
        agreementInput, agreementOptions: JSON.parse(agreementOptions || 'null'),
        customRequired: customRequired === 'true', customRule: JSON.parse(customRule), label: node.title
      });
    });
  }

  function addCustomActionControls(doc) {
    const rows = doc.querySelector('[data-custom-inline-actions]');
    const template = doc.querySelector('[data-custom-inline-action-template]');
    const status = doc.querySelector('[data-custom-inline-status]');
    const add = doc.querySelector('[data-custom-inline-add]');
    rows.addEventListener('click', event => {
      const remove = event.target.closest('[data-custom-inline-remove]');
      if (!remove) return;

      if (activeEdit) activeEdit.finish(true);
      const row = remove.closest('[data-action-id]');
      const prefix = `cr_action_${row.dataset.actionId}_`;
      inputs.forEach((input, field) => {
        if (!field.startsWith(prefix)) return;
        input.remove();
        inputs.delete(field);
        original.delete(field);
        customFields.delete(field);
      });
      const next = row.nextElementSibling || row.previousElementSibling;
      row.remove();
      Array.from(rows.children).forEach((action, index) => {
        action.querySelector('h3 span').textContent = index + 1;
      });
      (next?.querySelector('[data-custom-inline-remove]') || add).focus();
      status.textContent = 'Action removed.';
      report('');
      refreshCount();
    });
    add.addEventListener('click', () => {
      const id = crypto.randomUUID();
      const row = template.content.firstElementChild.cloneNode(true);
      [row, ...row.querySelectorAll('[data-agreement-field], [data-custom-clause]')].forEach(node => {
        Object.entries(node.dataset).forEach(([key, data]) => {
          node.dataset[key] = data.replaceAll('00000000-0000-0000-0000-000000000000', id);
        });
      });
      row.querySelector('h3 span').textContent = rows.children.length + 1;
      rows.append(row);
      const input = document.createElement('input');
      input.type = 'hidden';
      input.name = `cr_action_${id}_present`;
      input.dataset.agreementTerm = input.name;
      input.value = 'yes';
      form.append(input);
      inputs.set(input.name, input);
      registerCustomFields(row);
      makeEditable(row);
      updateConditionalSections(doc);
      const field = row.querySelector('[data-agreement-field]');
      field.focus();
      status.textContent = 'Action added.';
      report('');
      refreshCount();
    });
  }

  function refreshCount() {
    if (customResolution) {
      const checks = customChecks();
      count.textContent = `${checks.filter(message => !message).length} of ${checks.length} required fields completed`;
      return;
    }
    if (moveOutRules) {
      const checks = moveOutChecks();
      count.textContent = `${checks.filter(message => !message).length} of ${checks.length} required fields completed`;
      const signerError = moveOutSignerError();
      if (signerError && error.hidden) report(signerError);
      if (!signerError && error.textContent === moveOutRules.additionalSignersError) report('');
      finish.disabled = false;
      return;
    }
    const missing = requiredFields.filter(field =>
      !inputs.get(field)?.value.trim()
    );
    const completed = requiredFields.length - missing.length;

    count.textContent =
      `${completed} of ${requiredFields.length} required fields completed`;

    finish.disabled = missing.length > 0;
  }

  form.querySelectorAll('[data-agreement-term]').forEach(input => {
    input.addEventListener('change', refreshCount);
  });

  function displayValue(field, value, node) {
    if (!value) {
      if (/^time[1-6]$/.test(field)) return '—';
      return field === 'additional_terms' ? '___________' :
        (node.dataset.agreementFormat === 'long-date' ? 'TBD' : '___________');
    }
    if (['regular_rent_due_day', 'monthly_payment_day'].includes(field) && /^\d{1,2}$/.test(value)) {
      const day = Number(value);
      const suffix = [11, 12, 13].includes(day) ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' }[day % 10] || 'th');
      const ordinal = `${day}${suffix}`;
      return field === 'monthly_payment_day' ? ordinal : `the ${ordinal} day of each month`;
    }
    if ((/^time[1-6]$/.test(field) || field === 'move_out_time') && /^\d{2}:\d{2}$/.test(value)) {
      const [hours, minutes] = value.split(':').map(Number);
      if (hours < 24 && minutes < 60) {
        return `${hours % 12 || 12}:${String(minutes).padStart(2, '0')} ${hours >= 12 ? 'PM' : 'AM'}`;
      }
    }
    if (node.dataset.agreementFormat === 'long-date') {
      const date = new Date(`${value}T12:00:00`);
      if (!Number.isNaN(date.getTime())) return new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric' }).format(date);
    }
    const choices = customFields.get(field)?.agreementOptions;
    return choices && Object.hasOwn(choices, value) ? choices[value] : value;
  }

  function sortPaymentRows(doc) {
    const tbody = doc.querySelector('[data-agreement-payment-anchor]')
      ?.parentElement.querySelector('table tbody');

    if (!tbody) return;

    const rows = Array.from(
      tbody.querySelectorAll('[data-agreement-payment-row]')
    );

    rows.sort((a, b) => {
      const dateA = inputs.get(`date${a.dataset.agreementPaymentRow}`)?.value || '9999-12-31';
      const dateB = inputs.get(`date${b.dataset.agreementPaymentRow}`)?.value || '9999-12-31';

      return dateA.localeCompare(dateB);
    });

    rows.forEach((row, index) => {
      if (!['b', 'move_out_v1'].includes(template)) row.querySelector('td').textContent = index + 1;
      tbody.append(row);
    });
  }

  function writeField(doc, field, value) {
    const input = inputs.get(field);
    if (!input) return;
    input.value = value;
    doc.querySelectorAll(`[data-agreement-field="${field}"]`).forEach(node => {
      if (node !== activeEdit?.node) node.textContent = displayValue(field, value, node);
      node.classList.toggle('agreement-changed', value !== original.get(field));
    });
    if (/^date[1-6]$/.test(field)) {
      sortPaymentRows(doc);
    }
    if (customResolution) {
      updateConditionalSections(doc);
      report('');
    }
    refreshCount();
  }

  function inputType(field) {
    if (/^(date[1-6]|negotiation_date|vacate_date|lump_sum_date|monthly_payment_start|final_payment_date|forgiveness_deadline)$/.test(field)) return 'date';
    if (/^time[1-6]$/.test(field)) return 'time';
    if (/^(amount[1-6]|money_owed|monthly_rent|rent_owed|late_fees|utilities|other_charges|lump_sum_amount|monthly_payment_amount|final_payment_amount|forgiveness_amount|forgiveness_remaining_amount)$/.test(field)) return 'number';
    return 'text';
  }

  function editField(doc, node) {
    if (activeEdit) activeEdit.finish(true);
    const field = node.dataset.agreementField;
    const type = node.dataset.agreementInput || inputType(field);
    const editor = doc.createElement(type === 'select' ? 'select' : type === 'textarea' || field === 'additional_terms' || field === 'reason' ? 'textarea' : 'input');
    if (editor.tagName === 'INPUT') editor.type = type;
    if (type === 'number' || type === 'positive-integer') {
      editor.type = 'number';
      editor.min = type === 'number' ? '0' : '1';
      editor.step = type === 'number' ? '0.01' : '1';
    }
    if (type === 'select') {
      const options = { '': 'Select an option', ...customFields.get(field).agreementOptions };
      Object.entries(options).forEach(([optionValue, label]) => {
        editor.add(new doc.defaultView.Option(label, optionValue));
      });
    }
    if (customResolution && ['text', 'textarea'].includes(type)) editor.maxLength = 4000;
    editor.value = inputs.get(field)?.value || '';
    editor.className = 'agreement-inline-input';
    if (node.title) editor.placeholder = node.title;
    editor.setAttribute('aria-label', `Edit ${node.title || field.replaceAll('_', ' ')}`);
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
    if (type === 'time') {
      editor.addEventListener('change', () => finish(true), { once: true });
    }
    if (type === 'select') {
      editor.addEventListener('change', () => {
        finish(true);
        node.focus();
      }, { once: true });
    }
    editor.addEventListener('keydown', event => {
      if (event.key === 'Escape') { event.preventDefault(); finish(false); }
      if (event.key === 'Enter' && editor.tagName === 'INPUT') { event.preventDefault(); finish(true); }
    });
    editor.focus();
    if (editor.tagName === 'TEXTAREA' || editor.type === 'text') editor.select();
  }

  function updateConditionalSections(doc) {
    if (customResolution) {
      customFields.forEach(({ customRule }, field) => {
        inputs.get(field).disabled = !matchesConditions(customRule);
      });
      doc.querySelectorAll('[data-custom-clause]').forEach(section => {
        section.hidden = !matchesConditions(JSON.parse(section.dataset.customClause));
      });
      const attachments = value('cr_attachments');
      doc.querySelector('[data-custom-attachments]').hidden = !attachments || attachments.toLowerCase() === 'none';
    }
    doc.querySelectorAll('[data-agreement-conditional]').forEach(section => {
      const field = section.dataset.agreementConditional;
      const expectedValue = section.dataset.agreementConditionalValue;

      const value = inputs.get(field)?.value || '';
      const selected = field === 'payment_method' ?
        value.split(',').includes(expectedValue) : expectedValue.split(' ').includes(value);

      section.hidden = !selected;
    });
  }

  function markChoices(doc) {
    doc.querySelectorAll('[data-agreement-choice]').forEach(node => {
      const field = node.dataset.agreementChoice;
      const currentValue = inputs.get(field)?.value || '';

      const selected = field === 'payment_method'
        ? currentValue.split(',').includes(node.dataset.agreementValue)
        : currentValue === node.dataset.agreementValue;
      node.querySelector('.checkbox')?.classList.toggle('checked', selected);
      node.classList.toggle('agreement-changed', inputs.get(field)?.value !== original.get(field));
      if (node.hasAttribute('data-custom-checkbox')) {
        node.setAttribute('aria-checked', selected);
      }
    });

    updateConditionalSections(doc);
  }

  function makeEditable(container) {
    container.querySelectorAll('[data-agreement-field], [data-agreement-choice]').forEach(node => {
      node.tabIndex = 0;
      if (node.hasAttribute('data-custom-checkbox')) {
        node.setAttribute('role', 'checkbox');
        return;
      }
      node.setAttribute('role', 'button');
      node.setAttribute('aria-label', node.dataset.agreementField ?
        `Edit ${(node.title || node.dataset.agreementField.replaceAll('_', ' '))}` :
        `Choose ${node.dataset.agreementChoice.replaceAll('_', ' ')}: ${node.dataset.agreementValue.replaceAll('_', ' ')}`);
    });
  }

  function addPaymentControls(doc) {
    doc.querySelectorAll('[data-agreement-payment-row]').forEach(row => {
      addPaymentControlsForRow(doc, row, Number(row.dataset.agreementPaymentRow));
    });
    const anchor = doc.querySelector('[data-agreement-payment-anchor]');
    if (!anchor) return;
    anchor.style.display = 'none';
    const add = doc.createElement('button');
    add.type = 'button';
    add.className = 'agreement-add-payment';
    add.textContent = '+ Add payment';
    add.addEventListener('click', () => {
      const number = Array.from({ length: 6 }, (_, index) => index + 1).find(index =>
        !doc.querySelector(`[data-agreement-payment-row="${index}"]`) &&
        !inputs.get(`amount${index}`)?.value && !inputs.get(`date${index}`)?.value && !inputs.get(`time${index}`)?.value);
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
        row.innerHTML = `
          ${template === 'move_out_v1' ? '' : `<td>${number}</td>`}
          <td>$<span data-agreement-field="amount${number}">___________</span></td>
          <td><span data-agreement-field="date${number}" data-agreement-format="long-date">TBD</span></td>
          <td><span data-agreement-field="time${number}" data-agreement-input="time" title="Time and AM/PM">—</span></td>
        `;
        table.querySelector('tbody').append(row);
      }
      row.className = 'agreement-new-payment';
      row.dataset.agreementPaymentRow = String(number);
      if (row.tagName === 'TR') sortPaymentRows(doc);
      addPaymentControlsForRow(doc, row, number);
      makeEditable(row);
      editField(doc, row.querySelector(`[data-agreement-field="amount${number}"]`));
    });
    const paymentList = doc.querySelector('.payment-list');

    if (paymentList) {
      paymentList.after(add);
    } else {
      anchor.before(add);
    }
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
      writeField(doc, `time${number}`, '');
      row.remove();
    });
    (row.tagName === 'TR' ? row.lastElementChild : row).append(remove);
  }

  function initializeFrame() {
    let doc;
    try { doc = frame.contentDocument; } catch (_) { /* The preview must be same origin. */ }
    // The browser exposes an empty about:blank frame before the requested document loads.
    // It is not an editor failure, and its load event must not show an error.
    if (!doc || doc.URL === 'about:blank') return;
    if (!doc?.body || !doc.querySelector('[data-agreement-field]')) {
      report('The document preview could not be edited. Reload the page and try again.');
      return;
    }
    if (!frame.hasAttribute('srcdoc')) report('');
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
      [data-custom-checkbox]::before { content: '☐ '; }
      [data-custom-checkbox][aria-checked="true"]::before { content: '☑ '; }
      @media print { .agreement-add-payment, .agreement-remove-payment { display: none; } }
    `;
    doc.head.append(style);
    if (customResolution) {
      customIssues = Array.from(doc.querySelectorAll('[data-custom-checkbox]'), node => node.dataset.agreementChoice);
      registerCustomFields(doc);
      addCustomActionControls(doc);
      finish.disabled = false;
    }
    makeEditable(doc);

    // Display prefilled information in the agreement.
    inputs.forEach((input, field) => {
      doc.querySelectorAll('[data-agreement-field]').forEach(node => {
        if (node.dataset.agreementField === field) {
          node.textContent = displayValue(field, customResolution ? value(field) : input.value, node);
        }
      });
    });
    doc.addEventListener('keydown', event => {
      if ((event.key === 'Enter' || event.key === ' ') &&
          event.target.matches('[data-agreement-field], [data-agreement-choice]')) {
        event.preventDefault();
        event.target.click();
      }
    });
    doc.addEventListener('click', event => {
      if (event.target.closest('.agreement-inline-input')) return;
      const field = event.target.closest('[data-agreement-field]');
      if (field) { editField(doc, field); return; }
      const choice = event.target.closest('[data-agreement-choice]');
      if (!choice || !inputs.has(choice.dataset.agreementChoice)) return;
      const choiceField = choice.dataset.agreementChoice;
      const input = inputs.get(choiceField);
      if (choice.hasAttribute('data-custom-checkbox')) {
        input.value = input.value === 'yes' ? '' : 'yes';
        report('');
      } else if (choiceField.startsWith('move_out_method_')) {
        input.value = input.value === 'yes' ? '' : 'yes';
      } else if (choiceField === 'payment_method' && guide.dataset.agreementTemplate === 'b') {
        const selectedMethods = new Set(input.value.split(',').filter(Boolean));
        const method = choice.dataset.agreementValue;

        if (selectedMethods.has(method)) {
          selectedMethods.delete(method);
        } else {
          selectedMethods.add(method);
        }

        input.value = Array.from(selectedMethods).join(',');
      } else if (choice.hasAttribute('data-agreement-toggle')) {
        input.value = input.value === '1' ? (original.get(choiceField) === '' ? '' : '0') : '1';
        if (choice.hasAttribute('data-additional-term-option')) {
          const hasTerms = ['review_payment_arrangement', 'other_additional_terms'].some(field => inputs.get(field).value === '1');
          inputs.get('additional_terms_selection').value = hasTerms ? 'included' : 'none';
        }
      } else if (choiceField === 'additional_terms_selection') {
        input.value = 'none';
        ['review_payment_arrangement', 'other_additional_terms'].forEach(field => {
          inputs.get(field).value = original.get(field) === '1' ? '0' : original.get(field);
        });
      } else if (choice.hasAttribute('data-agreement-select-one') || [
        'unresolved_payment_issues',
        'regular_rent_arrangement',
        'payment_application',
        'conditional_reduction',
        'rental_assistance',
        'assistance_status',
        'assistance_amount_status'
      ].includes(choiceField)) {
        input.value = choice.dataset.agreementValue;
      } else {
        input.value = input.value === choice.dataset.agreementValue ?
          (choiceField === 'payment_method' ? '' : (original.get(choiceField) === '' ? '' : '0')) :
          choice.dataset.agreementValue;
      }
      markChoices(doc);
      refreshCount();
    });
    if ((['a', 'b'].includes(template) || (template === 'move_out_v1' && doc.querySelector('[data-agreement-payment-anchor]')))) {
      addPaymentControls(doc);
    }
    markChoices(doc);
    refreshCount();
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
    if (customResolution) {
      const message = value('cr_additional_signers') === 'yes'
        ? guide.dataset.customSignerError : customChecks({ includeOptional: true }).find(Boolean);
      if (message) {
        event.preventDefault();
        report(message);
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
      }
      return;
    }
    if (moveOutRules) {
      const message = moveOutChecks().find(Boolean) || moveOutSignerError();
      if (message) {
        event.preventDefault();
        report(message);
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
      }
      return;
    }
    const dateWithoutAmount = Array.from({ length: 6 }, (_, index) => index + 1).some(number =>
      inputs.get(`date${number}`)?.value && !inputs.get(`amount${number}`)?.value);
    if (dateWithoutAmount) {
      event.preventDefault();
      report('A payment date needs a payment amount. Add an amount or remove the date.');
      guide.scrollIntoView({ block: 'start', behavior: 'auto' });
      return;
    }

    if (template === 'b') {
      const value = field => inputs.get(field)?.value.trim() || '';
      const rentDueDay = value('regular_rent_due_day');
      const rentArrangement = value('regular_rent_arrangement');

      const validDay = /^\d{1,2}$/.test(rentDueDay) && Number(rentDueDay) >= 1 && Number(rentDueDay) <= 31;
      if (!validDay && !/^\d{4}-\d{2}-\d{2}$/.test(rentDueDay)) {
        event.preventDefault();
        report('Please enter a day of the month (1–31) or a date (YYYY-MM-DD).');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }

      if (!['unchanged', 'modified'].includes(rentArrangement)) {
        event.preventDefault();
        report('Please select whether the regular rent arrangement is unchanged or modified.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }

      if (rentArrangement === 'modified' && !value('regular_rent_change_details')) {
        event.preventDefault();
        report('Please describe the agreed changes to regular rent.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }
      const unresolvedIssues = value('unresolved_payment_issues');

      if (!['yes', 'no'].includes(unresolvedIssues)) {
        event.preventDefault();
        report('Please select Yes or No for unresolved payment issues.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }

      if (unresolvedIssues === 'yes' && !value('unresolved_payment_details')) {
        event.preventDefault();
        report('Please describe the unresolved payment issues.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }

      const paymentRequirements = [
        {
          selected: value('payment_lump_sum') === '1',
          fields: ['lump_sum_amount', 'lump_sum_date'],
          label: 'Lump Sum Payment'
        },
        {
          selected: value('payment_monthly') === '1',
          fields: [
            'monthly_payment_amount',
            'monthly_payment_months',
            'monthly_payment_day',
            'monthly_payment_start'
          ],
          label: 'Monthly Payments'
        },
        {
          selected: value('payment_final') === '1',
          fields: ['final_payment_amount', 'final_payment_date'],
          label: 'Final Payment'
        }
      ];

      const customScheduleSelected = value('payment_custom_schedule') === '1';

      if (!paymentRequirements.some(option => option.selected) && !customScheduleSelected) {
        event.preventDefault();
        report('Please select at least one payment option.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }

      for (const option of paymentRequirements) {
        if (!option.selected) continue;

        const missingPaymentFields = option.fields.filter(field => !value(field));

        if (missingPaymentFields.length > 0) {
          event.preventDefault();
          report(`Please complete all fields for ${option.label}: ${missingPaymentFields.join(', ').replaceAll('_', ' ')}`);
          guide.scrollIntoView({ block: 'start', behavior: 'auto' });
          return;
        }
      }

      if (!value('payment_method')) {
        event.preventDefault();
        report('Please select a payment method.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }

      if (value('payment_method').split(',').includes('other') && !value('payment_method_other_description')) {
        event.preventDefault();
        report('Please describe the other payment method.');
        guide.scrollIntoView({ block: 'start', behavior: 'auto' });
        return;
      }
    }
    const missing = requiredFields.filter(field =>
      !inputs.get(field)?.value.trim()
    );

    if (missing.length > 0) {
      event.preventDefault();
      report(`Please complete all required fields: ${missing.join(', ').replaceAll('_', ' ')}`);
      guide.scrollIntoView({ block: 'start', behavior: 'auto' });
    }
  });
  refreshCount();
}

document.addEventListener('DOMContentLoaded', startDocumentGenerationEditor);
document.addEventListener('turbo:load', startDocumentGenerationEditor);
