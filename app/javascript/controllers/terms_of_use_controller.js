import { Controller } from "@hotwired/stimulus"

const storageKey = "evictionMediationTermsAccepted"

export default class extends Controller {
  static targets = ["instructions", "content", "actions", "agree", "error", "back"]
  static values = { redirectUrl: String, returnUrl: String }

  connect() {
    let accepted
    try {
      accepted = localStorage.getItem(storageKey) === "true"
    } catch {
      accepted = false
    }

    if (this.hasRedirectUrlValue) {
      if (!accepted) window.location.replace(this.redirectUrlValue)
      return
    }

    this.backTarget.hidden = !accepted
    this.instructionsTarget.hidden = accepted
    this.actionsTarget.hidden = accepted
    this.reachedEnd = false
    this.updateAcceptance()
  }

  updateAcceptance() {
    if (this.actionsTarget.hidden) return

    const { scrollTop, clientHeight, scrollHeight } = this.contentTarget
    const maxScroll = scrollHeight - clientHeight
    const scrollable = maxScroll > 1

    if (scrollable && scrollTop >= maxScroll - 1) this.reachedEnd = true
    this.agreeTarget.disabled = scrollable && !this.reachedEnd
  }

  accept() {
    if (this.actionsTarget.hidden || this.agreeTarget.disabled) return

    try {
      localStorage.setItem(storageKey, "true")
    } catch {
      this.errorTarget.hidden = false
      this.errorTarget.scrollIntoView({ block: "nearest" })
      return
    }
    window.location.replace(this.returnUrlValue)
  }
}
