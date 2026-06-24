import consumer from "channels/consumer";

const escapeHtml = (value) => {
  if (value === null || value === undefined) return "";
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
};

const escapeAttribute = (value) => {
  if (value === null || value === undefined) return "";
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
};

const titleize = (value) => {
  if (!value) return "";
  return value
    .toString()
    .replace(/_/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map((token) => token.charAt(0).toUpperCase() + token.slice(1).toLowerCase())
    .join(" ");
};

const formatMessageContents = (contents) => {
  if (!contents) return "";
  const sanitized = escapeHtml(contents);
  return sanitized.replace(/(\r\n|\n|\r)/g, "<br>");
};

const formatDateLabel = (timestamp) => {
  const date = new Date(timestamp * 1000);
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  if (date.toDateString() === today.toDateString()) return 'Today';
  if (date.toDateString() === yesterday.toDateString()) return 'Yesterday';
  return date.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' });
};

const isSameDay = (ts1, ts2) => {
  return new Date(ts1 * 1000).toDateString() === new Date(ts2 * 1000).toDateString();
};

const placeholderForRole = (role) => {
  switch (role) {
    case "Tenant":
      return "Message your landlord and mediator...";
    case "Landlord":
      return "Message your tenant and mediator...";
    case "Mediator":
      return "Message everyone in this mediation...";
    default:
      return "Type your message...";
  }
};

const buildAttachmentHtml = (attachment, currentUserRole) => {
  if (!attachment) return "";

  const fileId = escapeAttribute(attachment.file_id);
  const fileName = escapeHtml(attachment.file_name || "Untitled document");
  const previewUrl = escapeAttribute((attachment.preview_url || attachment.view_url || attachment.download_url || "#") + (attachment.preview_url || attachment.view_url ? "?view_mode=simple" : ""));
  const downloadUrl = escapeAttribute(attachment.download_url || attachment.view_url || "#");
  const extension = escapeAttribute(attachment.extension || "");
  const signUrl = escapeAttribute(attachment.sign_url || "");
  const needsTenantSignature = Boolean(attachment.tenant_signature_required);
  const needsLandlordSignature = Boolean(attachment.landlord_signature_required);

  const showTenantCTA = currentUserRole === "Tenant" && needsTenantSignature && signUrl;
  const showLandlordCTA = currentUserRole === "Landlord" && needsLandlordSignature && signUrl;

  const actions = [
    `<a href="${previewUrl}" class="attachment-link">View</a>`,
    `<span aria-hidden="true" class="attachment-dot">·</span>`,
    `<a href="${downloadUrl}" class="attachment-link">Download</a>`
  ];

  if (showTenantCTA || showLandlordCTA) {
    actions.push(`<span aria-hidden="true" class="attachment-dot">·</span>`);
    actions.push(`<a href="${signUrl}" class="attachment-link attachment-link--primary">Sign as ${showTenantCTA ? "Tenant" : "Landlord"}</a>`);
  }

  return `
    <div class="message-attachment" data-attachment-id="${fileId}" data-attachment-type="${extension}">
      <div class="attachment-icon" aria-hidden="true">
        <i class="fa-solid fa-file-lines"></i>
      </div>
      <div class="attachment-body">
        <div class="attachment-name">${fileName}</div>
        <div class="attachment-actions">${actions.join(" ")}</div>
      </div>
    </div>
  `;
};

// Track if we've already scrolled on initial load for this conversation
let hasScrolledOnLoad = new Set();
let activeSubscription = null;
let activeConversationId = null;

const initializeMessagesChannel = () => {
  const messagesContainer = document.querySelector('.message-list-container');
  const messagesList = document.getElementById('messages');
  const composer = document.getElementById('new_message_form');

  if (!messagesContainer || !messagesList) return;

  const conversationId = messagesList.dataset.conversationId;
  const currentUserId = messagesList.dataset.currentUserId;
  const currentUserRole = messagesList.dataset.currentUserRole;
  let broadcastEnabled = messagesList.dataset.broadcastEnabled === 'true';

  if (!conversationId) {
    console.error("No conversation ID found in message list!");
    return;
  }

  console.log(`Checking for existing subscriptions before subscribing to conversation ID: ${conversationId}`);
  console.log("Active subscriptions before cleanup:", consumer.subscriptions.subscriptions);

  if (activeSubscription) {
    consumer.subscriptions.remove(activeSubscription);
    activeSubscription = null;
    activeConversationId = null;
  }

  consumer.subscriptions.subscriptions
    .filter((subscription) => subscription.identifier.includes(`"conversation_id":"${conversationId}"`))
    .forEach((subscription) => {
      console.log("Removing existing subscription before reinitializing:", subscription);
      consumer.subscriptions.remove(subscription);
    });

  const subscription = consumer.subscriptions.create({ channel: "MessagesChannel", conversation_id: conversationId }, {
    initialized() {
      console.log(`Initializing subscription for conversation ID: ${conversationId}`);
    },
    connected() {
      console.log(`Connected to conversation ID: ${conversationId}`);
    },
    received(data) {
      if (data.type === 'mediator_assigned') {
        broadcastEnabled = true;
        if (messagesList) {
          messagesList.dataset.broadcastEnabled = 'true';
        }

        const textarea = document.getElementById('message_contents');
        if (textarea) {
          textarea.placeholder = placeholderForRole(currentUserRole);
        }

        if (composer) {
          composer.dataset.composerEnabled = 'true';
          const submitButton = composer.querySelector('button[type="submit"]');
          if (submitButton) submitButton.disabled = false;
        }

        // Update the status pill in the toolbar
        const statusContainer = document.getElementById('mediation-status-container');
        if (statusContainer) {
           const mediatorName = (data.mediator_name || "").trim();
           const label = mediatorName ? `Mediator: ${mediatorName}` : "Mediator assigned";
           statusContainer.innerHTML = `
            <span class="conversation-status-pill conversation-status-pill--success" title="A mediator has been assigned to this case.">
              <i class="fa-solid fa-handshake" aria-hidden="true"></i>
              <span>${label}</span>
            </span>
           `;
        }

        // The "Request a mediator" toolbar button is only rendered while a request
        // can still be made, so once a mediator is assigned there's nothing to relabel.

        console.log('Mediator assigned, conversation now in broadcast mode.');
        return;
      }

      const senderId = data.sender_id != null ? data.sender_id.toString() : null;
      const recipientId = data.recipient_id != null ? data.recipient_id.toString() : null;
      const isBroadcast = data.broadcast === true || data.broadcast === 'true' || recipientId === null;

      const isSender = senderId === currentUserId;
      const isRecipient = !isBroadcast && recipientId === currentUserId;

      if (isBroadcast && !broadcastEnabled) {
        broadcastEnabled = true;
        if (messagesList) {
          messagesList.dataset.broadcastEnabled = 'true';
        }
        if (composer) {
          composer.dataset.composerEnabled = 'true';
        }
        const textarea = document.getElementById('message_contents');
        if (textarea) {
          textarea.placeholder = placeholderForRole(currentUserRole);
        }
      }

      if (!(isSender || isRecipient || isBroadcast)) return;

      // Remove "no messages" placeholder if it exists
      const noMessagesPlaceholder = messagesList.querySelector('.no-messages');
      if (noMessagesPlaceholder) {
        noMessagesPlaceholder.remove();
      }

      const messageContents = formatMessageContents(data.contents);
      const attachments = Array.isArray(data.attachments) ? data.attachments : [];
      const attachmentsHtml = attachments
        .map((attachment) => buildAttachmentHtml(attachment, currentUserRole))
        .filter(Boolean)
        .join('');

      const currTimestamp = data.message_timestamp || Math.floor(Date.now() / 1000);

      // Insert date separator if the day has changed
      const allChatMessages = messagesList.querySelectorAll('.chat-message, .system-message');
      const prevAnyMessage = allChatMessages.length > 0 ? allChatMessages[allChatMessages.length - 1] : null;
      if (prevAnyMessage) {
        const prevTimestamp = parseInt(prevAnyMessage.dataset.messageTimestamp || '0', 10);
        if (prevTimestamp && !isSameDay(prevTimestamp, currTimestamp)) {
          const label = escapeHtml(formatDateLabel(currTimestamp));
          messagesList.insertAdjacentHTML('beforeend', `<div class="date-separator" aria-label="${label}"><span class="date-separator__label">${label}</span></div>`);
        }
      }

      let messageHtml;

      if (data.is_system) {
        const attachmentsBlock = attachmentsHtml ? `<div class="system-message__attachments">${attachmentsHtml}</div>` : '';
        messageHtml = `
          <div class="system-message" data-message-id="${escapeAttribute(data.message_id)}" data-message-timestamp="${escapeAttribute(data.message_timestamp || '')}">
            <span class="system-message__text">${messageContents}</span>
            ${attachmentsBlock}
          </div>
        `;
      } else {
        const messageClass = isSender ? 'sent' : 'received';
        const formattedRole = titleize(data.sender_role);
        const senderName = isSender ? 'You' : escapeHtml(data.sender_name || formattedRole || 'Participant');
        const broadcastAttr = isBroadcast ? 'true' : 'false';
        const recipientAttr = recipientId || '';

        // Determine grouping with the previous chat message.
        // A system message between two chat messages always breaks the group.
        const prevIsSystemMessage = prevAnyMessage && prevAnyMessage.classList.contains('system-message');
        const prevChatMessages = messagesList.querySelectorAll('.chat-message');
        const prevChatMessage = prevChatMessages.length > 0 ? prevChatMessages[prevChatMessages.length - 1] : null;
        let isGrouped = false;

        if (!prevIsSystemMessage && prevChatMessage) {
          const prevTimestamp = parseInt(prevChatMessage.dataset.messageTimestamp || '0', 10);
          const prevSenderId = prevChatMessage.dataset.senderId;
          if (prevTimestamp && isSameDay(prevTimestamp, currTimestamp) &&
              String(prevSenderId) === String(data.sender_id) && (currTimestamp - prevTimestamp) <= 300) {
            isGrouped = true;
            prevChatMessage.dataset.lastInGroup = 'false';
          }
        }

        messageHtml = `
          <div class="chat-message ${messageClass}" data-message-id="${escapeAttribute(data.message_id)}" data-sender-role="${escapeAttribute(formattedRole)}" data-sender-id="${escapeAttribute(data.sender_id)}" data-recipient-id="${escapeAttribute(recipientAttr)}" data-current-user-id="${escapeAttribute(currentUserId)}" data-broadcast="${broadcastAttr}" data-grouped="${isGrouped}" data-last-in-group="true" data-message-timestamp="${escapeAttribute(data.message_timestamp || '')}">
            <div class="message-bubble">
              <div class="message-meta">
                <span class="message-author">${senderName}</span>
                ${formattedRole ? `<span class="message-role">${escapeHtml(formattedRole)}</span>` : ''}
              </div>
              ${messageContents ? `<p class="message-content">${messageContents}</p>` : ''}
              ${attachmentsHtml ? `<div class="message-attachments">${attachmentsHtml}</div>` : ''}
              <small class="message-timestamp">${escapeHtml(data.message_date)}</small>
            </div>
          </div>
        `;
      }

      messagesList.insertAdjacentHTML('beforeend', messageHtml);

      const newMessageElement = messagesList.lastElementChild;
      if (newMessageElement) {
        newMessageElement.classList.add('is-entering');
        newMessageElement.addEventListener('animationend', () => {
          newMessageElement.classList.remove('is-entering');
        }, { once: true });
      }

      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }
  });

  activeSubscription = subscription;
  activeConversationId = conversationId;

  if (!hasScrolledOnLoad.has(conversationId)) {
    hasScrolledOnLoad.add(conversationId);
    messagesContainer.classList.add("use-smooth-scroll");
    requestAnimationFrame(() => {
      messagesContainer.scrollTo({
        top: messagesContainer.scrollHeight,
        behavior: "smooth"
      });
      setTimeout(() => {
        messagesContainer.classList.remove("use-smooth-scroll");
      }, 450);
    });
  } else {
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
  }
};

if (document.readyState === 'interactive' || document.readyState === 'complete') {
  initializeMessagesChannel();
}

document.addEventListener('turbo:load', () => {
  initializeMessagesChannel();
});

document.addEventListener('turbo:frame-load', (event) => {
  const frame = event.target;
  if (frame instanceof HTMLElement && typeof frame.querySelector === 'function' && frame.querySelector('#messages')) {
    initializeMessagesChannel();
  }
});

// Clear the tracking when navigating away
document.addEventListener('turbo:before-visit', () => {
  hasScrolledOnLoad.clear();
  if (activeSubscription) {
    consumer.subscriptions.remove(activeSubscription);
    activeSubscription = null;
    activeConversationId = null;
  }
});

document.addEventListener('turbo:before-cache', () => {
  if (activeSubscription) {
    consumer.subscriptions.remove(activeSubscription);
    activeSubscription = null;
    activeConversationId = null;
  }
});
