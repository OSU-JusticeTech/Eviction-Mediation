// "Jump to latest" affordance for chat threads.
//
// On load the thread lands on the first unread message (a divider is inserted
// there) instead of always snapping to the newest message. A floating button
// appears whenever the user is scrolled away from the bottom, showing how many
// new messages have arrived. Read state is tracked client-side in localStorage
// keyed by user + conversation, so it works for every role (tenant, landlord,
// mediator/admin) without any server-side read receipts.

const STORAGE_PREFIX = 'chatLastRead';
const BOTTOM_THRESHOLD = 80; // px tolerance for treating the view as "at bottom"
const BUTTON_GAP = 14; // px above the composer

const prefersReducedMotion = () =>
  typeof window.matchMedia === 'function' &&
  window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const storageKey = (userId, conversationId) =>
  `${STORAGE_PREFIX}:${userId || 'anon'}:${conversationId}`;

// Returns the stored watermark, or null when this browser has never recorded a
// read position for the conversation (first visit).
const readLastReadId = (userId, conversationId) => {
  try {
    const raw = window.localStorage.getItem(storageKey(userId, conversationId));
    if (raw === null) return null;
    const id = parseInt(raw, 10);
    return Number.isFinite(id) ? id : null;
  } catch (error) {
    return null;
  }
};

const writeLastReadId = (userId, conversationId, id) => {
  try {
    window.localStorage.setItem(storageKey(userId, conversationId), String(id));
  } catch (error) {
    /* localStorage unavailable (private mode / disabled) — degrade silently */
  }
};

