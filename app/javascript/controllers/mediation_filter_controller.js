import { Controller } from "@hotwired/stimulus"

// Drives the tenant/landlord messages board.
//
// All of a user's mediations are rendered into the DOM once. By default they
// are shown grouped (Active / Pending / Past) and paginated 10 at a time. The
// moment a status chip other than "All" is chosen, text is typed into search,
// or a date bound is set, the board collapses into a single flat list of the
// matching mediations (still paginated). Filtering always runs across the full
// set, not just the current page, and pagination then windows the results.
export default class extends Controller {
  static targets = [
    "card", "groups", "empty", "header",
    "search", "chip", "dateFrom", "dateTo", "clear",
    "pagination", "prev", "next", "pages"
  ]

  static values = { perPage: { type: Number, default: 10 } }

  connect() {
    this.status = "all"
    this.query = ""
    this.dateFrom = null
    this.dateTo = null
    this.page = 1
    this.apply()
  }

  filterByStatus(event) {
    this.status = event.currentTarget.dataset.status || "all"
    this.#highlightChip(event.currentTarget)
    this.page = 1
    this.apply()
  }

  filterBySearch(event) {
    this.query = event.target.value.trim().toLowerCase()
    this.page = 1
    this.apply()
  }

  filterByDate() {
    this.dateFrom = this.hasDateFromTarget && this.dateFromTarget.value ? this.dateFromTarget.value : null
    this.dateTo = this.hasDateToTarget && this.dateToTarget.value ? this.dateToTarget.value : null
    this.page = 1
    this.apply()
  }

  clearFilters() {
    this.status = "all"
    this.query = ""
    this.dateFrom = null
    this.dateTo = null
    this.page = 1
    if (this.hasSearchTarget) this.searchTarget.value = ""
    if (this.hasDateFromTarget) this.dateFromTarget.value = ""
    if (this.hasDateToTarget) this.dateToTarget.value = ""
    this.chipTargets.forEach((chip) => chip.classList.toggle("is-active", chip.dataset.status === "all"))
    this.apply()
  }

  prevPage() {
    if (this.page > 1) {
      this.page -= 1
      this.apply()
      this.#scrollToTop()
    }
  }

  nextPage() {
    this.page += 1 // clamped to the last page inside apply()
    this.apply()
    this.#scrollToTop()
  }

  goToPage(event) {
    const target = Number(event.currentTarget.dataset.page)
    if (!Number.isNaN(target)) {
      this.page = target
      this.apply()
      this.#scrollToTop()
    }
  }

  // A filter is active whenever the view should switch from grouped to flat.
  get isFiltering() {
    return this.status !== "all" || this.query !== "" || this.dateFrom !== null || this.dateTo !== null
  }

  apply() {
    const filtering = this.isFiltering
    this.element.classList.toggle("is-filtered", filtering)
    if (this.hasClearTarget) this.clearTarget.hidden = !filtering

    const matching = this.cardTargets.filter((card) => this.#matches(card))

    const perPage = this.perPageValue
    const totalPages = Math.max(1, Math.ceil(matching.length / perPage))
    this.page = Math.min(Math.max(this.page, 1), totalPages)

    const start = (this.page - 1) * perPage
    const pageCards = new Set(matching.slice(start, start + perPage))

    this.cardTargets.forEach((card) => { card.hidden = !pageCards.has(card) })

    // Group headers only appear in the grouped (default) view, and only for a
    // group that has a card visible on the current page.
    const visibleGroups = new Set([...pageCards].map((card) => card.dataset.group))
    this.headerTargets.forEach((header) => {
      header.hidden = filtering || !visibleGroups.has(header.dataset.group)
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = matching.length !== 0
    if (this.hasGroupsTarget) this.groupsTarget.hidden = matching.length === 0

    this.#renderPagination(matching.length, totalPages, perPage)
  }

  #matches(card) {
    const matchesStatus = this.status === "all" || card.dataset.status === this.status
    const matchesQuery = this.query === "" || (card.dataset.search || "").includes(this.query)
    const date = card.dataset.date || ""
    const matchesFrom = !this.dateFrom || (date !== "" && date >= this.dateFrom)
    const matchesTo = !this.dateTo || (date !== "" && date <= this.dateTo)
    return matchesStatus && matchesQuery && matchesFrom && matchesTo
  }

  #renderPagination(total, totalPages, perPage) {
    if (!this.hasPaginationTarget) return

    this.paginationTarget.hidden = total <= perPage
    if (this.hasPrevTarget) this.prevTarget.disabled = this.page <= 1
    if (this.hasNextTarget) this.nextTarget.disabled = this.page >= totalPages

    if (this.hasPagesTarget) {
      this.pagesTarget.replaceChildren(...this.#pageWindow(this.page, totalPages).map((item) => this.#pageElement(item)))
    }
  }

  // Build a compact, never-overflowing list of page tokens: always the first
  // and last page, the current page and its immediate neighbours, and "…" to
  // bridge any gaps. e.g. page 5 of 50 -> [1, "…", 4, 5, 6, "…", 50].
  #pageWindow(current, total) {
    const window = []
    const left = Math.max(2, current - 1)
    const right = Math.min(total - 1, current + 1)

    window.push(1)
    if (left > 2) window.push("ellipsis")
    for (let page = left; page <= right; page += 1) window.push(page)
    if (right < total - 1) window.push("ellipsis")
    if (total > 1) window.push(total)

    return window
  }

  #pageElement(item) {
    if (item === "ellipsis") {
      const span = document.createElement("span")
      span.className = "pagination-ellipsis"
      span.textContent = "…"
      span.setAttribute("aria-hidden", "true")
      return span
    }

    const button = document.createElement("button")
    button.type = "button"
    button.className = "pagination-page"
    button.textContent = String(item)
    button.dataset.page = String(item)
    button.dataset.action = "mediation-filter#goToPage"
    button.setAttribute("aria-label", `Go to page ${item}`)
    if (item === this.page) {
      button.classList.add("is-active")
      button.setAttribute("aria-current", "page")
    }
    return button
  }

  #highlightChip(active) {
    this.chipTargets.forEach((chip) => chip.classList.toggle("is-active", chip === active))
  }

  // After a page change, bring the top of the board back into view so the new
  // results start at the top instead of leaving the user at the pagination row.
  #scrollToTop() {
    this.element.scrollIntoView({ behavior: "smooth", block: "start" })
  }
}
