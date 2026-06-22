const MODAL_SELECTOR = '[data-disclaimer-modal]';
const CLOSE_SELECTOR = '[data-disclaimer-modal-close]';

// The chat-terms modal is a native <dialog>. Opening it with showModal() puts it
// in the browser's top layer, which enforces a focus trap (the rest of the page
// becomes inert and cannot be tabbed into) and handles Escape for us.
export const setupChatDisclaimer = () => {
  const modal = document.querySelector(MODAL_SELECTOR);
  if (!modal || modal.dataset.boundDisclaimer === 'true') return;
  modal.dataset.boundDisclaimer = 'true';

  const disclaimerKey = `chatDisclaimerSeen_${modal.dataset.userRole}`;
  const rememberSeen = () => localStorage.setItem(disclaimerKey, 'true');

  const openModal = () => {
    if (modal.open) return;
    if (typeof modal.showModal === 'function') {
      modal.showModal();
    } else {
      modal.setAttribute('open', '');
    }
    // showModal() auto-focuses the first button, which shows a focus ring on
    // open. Move focus to the dialog itself (outline: none) so no ring appears;
    // keyboard users can still Tab to reach the buttons.
    modal.focus();
  };

  const closeModal = () => {
    if (typeof modal.close === 'function' && modal.open) {
      modal.close();
    } else {
      modal.removeAttribute('open');
      rememberSeen();
    }
  };

  // Mark as seen on any close (button, Escape, or programmatic).
  modal.addEventListener('close', rememberSeen);

  if (!localStorage.getItem(disclaimerKey)) {
    setTimeout(openModal, 300);
  }

  modal
    .querySelectorAll(CLOSE_SELECTOR)
    .forEach((button) => button.addEventListener('click', closeModal));

  // Clicking the backdrop (the dialog element itself, outside the content) closes it.
  modal.addEventListener('click', (event) => {
    if (event.target === modal) closeModal();
  });
};
