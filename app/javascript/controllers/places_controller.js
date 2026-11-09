import { Controller } from "@hotwired/stimulus"

// **The places box**: which place's panel is shown, how many are in each, and the first of each
// place's boards saying something that is not calm, in its own words. The choice is kept per
// machine in this browser, so a visit to outfitting comes back to it.
export default class extends Controller {
  static values = { operation: String }

  connect() {
    this.lines = [ ...this.element.querySelectorAll("[data-places-line]") ].map((el) => ({
      el, id: el.dataset.placesLine, boards: JSON.parse(el.dataset.placesBoards || "[]")
    }))
    this.show(this.remembered() || this.lines[0]?.id)

    this.onView = (event) => this.paint(event.detail.state)
    window.addEventListener("reactor:view", this.onView)
    // A count or a board kept from when the page was left is a stale reading shown as current.
    this.blankOnCache = () => this.blank()
    document.addEventListener("turbo:before-cache", this.blankOnCache)
    window.dispatchEvent(new CustomEvent("reactor:request"))
  }

  disconnect() {
    window.removeEventListener("reactor:view", this.onView)
    document.removeEventListener("turbo:before-cache", this.blankOnCache)
  }

  select({ params: { id } }) {
    this.show(id)
    try { localStorage.setItem(this.key(), id) } catch { /* storage may be unavailable */ }
  }

  show(id) {
    if (!this.lines.some((line) => line.id === id)) return
    for (const line of this.lines) line.el.setAttribute("aria-current", line.id === id ? "true" : "false")
    for (const panel of document.querySelectorAll("[data-place-panel]")) {
      panel.classList.toggle("hidden", panel.dataset.placePanel !== id)
    }
  }

  remembered() {
    try {
      const id = localStorage.getItem(this.key())
      return this.lines.some((line) => line.id === id) ? id : null
    } catch {
      return null
    }
  }

  key() {
    return `reactor:place:${this.operationValue}`
  }

  paint(state) {
    const here = new Map()
    for (const member of Object.values(state.crew || {})) {
      if (member.place) here.set(member.place, (here.get(member.place) || 0) + 1)
    }

    for (const line of this.lines) {
      const count = line.el.querySelector("[data-places-count]")
      if (count) count.textContent = here.get(line.id) || ""

      const words = line.el.querySelector("[data-places-words]")
      if (words) words.textContent = this.pressing(line.boards, state) || ""
    }
  }

  // An offline board says nothing, which is not the same as saying all is well.
  pressing(boards, { gauges, flags }) {
    for (const board of boards) {
      const said = gauges[board.id]
      const offline = (flags[board.id] || []).includes("offline") || said === null || said === undefined
      if (!offline && !board.calm.includes(said)) return said
    }
    return null
  }

  blank() {
    for (const line of this.lines) {
      line.el.querySelectorAll("[data-places-count], [data-places-words]").forEach((el) => { el.textContent = "" })
    }
  }
}
