// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import "controllers";
import "channels";
import "chat/negotiation_chat";
import "chat/mediator_chats";

(function () {
  if (window.__navToggleInit) return;

  function onDocumentClick(e) {
    // click on the hamburger
    const toggle = e.target.closest('#navbar-toggle');
    if (toggle) {
      e.preventDefault();
      const menu = document.querySelector('.navbar-menu');
      if (menu) {
        menu.classList.toggle('active');
        toggle.setAttribute('aria-expanded', String(menu.classList.contains('active')));
      }
      return;
    }

    // click on resources dropdown toggle on mobile or any touch device — toggle sub-menu without closing nav
    const dropdownToggle = e.target.closest('.nav-dropdown-toggle');
    if (dropdownToggle && (window.innerWidth <= 850 || window.matchMedia('(hover: none)').matches)) {
      e.preventDefault();
      const dropdown = dropdownToggle.closest('.nav-dropdown');
      if (dropdown) {
        const opening = !dropdown.classList.contains('is-open');
        dropdown.classList.toggle('is-open');
        dropdownToggle.setAttribute('aria-expanded', String(opening));
      }
      return;
    }

    // click on any menu link and then close mobile menu
    const menuLink = e.target.closest('.navbar-menu a');
    if (menuLink) {
      const menu = document.querySelector('.navbar-menu');
      if (menu) {
        menu.classList.remove('active');
        document.querySelectorAll('.nav-dropdown.is-open').forEach(d => d.classList.remove('is-open'));
        const navToggle = document.querySelector('#navbar-toggle');
        if (navToggle) navToggle.setAttribute('aria-expanded', 'false');
      }
      return;
    }

    // click outside closes the menu and any open dropdowns
    const clickedInsideNav = e.target.closest('.navbar-menu') || e.target.closest('#navbar-toggle');
    if (!clickedInsideNav) {
      const menu = document.querySelector('.navbar-menu');
      if (menu && menu.classList.contains('active')) {
        menu.classList.remove('active');
        const navToggle = document.querySelector('#navbar-toggle');
        if (navToggle) navToggle.setAttribute('aria-expanded', 'false');
      }
      document.querySelectorAll('.nav-dropdown.is-open').forEach(d => {
        d.classList.remove('is-open');
        const t = d.querySelector('.nav-dropdown-toggle');
        if (t) t.setAttribute('aria-expanded', 'false');
      });
    }
  }

  function init() {
    if (window.__navToggleInit) return;
    document.addEventListener('click', onDocumentClick);
    window.__navToggleInit = true;
  }

  // initialize on normal page load and Turbo/Turbolinks loads
  document.addEventListener('DOMContentLoaded', init);
  document.addEventListener('turbo:load', init);
  document.addEventListener('turbolinks:load', init);
})();

  const updateBodyModalState = () => {
    const hasOpenModal = document.querySelector('[data-conversation-info-panel]:not([hidden])') ||
      document.querySelector('[data-end-modal]:not([hidden])') ||
      document.querySelector('[data-document-preview]:not([hidden])');

    document.body.classList.toggle('has-modal-open', Boolean(hasOpenModal));
  };

  const initConversationInfoPanel = () => {
    const panel = document.querySelector('[data-conversation-info-panel]');
    if (!panel) return;

    panel.setAttribute('tabindex', '-1');

    const openButtons = document.querySelectorAll('[data-conversation-info-toggle]');
    const closeButtons = panel.querySelectorAll('[data-conversation-info-close]');

    const openPanel = () => {
      panel.hidden = false;
      panel.classList.add('is-open');
      panel.focus();
      updateBodyModalState();
    };

    const closePanel = () => {
      panel.classList.remove('is-open');
      panel.hidden = true;
      updateBodyModalState();
    };

    openButtons.forEach((button) => {
      if (button.dataset.boundConversationInfo) return;
      button.dataset.boundConversationInfo = 'true';
      button.addEventListener('click', openPanel);
    });

    closeButtons.forEach((button) => {
      if (button.dataset.boundConversationInfoClose) return;
      button.dataset.boundConversationInfoClose = 'true';
      button.addEventListener('click', closePanel);
    });

    panel.addEventListener('click', (event) => {
      if (event.target === panel) {
        closePanel();
      }
    });

    panel.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closePanel();
      }
    });
  };

  const initAttachmentMenus = () => {
    document.querySelectorAll('[data-attachment-toggle]').forEach((toggle) => {
      if (toggle.dataset.boundAttachmentToggle) return;
      toggle.dataset.boundAttachmentToggle = 'true';

      const composer = toggle.closest('.message-composer, form');
      if (!composer) return;

      const menu = composer.querySelector('[data-attachment-menu]');
      if (!menu) return;

      const updateState = () => {
        const isHidden = menu.hasAttribute('hidden');
        toggle.setAttribute('aria-expanded', String(!isHidden));
      };

      toggle.addEventListener('click', () => {
        if (menu.hasAttribute('hidden')) {
          menu.removeAttribute('hidden');
        } else {
          menu.setAttribute('hidden', '');
        }
        updateState();
      });

      document.addEventListener('click', (event) => {
        if (!menu.hasAttribute('hidden')) {
          if (!menu.contains(event.target) && !toggle.contains(event.target)) {
            menu.setAttribute('hidden', '');
            updateState();
          }
        }
      });

      updateState();
    });
  };

  const initEndModal = () => {
    document.querySelectorAll('[data-chat-actions]').forEach((actions) => {
      const modal = actions.querySelector('[data-end-modal]');
      if (!modal) return;

      const openButtons = actions.querySelectorAll('[data-end-modal-open]');
      const closeButtons = modal.querySelectorAll('[data-end-modal-close]');

      const openModal = () => {
        modal.hidden = false;
        modal.classList.add('is-open');
        modal.focus();
        updateBodyModalState();
      };

      const closeModal = () => {
        modal.classList.remove('is-open');
        modal.hidden = true;
        updateBodyModalState();
      };

      if (!modal.dataset.boundEndModal) {
        modal.dataset.boundEndModal = 'true';
        modal.setAttribute('tabindex', '-1');
        modal.addEventListener('click', (event) => {
          if (event.target === modal) {
            closeModal();
          }
        });
        modal.addEventListener('keydown', (event) => {
          if (event.key === 'Escape') {
            closeModal();
          }
        });
      }

      openButtons.forEach((button) => {
        if (button.dataset.boundEndModalOpen) return;
        button.dataset.boundEndModalOpen = 'true';
        button.addEventListener('click', openModal);
      });

      closeButtons.forEach((button) => {
        if (button.dataset.boundEndModalClose) return;
        button.dataset.boundEndModalClose = 'true';
        button.addEventListener('click', closeModal);
      });
    });
  };

  const initMediatorModal = () => {
    document.querySelectorAll('[data-chat-actions]').forEach((actions) => {
      const modal = actions.querySelector('[data-mediator-modal]');
      const openButton = actions.querySelector('[data-mediator-modal-open]');
      if (!modal || !openButton) return;

      const closeButtons = modal.querySelectorAll('[data-mediator-modal-close]');

      const openModal = () => {
        modal.hidden = false;
        modal.classList.add('is-open');
        modal.focus();
        updateBodyModalState();
      };

      const closeModal = () => {
        modal.classList.remove('is-open');
        modal.hidden = true;
        updateBodyModalState();
      };

      if (!modal.dataset.boundMediatorModal) {
        modal.dataset.boundMediatorModal = 'true';
        modal.setAttribute('tabindex', '-1');
        modal.addEventListener('click', (event) => {
          if (event.target === modal) {
            closeModal();
          }
        });
        modal.addEventListener('keydown', (event) => {
          if (event.key === 'Escape') {
            closeModal();
          }
        });
      }

      if (!openButton.dataset.boundMediatorModalOpen) {
        openButton.dataset.boundMediatorModalOpen = 'true';
        openButton.addEventListener('click', openModal);
      }

      closeButtons.forEach((button) => {
        if (button.dataset.boundMediatorModalClose) return;
        button.dataset.boundMediatorModalClose = 'true';
        button.addEventListener('click', closeModal);
      });
    });
  };

  const documentPreview = (() => {
    let overlay;
    let dialog;
    let frame;
    let nameLabel;

    const ensureElements = () => {
      overlay = document.querySelector('[data-document-preview]');
      if (!overlay) return false;
      dialog = overlay.querySelector('.document-preview-dialog');
      frame = overlay.querySelector('[data-document-preview-frame]');
      nameLabel = overlay.querySelector('[data-document-preview-name]');
      if (dialog && !dialog.hasAttribute('tabindex')) {
        dialog.setAttribute('tabindex', '-1');
      }
      return true;
    };

    const open = (trigger) => {
      if (!ensureElements()) return;

      const previewUrl = trigger.getAttribute('data-preview-url');
      if (!previewUrl) return;

      const fileName = trigger.getAttribute('data-file-name') || 'Document preview';

      overlay.hidden = false;
      overlay.classList.add('is-open');

      if (frame) {
        frame.src = previewUrl;
      }

      if (nameLabel) {
        nameLabel.textContent = fileName;
      }

      updateBodyModalState();

      if (dialog) {
        dialog.focus();
      }
    };

    const close = () => {
      if (!ensureElements()) return;

      overlay.classList.remove('is-open');
      overlay.hidden = true;

      if (frame) {
        frame.removeAttribute('src');
      }

      updateBodyModalState();
    };

    const bind = () => {
      if (!ensureElements()) return;

      if (!document.body.dataset.boundDocumentPreviewTriggers) {
        document.body.dataset.boundDocumentPreviewTriggers = 'true';

        document.addEventListener('click', (event) => {
          const trigger = event.target.closest('[data-document-preview-trigger]');
          if (!trigger) return;
          event.preventDefault();
          open(trigger);
        });

        document.addEventListener('keydown', (event) => {
          if (event.key === 'Escape') {
            ensureElements();
            if (overlay && !overlay.hidden) {
              close();
            }
          }
        });

        document.addEventListener('turbo:before-cache', () => {
          ensureElements();
          if (overlay && !overlay.hidden) {
            close();
          }
        });
      }

      if (!overlay.dataset.boundDocumentPreviewOverlay) {
        overlay.dataset.boundDocumentPreviewOverlay = 'true';
        overlay.addEventListener('click', (event) => {
          if (event.target === overlay) {
            close();
          }
        });
      }

      const closeButton = overlay.querySelector('[data-document-preview-close]');
      if (closeButton && !closeButton.dataset.boundDocumentPreviewClose) {
        closeButton.dataset.boundDocumentPreviewClose = 'true';
        closeButton.addEventListener('click', (event) => {
          event.preventDefault();
          close();
        });
      }
    };

    return {
      init: () => {
        if (!ensureElements()) return;
        bind();
      }
    };
  })();

  const initChatExperience = () => {
    initConversationInfoPanel();
    initAttachmentMenus();
    initEndModal();
    initMediatorModal();
    documentPreview.init();
  };

  document.addEventListener('turbo:load', initChatExperience);
  document.addEventListener('DOMContentLoaded', initChatExperience);
