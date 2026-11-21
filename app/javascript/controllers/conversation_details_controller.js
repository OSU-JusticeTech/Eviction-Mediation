import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    this.opener = event.currentTarget
    this.dialogTarget.showModal()
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  dismissBackdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  restoreFocus() {
    if (!this.dialogTarget.open) this.opener?.focus()
  }
}
