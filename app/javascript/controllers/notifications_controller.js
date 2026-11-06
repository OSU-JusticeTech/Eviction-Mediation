import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { menuUrl: String, presenceUrl: String }

  connect() {
    const chat = document.getElementById("messages")
    if (chat && chat.dataset.currentUserRole !== "Admin") {
      this.conversationId = Number(chat.dataset.conversationId)
      this.presenceToken = crypto.randomUUID()
      this.observer = new IntersectionObserver(([entry]) => {
        this.chatVisible = entry.isIntersecting
        this.publishPresence()
      })
      this.observer.observe(chat.closest(".message-list-container"))
    }
    let ticks = 0
    this.timer = window.setInterval(() => {
      this.publishPresence()
      if (++ticks % 3 === 0) this.refresh()
    }, 10000)
  }

  disconnect() {
    window.clearInterval(this.timer)
    this.observer?.disconnect()
    this.clearPresence()
    this.presenceToken = null
  }

  resume() {
    this.publishPresence()
    this.refresh()
  }

  refresh() {
    // Keep an open menu stable while someone is reading or using its buttons.
    if (!document.hidden && !this.element.querySelector("details[open]") && !this.element.hasAttribute("busy")) {
      if (this.element.src) this.element.reload()
      else this.element.src = this.menuUrlValue
    }
  }

  closeOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  close(event) {
    const menu = this.element.querySelector("details")
    if (!menu?.open) return
    menu.open = false
    if (event?.key === "Escape") menu.querySelector("summary").focus()
  }

  publishPresence() {
    if (!this.presenceToken) return
    if (this.chatVisible && !document.hidden) {
      this.registered = true
      this.sendPresence("PATCH")
    } else {
      this.clearPresence()
    }
  }

  clearPresence() {
    if (!this.registered) return
    this.registered = false
    this.sendPresence("DELETE")
  }

  sendPresence(method) {
    const options = {
      method, credentials: "same-origin", keepalive: true,
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
      body: JSON.stringify({ token: this.presenceToken, conversation_id: this.conversationId })
    }
    // Keep a slow heartbeat from arriving after the request to leave the chat.
    this.pendingRequest = (this.pendingRequest || Promise.resolve())
      .then(() => fetch(this.presenceUrlValue, options))
      .catch(() => {}) // A lost connection automatically expires the presence.
  }
}
