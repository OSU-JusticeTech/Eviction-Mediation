import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["trigger", "dialog", "consent", "error"]

  open() {
    this.dialogTarget.showModal()
    this.opened = true
    this.errorTarget.hidden = true
  }

  agree() {
    this.consentTarget.checked = true
    this.close()
  }

  close() {
    this.dialogTarget.close()
  }

  restoreFocus() {
    if (!this.dialogTarget.open) this.triggerTarget.focus()
  }

  validate(event) {
    if (this.opened) return

    event.preventDefault()
    this.errorTarget.hidden = false
    this.triggerTarget.focus()
  }
}
