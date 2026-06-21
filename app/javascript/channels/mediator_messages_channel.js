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
  // Escape only; whitespace and line breaks are preserved by CSS white-space: pre-wrap
  // on .message-content, so this matches the server-rendered output exactly.
  return escapeHtml(contents);
};

const buildAttachmentHtml = (attachment) => {
  if (!attachment) return "";

  const fileId = escapeAttribute(attachment.file_id);
  const fileName = escapeHtml(attachment.file_name || "Document");
  const previewUrl = escapeAttribute((attachment.preview_url || attachment.view_url || attachment.download_url || "#") + (attachment.preview_url || attachment.view_url ? "?view_mode=simple" : ""));
  const downloadUrl = escapeAttribute(attachment.download_url || attachment.view_url || "#");
  const extension = escapeAttribute(attachment.extension || "");

  return `
    <div class="message-attachment" data-attachment-id="${fileId}" data-attachment-type="${extension}">
      <div class="attachment-icon" aria-hidden="true">
        <i class="fa-solid fa-file-lines"></i>
      </div>
      <div class="attachment-body">
        <div class="attachment-name">${fileName}</div>
        <div class="attachment-actions">
          <a href="${previewUrl}" class="attachment-link">View</a>
          <span aria-hidden="true" class="attachment-dot">·</span>
          <a href="${downloadUrl}" class="attachment-link">Download</a>
        </div>
      </div>
    </div>
  `;
};

// Track if we've already scrolled on initial load for this conversation
let hasScrolledOnLoad = new Set();

document.addEventListener("turbo:load", () => {
  document.querySelectorAll(".mediator-chat-box").forEach((box) => {
    const conversationId = box.dataset.conversationId;
    const currentUserId = box.dataset.userId;
    const messagesList = box.querySelector(".message-list");
    const messagesContainer = box.querySelector(".message-list-container");

    if (!conversationId || !currentUserId || !messagesList || !messagesContainer) return;

    // Cleanup old subscriptions
    consumer.subscriptions.subscriptions.forEach((subscription) => {
      if (subscription.identifier.includes(`"conversation_id":"${conversationId}"`)) {
        consumer.subscriptions.remove(subscription);
      }
    });

    // Check if subscription already exists
    const existing = consumer.subscriptions.subscriptions.find((subscription) =>
      subscription.identifier.includes(`"conversation_id":"${conversationId}"`)
    );

    if (!existing) {
      consumer.subscriptions.create(
        { channel: "MediatorMessagesChannel", conversation_id: conversationId },
        {
          connected() {
            console.log(`MediatorMessagesChannel: Connected to ${conversationId}`);
          },

          disconnected() {
            console.log(`MediatorMessagesChannel: Disconnected from ${conversationId}`);
          },

          received(data) {
            const isSender = data.sender_id.toString() === currentUserId;
            const isRecipient = data.recipient_id.toString() === currentUserId;

            if (!isSender && !isRecipient) return;

            const messageClass = isSender ? "sent" : "received";
            const formattedRole = titleize(data.sender_role);
            const senderName = escapeHtml(data.sender_name || (isSender ? "You" : formattedRole || "Participant"));
            const messageContents = formatMessageContents(data.contents);
            const attachments = Array.isArray(data.attachments) ? data.attachments : [];

            const attachmentsHtml = attachments
              .map((attachment) => buildAttachmentHtml(attachment))
              .filter(Boolean)
              .join("");

            const contentHtml = messageContents ? `<p class="message-content">${messageContents}</p>` : "";
            const attachmentsBlock = attachmentsHtml ? `<div class="message-attachments">${attachmentsHtml}</div>` : "";

            const messageHtml = `
              <div class="chat-message ${messageClass}" data-message-id="${escapeAttribute(data.message_id)}" data-sender-role="${escapeHtml(formattedRole)}" data-sender-id="${escapeAttribute(data.sender_id)}" data-current-user-id="${escapeAttribute(currentUserId)}">
                <div class="message-bubble">
                  <div class="message-meta">
                    <span class="message-author">${senderName}</span>
                    ${formattedRole ? `<span class="message-role">${escapeHtml(formattedRole)}</span>` : ""}
                  </div>
                  ${contentHtml}
                  ${attachmentsBlock}
                  <small class="message-timestamp">${escapeHtml(data.message_date)}</small>
                </div>
              </div>
            `;

            messagesList.insertAdjacentHTML("beforeend", messageHtml);
            console.log("message sent, Scrolling to bottom of:", messagesList);
            // Instantly scroll to bottom
            messagesContainer.scrollTop = messagesContainer.scrollHeight;

            // Apply entering animation to the new message
            const newMessageElement = messagesList.lastElementChild;
            if (newMessageElement) {
              newMessageElement.classList.add("is-entering");
              newMessageElement.addEventListener("animationend", () => {
                newMessageElement.classList.remove("is-entering");
              }, { once: true });
            }
          }
        }
      );
    }

    // Scroll to bottom ONLY on first true page load
    console.log("page load, Scrolling to bottom of:", messagesList);
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
      // On subsequent turbo:load events, just jump to bottom instantly
      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }
  });
});

// Clear the tracking when navigating away
document.addEventListener('turbo:before-visit', () => {
  hasScrolledOnLoad.clear();
});
