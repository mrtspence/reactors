import { Controller } from "@hotwired/stimulus"
import { postings } from "console/postings"

// **The levers**: moved at once and marked pending, sent through the frame, and confirmed or
// corrected by the next view.
export default class extends Controller {
  // Send on change, at most ~10/s. Coalescing by lever is the key property, and it works only
  // because commands are ABSOLUTE: a drag fires hundreds of input events and only the last counts.
  static THROTTLE_MS = 100

  // A pending lever unconfirmed for this long is assumed lost, or the slider would lie forever —
  // and a drop is expected, because the producer does not wait on delivery.
  static PENDING_TIMEOUT_MS = 2000

  connect() {
    this.pending = new Map()
    this.queued = new Map()
    this.timer = null

    this.levers = new Map()
    this.element.querySelectorAll("[data-lever-id]").forEach((el) => {
      this.levers.set(el.dataset.leverId, el)
    })

    this.onView = (event) => this.paint(event.detail.state)
    window.addEventListener("reactor:view", this.onView)
    window.dispatchEvent(new CustomEvent("reactor:request"))
  }

  disconnect() {
    window.removeEventListener("reactor:view", this.onView)
    if (this.timer) clearTimeout(this.timer)
  }

  paint(state) {
    for (const [id, el] of this.levers) this.paintLever(el, id, state.controls[id])
    this.paintGangs(state.crew)
  }

  paintLever(el, id, control) {
    if (!control) return
    const input = el.querySelector("[data-lever-input]")
    const readout = el.querySelector("[data-lever-readout]")
    const ghost = el.querySelector("[data-lever-ghost]")
    const pending = this.pending.get(id)

    if (pending === undefined) {
      input.value = control.target
    } else if (pending.value === control.target) {
      this.pending.delete(id)
      delete input.dataset.pending
    } else if (Date.now() - pending.at > this.constructor.PENDING_TIMEOUT_MS) {
      // The server is authoritative, and it CLAMPS: a client that sent 150 gets 100 back.
      this.pending.delete(id)
      delete input.dataset.pending
      input.value = control.target
    }

    if (readout) readout.textContent = Math.round(control.target)

    // Where the lever actually is, as opposed to where it was asked to go.
    if (ghost) {
      const min = parseFloat(input.min)
      const max = parseFloat(input.max)
      const travelling = Math.abs(control.actual - control.target) > 0.01
      ghost.hidden = !travelling
      if (travelling) ghost.style.left = `${((control.actual - min) / (max - min)) * 100}%`
    }
  }

  // Who is working each post against how many it takes, shown for a gang's post or any post
  // somebody has been sent to.
  paintGangs(crew) {
    const { sent, working } = postings(crew)
    for (const [id, el] of this.levers) {
      const badge = el.querySelector("[data-lever-crew]")
      if (!badge) continue

      const capacity = parseInt(badge.dataset.capacity, 10)
      const ordered = sent.get(id) || 0
      const at = working.get(id) || 0
      const walking = ordered - at
      badge.textContent = walking > 0 ? `${at}/${capacity}, ${walking} walking` : `${at}/${capacity}`
      badge.classList.toggle("hidden", !(capacity > 1 || ordered > 0))
    }
  }

  lever(event) {
    const el = event.target
    const lever = el.closest("[data-lever-id]")
    const id = lever.dataset.leverId
    const value = Number(el.value)

    // Move immediately and mark it unconfirmed: the round trip is a whole tick away.
    el.dataset.pending = "true"
    this.pending.set(id, { value, at: Date.now() })
    const readout = lever.querySelector("[data-lever-readout]")
    if (readout) readout.textContent = Math.round(value)

    this.queued.set(id, value)
    this.scheduleFlush()
  }

  scheduleFlush() {
    if (this.timer) return
    this.timer = setTimeout(() => {
      this.timer = null
      for (const [id, value] of this.queued) {
        this.dispatch("command", { target: window, prefix: "reactor",
                                   detail: { command: { type: "set_control", control_point_id: id, value } } })
      }
      this.queued.clear()
    }, this.constructor.THROTTLE_MS)
  }
}
