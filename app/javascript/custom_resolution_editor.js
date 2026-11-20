function updateConditionalFields(container) {
  const fields = [...container.querySelectorAll('[data-custom-field]')];
  const values = new Map(fields.map(field => {
    const control = field.querySelector('select, textarea, input:not([type="hidden"])');
    const key = control.name.replace(/^counteroffer\[|\]$/g, '');
    return [key, control.type === 'checkbox' && !control.checked ? '' : control.value];
  }));

  fields.forEach(field => {
    const rules = JSON.parse(field.dataset.customRule);
    field.hidden = Object.entries(rules).some(([name, choices]) =>
      ![choices].flat().includes(values.get(name)));
  });
}

function initializeCustomResolution() {
  document.querySelectorAll('[data-custom-resolution-fields]').forEach(updateConditionalFields);
}

document.addEventListener('change', event => {
  const container = event.target.closest('[data-custom-resolution-fields]');
  if (container) updateConditionalFields(container);
});

document.addEventListener('DOMContentLoaded', initializeCustomResolution);
document.addEventListener('turbo:load', initializeCustomResolution);
