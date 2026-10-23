import { Controller } from "@hotwired/stimulus"

// Keeps a mediator's time-tracking session alive while they're active.
// Mouse movement counts as activity; the last activity time lives in
// localStorage so it carries across Turbo page loads and open tabs. After
// idleMs without movement it asks "Are you still there?" and stops tracking
// if nobody confirms within confirmMs.
const HEARTBEAT_MS = 60000
const TICK_MS = 1000
const MOUSEMOVE_THROTTLE_MS = 1000
const KEY_PREFIX = "timeTracker:"

export default class extends Controller {
  static targets = ["modal", "countdown"]
  static values = {
    entryId: Number,
    heartbeatUrl: String,
    stopUrl: String,
    idleMs: Number,
    confirmMs: Number
  }

  connect() {
    this.activityKey = `${KEY_PREFIX}lastActivity:${this.entryIdValue}`
    this.stoppedKey = `${KEY_PREFIX}stopped:${this.entryIdValue}`
    this.heartbeatKey = `${KEY_PREFIX}lastHeartbeat:${this.entryIdValue}`
    this.memory = {}
    this.clearOtherSessions()
    if (!this.readNumber(this.activityKey)) this.recordActivity()

    this.promptStartedAt = null
    this.lastMouseWrite = 0

    this.onMouseMove = this.onMouseMove.bind(this)
    document.addEventListener("mousemove", this.onMouseMove, { passive: true })
    this.tickTimer = setInterval(() => this.tick(), TICK_MS)
  }

  disconnect() {
    document.removeEventListener("mousemove", this.onMouseMove)
    clearInterval(this.tickTimer)
  }

  onMouseMove() {
    // While the prompt is open, only the "I'm still here" button counts.
    if (this.promptStartedAt) return

    const now = Date.now()
    if (now - this.lastMouseWrite < MOUSEMOVE_THROTTLE_MS) return
    this.lastMouseWrite = now
    this.recordActivity(now)
  }

  tick() {
    if (this.readNumber(this.stoppedKey)) {
      this.teardown()
      return
    }

    const now = Date.now()
    const lastActivity = this.readNumber(this.activityKey) || now

    if (this.promptStartedAt) {
      // Another tab saw activity after this prompt opened.
      if (lastActivity > this.promptStartedAt) {
        this.closeModal()
        return
      }

      const remainingMs = this.confirmMsValue - (now - this.promptStartedAt)
      if (remainingMs <= 0) {
        this.stopTracking({ reason: "idle", message: "Time tracking stopped due to inactivity.", flashClass: "flash-alert" })
      } else if (this.hasCountdownTarget) {
        this.countdownTarget.textContent = Math.ceil(remainingMs / 1000)
      }
    } else if (now - lastActivity >= this.idleMsValue) {
      this.openModal()
    } else if (now - this.readNumber(this.heartbeatKey) >= HEARTBEAT_MS &&
               lastActivity > this.readNumber(this.heartbeatKey)) {
      this.heartbeat()
    }
  }

  confirm() {
    this.closeModal()
    this.recordActivity()
    this.heartbeat()
  }

  stop() {
    this.stopTracking({ message: "Time tracking stopped.", flashClass: "flash-notice" })
  }

  // The last heartbeat time is shared in localStorage so page navigation
  // doesn't reset the interval and open tabs don't double up.
  async heartbeat() {
    this.write(this.heartbeatKey, Date.now())

    const response = await this.request(this.heartbeatUrlValue)
    if (response && (response.status === 410 || response.status === 404)) {
      this.markStopped()
      this.teardown()
    }
  }

  async stopTracking({ reason, message, flashClass }) {
    this.markStopped()
    this.teardown()
    await this.request(this.stopUrlValue, reason ? { reason } : {})
    this.showFlash(message, flashClass)
  }

  openModal() {
    this.promptStartedAt = Date.now()
    if (this.hasCountdownTarget) this.countdownTarget.textContent = Math.ceil(this.confirmMsValue / 1000)
    this.modalTarget.hidden = false
    this.modalTarget.classList.add("is-open")
    document.body.classList.add("has-modal-open")
  }

  closeModal() {
    this.promptStartedAt = null
    this.modalTarget.classList.remove("is-open")
    this.modalTarget.hidden = true
    document.body.classList.remove("has-modal-open")
  }

  teardown() {
    this.disconnect()
    if (this.promptStartedAt) this.closeModal()
    document.querySelectorAll("[data-time-tracker-pill]").forEach((pill) => pill.remove())
    this.element.remove()
  }

  recordActivity(now = Date.now()) {
    this.write(this.activityKey, now)
  }

  markStopped() {
    this.write(this.stoppedKey, Date.now())
  }

  showFlash(message, flashClass) {
    const main = document.getElementById("main-content")
    if (!main) return

    const flash = document.createElement("div")
    flash.className = `flash-message ${flashClass}`
    flash.dataset.controller = "flash"
    flash.dataset.flashTimeoutValue = "4500"
    flash.textContent = message
    main.prepend(flash)
  }

  request(url, body = {}) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    return fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token
      },
      body: JSON.stringify(body),
      credentials: "same-origin",
      keepalive: true
    }).catch(() => null)
  }

  // Drop localStorage keys left behind by earlier sessions.
  clearOtherSessions() {
    try {
      Object.keys(localStorage)
        .filter((key) => key.startsWith(KEY_PREFIX) && !key.endsWith(`:${this.entryIdValue}`))
        .forEach((key) => localStorage.removeItem(key))
    } catch (_) {}
  }

  readNumber(key) {
    try {
      return Number(localStorage.getItem(key)) || 0
    } catch (_) {
      return this.memory[key] || 0
    }
  }

  write(key, value) {
    try {
      localStorage.setItem(key, String(value))
    } catch (_) {
      this.memory[key] = value
    }
  }
}