export const setupJumpToLatest = ({ container, list, currentUserId, conversationId }) => {
  if (!container || !list || !conversationId) return null;

  // Re-use an existing controller if this container is re-initialized within the
  // same page lifetime (e.g. turbo:frame-load after turbo:load).
  if (container.dataset.jumpToLatestBound === 'true' && container.__jumpToLatestController) {
    return container.__jumpToLatestController;
  }
  container.dataset.jumpToLatestBound = 'true';

  const userId = currentUserId != null ? String(currentUserId) : '';
  const anchor = container.closest('.chat-panel') || container.parentElement || container;
  let unreadCount = 0;
  let hasPositioned = false;

  // Clear any orphaned button/divider that a Turbo-cached snapshot may have left
  // behind (its old controller is gone, so nothing would ever hide it).
  anchor.querySelectorAll('.chat-jump-latest').forEach((el) => el.remove());
  list.querySelectorAll('.unread-divider').forEach((el) => el.remove());

  const button = document.createElement('button');
  button.type = 'button';
  // Visibility is driven entirely by the `is-visible` class (see showButton /
  // hideButton). The base class is display:none, so it starts hidden.
  button.className = 'chat-jump-latest';
  button.innerHTML = `
    <span class="chat-jump-latest__count" data-jump-count></span>
    <span class="chat-jump-latest__text">Jump to latest</span>
    <i class="fa-solid fa-arrow-down" aria-hidden="true"></i>
  `;
  anchor.appendChild(button);
  const countEl = button.querySelector('[data-jump-count]');

  const showButton = () => {
    positionButton();
    button.classList.add('is-visible');
  };

  const hideButton = () => {
    button.classList.remove('is-visible');
  };

  const isAtBottom = () =>
    container.scrollHeight - container.scrollTop - container.clientHeight <= BOTTOM_THRESHOLD;

  const chatMessages = () => list.querySelectorAll('.chat-message[data-message-id]');

  const maxMessageId = () => {
    let max = 0;
    chatMessages().forEach((el) => {
      const id = parseInt(el.dataset.messageId, 10);
      if (Number.isFinite(id) && id > max) max = id;
    });
    return max;
  };

  const positionButton = () => {
    const composer = anchor.querySelector('.message-composer');
    const composerHeight = composer ? composer.offsetHeight : 64;
    button.style.bottom = `${composerHeight + BUTTON_GAP}px`;
  };

  const removeUnreadDivider = () => {
    const divider = list.querySelector('.unread-divider');
    if (divider) divider.remove();
  };

  const insertUnreadDivider = (beforeEl) => {
    if (!beforeEl || list.querySelector('.unread-divider')) return;
    const divider = document.createElement('div');
    divider.className = 'unread-divider';
    divider.setAttribute('role', 'separator');
    divider.setAttribute('aria-label', 'New messages');
    divider.innerHTML = '<span class="unread-divider__label">New messages</span>';
    beforeEl.parentNode.insertBefore(divider, beforeEl);
  };

  const updateCount = () => {
    if (unreadCount > 0) {
      countEl.textContent = unreadCount > 99 ? '99+' : String(unreadCount);
      countEl.classList.add('is-visible');
      button.setAttribute(
        'aria-label',
        `Jump to latest, ${unreadCount} new ${unreadCount === 1 ? 'message' : 'messages'}`,
      );
    } else {
      countEl.textContent = '';
      countEl.classList.remove('is-visible');
      button.setAttribute('aria-label', 'Jump to latest messages');
    }
  };

  const updateButton = () => {
    updateCount();
    if (isAtBottom()) {
      hideButton();
    } else {
      showButton();
    }
  };

  const scrollToBottom = (smooth = true) => {
    container.scrollTo({
      top: container.scrollHeight,
      behavior: smooth && !prefersReducedMotion() ? 'smooth' : 'auto',
    });
  };

  // Scroll the container so `target` sits near the top of the viewport. Uses
  // rects rather than offsetTop so it is correct regardless of offset parent.
  const scrollToElement = (target, smooth = false) => {
    const targetRect = target.getBoundingClientRect();
    const containerRect = container.getBoundingClientRect();
    const top = container.scrollTop + (targetRect.top - containerRect.top) - 12;
    container.scrollTo({
      top: Math.max(0, top),
      behavior: smooth && !prefersReducedMotion() ? 'smooth' : 'auto',
    });
  };

  // Called only when the view is at (or scrolling to) the newest message, so the
  // button is hidden directly rather than recomputed mid-scroll (avoids a flash).
  const markAllRead = () => {
    const top = maxMessageId();
    if (top > 0) writeLastReadId(userId, conversationId, top);
    unreadCount = 0;
    removeUnreadDivider();
    updateCount();
    hideButton();
  };

  const positionOnLoad = ({ smooth = false } = {}) => {
    if (hasPositioned) return;
    hasPositioned = true;

    // Defer to the next frame so the thread is laid out before we measure/scroll
    // (init can run at readyState "interactive", before styles settle).
    requestAnimationFrame(() => {
      const lastReadId = readLastReadId(userId, conversationId);

      // No prior read position in this browser: don't dump the user at the top of a
      // long history. Treat the thread as caught up and land on the newest message.
      if (lastReadId === null) {
        scrollToBottom(false);
        markAllRead();
        return;
      }

      let firstUnread = null;
      unreadCount = 0;
      chatMessages().forEach((el) => {
        const id = parseInt(el.dataset.messageId, 10);
        const fromOther = String(el.dataset.senderId) !== userId;
        if (fromOther && Number.isFinite(id) && id > lastReadId) {
          if (!firstUnread) firstUnread = el;
          unreadCount += 1;
        }
      });

      if (firstUnread && unreadCount > 0) {
        insertUnreadDivider(firstUnread);
        const target = list.querySelector('.unread-divider') || firstUnread;
        scrollToElement(target, smooth);
        updateButton();
        if (isAtBottom()) markAllRead();
      } else {
        scrollToBottom(smooth);
        markAllRead();
      }
    });
  };

  // Called by the channel after a live message has been appended to the DOM.
  // `wasAtBottom` is the scroll state captured *before* the DOM was mutated.
  const handleIncomingMessage = (messageEl, { fromCurrentUser, wasAtBottom } = {}) => {
    const atBottom = wasAtBottom === undefined ? isAtBottom() : wasAtBottom;
    if (fromCurrentUser || atBottom) {
      scrollToBottom(true);
      markAllRead();
      return;
    }

    // User is reading history further up — keep their place and tally the new one.
    if (messageEl && messageEl.classList.contains('chat-message')) {
      unreadCount += 1;
    }
    updateButton();
  };

  let scrollRaf = null;
  const onScroll = () => {
    if (scrollRaf) return;
    scrollRaf = requestAnimationFrame(() => {
      scrollRaf = null;
      if (isAtBottom()) {
        markAllRead();
      } else {
        updateButton();
      }
    });
  };
  container.addEventListener('scroll', onScroll, { passive: true });

  const onClick = () => {
    scrollToBottom(true);
    window.setTimeout(markAllRead, 400);
  };
  button.addEventListener('click', onClick);

  const controller = {
    positionOnLoad,
    handleIncomingMessage,
    markAllRead,
    isAtBottom,
    teardown() {
      container.removeEventListener('scroll', onScroll);
      button.removeEventListener('click', onClick);
      button.remove();
      removeUnreadDivider();
      delete container.dataset.jumpToLatestBound;
      delete container.__jumpToLatestController;
    },
  };

  container.__jumpToLatestController = controller;
  return controller;
};
