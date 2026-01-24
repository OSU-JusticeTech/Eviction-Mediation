const MIN_HEIGHT = '38px';

const setupTextareaAutoExpand = () => {
  const textareas = document.querySelectorAll('.message-textarea');

  textareas.forEach((textarea) => {
    if (textarea.dataset.autoExpandInitialized === 'true') return;

    const autoExpand = () => {
      if (!textarea.value.trim()) {
        textarea.style.height = MIN_HEIGHT;
        return;
      }

      textarea.style.height = MIN_HEIGHT;
      const newHeight = Math.min(textarea.scrollHeight, 160);
      textarea.style.height = `${newHeight}px`;
    };

    textarea.addEventListener('input', autoExpand);
    textarea.dataset.autoExpandInitialized = 'true';

    if (textarea.value.trim()) {
      autoExpand();
    }
  });
};

const getComposerElements = (form) => {
  const textarea = form.querySelector('.message-textarea');
  const submitButton = form.querySelector('.send-msg-btn');
  const attachmentSelect = form.querySelector(
    "select[name$='[file_id]'], select[name='file_id']",
  );

  const hasAttachment = () =>
    Boolean(
      attachmentSelect &&
      attachmentSelect.value &&
      attachmentSelect.value.trim().length > 0,
    );

  const hasMessageText = () =>
    Boolean(textarea && textarea.value.trim().length > 0);

  const canSend = () => hasMessageText() || hasAttachment();

  const updateButtonState = () => {
    if (!submitButton) return;
    const enabled = canSend();
    submitButton.disabled = !enabled;
    submitButton.classList.toggle('is-ready', enabled);
  };

  return {
    textarea,
    submitButton,
    attachmentSelect,
    hasAttachment,
    hasMessageText,
    canSend,
    updateButtonState,
  };
};

const setupMediatorForms = () => {
  document.querySelectorAll('.mediator-message-form').forEach((form) => {
    if (form.dataset.composerInitialized === 'true') return;

    const elements = getComposerElements(form);
    form.dataset.composerInitialized = 'true';

    const {
      textarea,
      attachmentSelect,
      updateButtonState,
      canSend,
      submitButton,
    } = elements;

    if (textarea) {
      textarea.addEventListener('input', updateButtonState);

      textarea.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && !event.shiftKey && canSend()) {
          event.preventDefault();
          if (typeof form.requestSubmit === 'function') {
            form.requestSubmit();
          } else {
            form.dispatchEvent(
              new Event('submit', { bubbles: true, cancelable: true }),
            );
          }
        }
      });
    }

    if (attachmentSelect) {
      attachmentSelect.addEventListener('change', updateButtonState);
    }

    form.addEventListener('reset', () => {
      requestAnimationFrame(() => {
        updateButtonState();
        if (textarea) {
          textarea.style.height = MIN_HEIGHT;
        }
      });
    });

    form.addEventListener('submit', (event) => {
      event.preventDefault();

      if (!canSend()) {
        updateButtonState();
        return;
      }

      if (submitButton && submitButton.disabled) return;

      if (submitButton) {
        submitButton.disabled = true;
        submitButton.classList.remove('is-ready');
      }

      const csrfToken = document.querySelector('meta[name="csrf-token"]');
      const headers = {
        Accept: 'application/json',
      };

      if (csrfToken) {
        headers['X-CSRF-Token'] = csrfToken.content;
      }

      fetch(form.action, {
        method: 'POST',
        headers: headers,
        body: new FormData(form),
      })
        .then(async (response) => {
          if (!response.ok && response.status !== 204) {
            throw new Error('Failed to send message');
          }

          const contentType = response.headers.get('content-type') || '';
          let payload = null;

          if (contentType.includes('application/json')) {
            try {
              payload = await response.json();
            } catch (parseError) {
              if (response.status !== 204) {
                throw parseError;
              }
            }
          }

          return { payload, status: response.status };
        })
        .then(({ payload }) => {
          const isDuplicate = payload && payload.duplicate;

          if (isDuplicate) {
            if (submitButton) {
              submitButton.disabled = false;
            }
            updateButtonState();
            return;
          }

          if (textarea) {
            textarea.value = '';
            textarea.style.height = MIN_HEIGHT;
          }
          if (attachmentSelect) {
            attachmentSelect.value = '';
          }
          form.reset();
          updateButtonState();
        })
        .catch((error) => {
          console.error('Error sending mediator message:', error);
          if (submitButton) {
            submitButton.disabled = false;
            updateButtonState();
          }
        });
    });

    updateButtonState();
  });
};

const initializeMediatorChat = () => {
  setupTextareaAutoExpand();
  setupMediatorForms();

  // Show disclaimer modal with slight delay (tenants always, landlords once)
  const disclaimerModal = document.querySelector('[data-disclaimer-modal]');
  if (disclaimerModal) {
    const userRole = disclaimerModal.dataset.userRole;
    const disclaimerKey = `chatDisclaimerSeen_${userRole}`;

    let shouldShowModal = true;

    // For landlords, check if they've seen it before
    if (userRole === 'Landlord') {
      const hasSeenDisclaimer = localStorage.getItem(disclaimerKey);
      if (hasSeenDisclaimer) {
        shouldShowModal = false; // Don't show modal again for landlords
      }
    }
    // Tenants always see it (shouldShowModal stays true)

    if (shouldShowModal) {
      setTimeout(() => {
        disclaimerModal.hidden = false;
        requestAnimationFrame(() => {
          disclaimerModal.classList.add('is-open');
        });
      }, 300);
    }
  }

  // Disclaimer modal close handler
  const disclaimerCloseButtons = document.querySelectorAll(
    '[data-disclaimer-modal-close]',
  );
  disclaimerCloseButtons.forEach((button) => {
    button.addEventListener('click', () => {
      const modal = document.querySelector('[data-disclaimer-modal]');
      if (modal) {
        modal.classList.remove('is-open');
        modal.hidden = true;

        // Mark as seen for landlords
        const userRole = modal.dataset.userRole;
        if (userRole === 'Landlord') {
          const disclaimerKey = `chatDisclaimerSeen_${userRole}`;
          localStorage.setItem(disclaimerKey, 'true');
        }
      }
    });
  });

  // Also mark as seen when clicking outside the modal
  if (disclaimerModal) {
    disclaimerModal.addEventListener('click', (e) => {
      if (e.target === disclaimerModal) {
        disclaimerModal.classList.remove('is-open');
        disclaimerModal.hidden = true;

        const userRole = disclaimerModal.dataset.userRole;
        if (userRole === 'Landlord') {
          const disclaimerKey = `chatDisclaimerSeen_${userRole}`;
          localStorage.setItem(disclaimerKey, 'true');
        }
      }
    });
  }
};

const eagerInitializeMediatorChat = () => {
  if (
    document.readyState === 'complete' ||
    document.readyState === 'interactive'
  ) {
    initializeMediatorChat();
  }
};

document.addEventListener('turbo:load', initializeMediatorChat);
document.addEventListener('turbo:frame-load', (event) => {
  const frame = event.target;
  if (
    frame &&
    typeof frame.querySelector === 'function' &&
    frame.querySelector('.mediator-message-form')
  ) {
    initializeMediatorChat();
  }
});

eagerInitializeMediatorChat();
