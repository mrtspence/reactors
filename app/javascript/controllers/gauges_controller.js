import { Controller } from "@hotwired/stimulus"

// **Instruments, painted from the frame's view** wherever they are drawn — the strip, the console.
export default class extends Controller {
  connect() {
    // Indexed once, not per tick: at 4 Hz a querySelector per gauge per tick is pure waste. An
    // instrument in two places is drawn twice, so an id holds every element drawing it.
    this.instruments = new Map()
    this.element.querySelectorAll("[data-instrument-id]").forEach((el) => {
      const id = el.dataset.instrumentId
      this.instruments.set(id, [ ...(this.instruments.get(id) || []), el ])
    })

    this.onView = (event) => this.paint(event.detail.state)
    window.addEventListener("reactor:view", this.onView)

    // **Turbo keeps a page as it looked when you left it**, and paints that snapshot on the way
    // back: readings minutes old and indistinguishable from live ones. Misreading an instrument is
    // the game, so a stale number shown as current is the one thing never to do — blank them on
    // the way out. The frame's own stay live across the visit, so they are left alone.
    this.blankOnCache = () => this.blank()
    if (!this.element.closest("[data-turbo-permanent]")) {
      document.addEventListener("turbo:before-cache", this.blankOnCache)
    }

    window.dispatchEvent(new CustomEvent("reactor:request"))
  }

  disconnect() {
    window.removeEventListener("reactor:view", this.onView)
    document.removeEventListener("turbo:before-cache", this.blankOnCache)
  }

  paint(state) {
    for (const [id, els] of this.instruments) {
      for (const el of els) this.paintInstrument(el, state.gauges[id], state.flags[id] || [])
    }
  }

  // Every gauge back to "—". A reading nobody can vouch for has to look like one.
  blank() {
    for (const els of this.instruments.values()) {
      for (const el of els) this.paintInstrument(el, undefined, [])
    }
  }

  paintInstrument(el, value, flags) {
    const offline = flags.includes("offline") || value === null || value === undefined
    const readout = el.querySelector("[data-instrument-value]")
    if (readout) readout.textContent = offline ? "—" : value

    // :warming_up is not a fault: every lagged gauge raises it for its first few ticks.
    el.dataset.settling = flags.includes("warming_up") ? "true" : ""
    el.classList.toggle("opacity-40", offline)

    const needle = el.querySelector("[data-instrument-needle]")
    if (needle) {
      const min = parseFloat(el.dataset.instrumentMin)
      const max = parseFloat(el.dataset.instrumentMax)
      const fraction = offline || max === min ? 0 : (value - min) / (max - min)
      needle.style.setProperty("--fraction", Math.min(1, Math.max(0, fraction)))
      const pegged = flags.includes("pegged_high") || flags.includes("pegged_low")
      if (pegged) needle.dataset.pegged = "true"
      else delete needle.dataset.pegged
    }

    const lamp = el.querySelector("[data-instrument-lamp]")
    if (lamp) lamp.className = value
      ? `h-4 w-4 rounded-full ring-1 ring-slate-600 transition ${el.dataset.instrumentColour}`
      : "h-4 w-4 rounded-full bg-slate-700 ring-1 ring-slate-600 transition"
  }
}
