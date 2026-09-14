import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// The operator's console: one subscription, one merged view, one set of pending levers.
//
// Deliberately a single controller rather than one per panel section. The optimistic-UI
// correction needs the lever state and the incoming projection in the same place; splitting
// them would mean building a message bus between two controllers to reunite them.
export default class extends Controller {
  static targets = ["tick", "status", "incidents"]
  static values = {
    matchId: String,
    operationId: String,
    commandsUrl: String,
    resetUrl: String
  }

  // Send on change, at most ~10/s. Coalescing by control id is the key property, and it works
  // only because commands are ABSOLUTE: dragging a slider fires hundreds of input events and
  // only the last value for each lever has any meaning.
  static THROTTLE_MS = 100

  // A pending lever unconfirmed for this long is assumed lost. Without it a dropped command
  // leaves the slider lying to the player forever — and a drop is expected here, because the
  // producer does not wait on delivery.
  static PENDING_TIMEOUT_MS = 2000

  connect() {
    this.state = { gauges: {}, flags: {}, controls: {}, tick: null }
    this.pending = new Map()
    this.queued = new Map()
    this.timer = null

    // Built once, on connect — not per tick. At 4 Hz a querySelector per gauge per tick is
    // pure waste.
    this.instruments = new Map()
    this.element.querySelectorAll("[data-instrument-id]").forEach((el) => {
      this.instruments.set(el.dataset.instrumentId, el)
    })
    this.levers = new Map()
    this.element.querySelectorAll("[data-lever-id]").forEach((el) => {
      this.levers.set(el.dataset.leverId, el)
    })

    this.subscription = consumer.subscriptions.create(
      {
        channel: "OperationChannel",
        match_id: this.matchIdValue,
        operation_id: this.operationIdValue
      },
      {
        connected: () => {
          this.setStatus("live", "text-emerald-300")
          // Ask for a full view immediately rather than waiting up to 10s for the periodic
          // one. Goes over HTTP like every other command, so it stays on the ordered path.
          this.resync()
        },
        disconnected: () => this.setStatus("disconnected", "text-rose-300"),
        rejected: () => this.setStatus("rejected", "text-rose-300"),
        received: (message) => this.apply(message)
      }
    )
  }

  disconnect() {
    this.subscription?.unsubscribe()
    if (this.timer) clearTimeout(this.timer)
  }

  // --- incoming ------------------------------------------------------------

  apply(message) {
    // A tick that goes BACKWARDS means this is a different match than the one we were
    // watching — a reset rebuilds it from tick 0, and so does restarting the runner. The
    // incident list is the only thing that accumulates across ticks, so it is the only thing
    // that would otherwise carry a burst flywheel over into a fresh engine.
    //
    // Detected from the tick rather than from a reset message because it then covers the
    // runner restarting too, which has exactly the same symptom and no message at all.
    if (this.state.tick !== null && message.tick < this.state.tick) this.clearIncidents()

    if (message.kind === "full") {
      this.state = {
        gauges: { ...message.view.gauges },
        flags: { ...message.view.flags },
        controls: { ...message.view.controls },
        tick: message.tick
      }
    } else {
      // A gap means we missed a message. Compare against prev_tick, NOT tick - 1: unchanged
      // ticks are skipped by design, so gaps in the tick sequence are normal.
      if (message.prev_tick !== this.state.tick) return this.resync()

      Object.assign(this.state.gauges, message.view.gauges)
      Object.assign(this.state.flags, message.view.flags)
      Object.assign(this.state.controls, message.view.controls)
      this.state.tick = message.tick
    }

    // Incidents are APPENDED. The simulation replaces its event list every tick, so a delta
    // carries only this tick's — assigning would lose the record one tick after it appeared.
    this.appendIncidents(message.view.incidents || [])
    this.paint()
  }

  paint() {
    if (this.hasTickTarget) this.tickTarget.textContent = this.state.tick ?? "—"

    for (const [id, el] of this.instruments) {
      this.paintInstrument(el, this.state.gauges[id], this.state.flags[id] || [])
    }
    for (const [id, el] of this.levers) {
      this.paintLever(el, id, this.state.controls[id])
    }
  }

  paintInstrument(el, value, flags) {
    const offline = flags.includes("offline") || value === null || value === undefined
    const readout = el.querySelector("[data-instrument-value]")
    if (readout) readout.textContent = offline ? "—" : value

    // :warming_up is not a fault. Every lagged gauge raises it for its first few ticks, so
    // showing it as an alarm would light up the whole panel on every fresh match.
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

  paintLever(el, id, control) {
    if (!control) return
    const input = el.querySelector("[data-lever-input]")
    const readout = el.querySelector("[data-lever-readout]")
    const ghost = el.querySelector("[data-lever-ghost]")
    const pending = this.pending.get(id)

    if (pending === undefined) {
      input.value = control.target
    } else if (pending.value === control.target) {
      // Confirmed by the authoritative projection.
      this.pending.delete(id)
      delete input.dataset.pending
    } else if (Date.now() - pending.at > this.constructor.PENDING_TIMEOUT_MS) {
      // Never confirmed. The server is authoritative — it also CLAMPS, so a client that sent
      // 150 legitimately gets 100 back and must not keep insisting.
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

  clearIncidents() {
    if (!this.hasIncidentsTarget) return
    this.incidentsTarget.replaceChildren()
    const empty = document.createElement("li")
    empty.className = "text-slate-500 italic"
    empty.dataset.incidentsEmpty = "true"
    empty.textContent = "nothing has gone wrong yet"
    this.incidentsTarget.append(empty)
  }

  appendIncidents(incidents) {
    if (!incidents.length || !this.hasIncidentsTarget) return
    this.incidentsTarget.querySelector("[data-incidents-empty]")?.remove()

    for (const incident of incidents) {
      const li = document.createElement("li")
      li.textContent = `t${incident.tick} · ${incident.label || incident.node}: ` +
        `${(incident.type || "").replace(/_/g, " ")} (${incident.cause || "?"})`
      this.incidentsTarget.prepend(li)
    }
  }

  // --- outgoing ------------------------------------------------------------

  lever(event) {
    const el = event.target
    const id = el.closest("[data-lever-id]").dataset.leverId
    const value = Number(el.value)

    // Move immediately and mark it unconfirmed. This is what makes a 4 Hz game feel instant:
    // the round trip is a whole tick away, and waiting for it would feel broken.
    el.dataset.pending = "true"
    this.pending.set(id, { value, at: Date.now() })
    const readout = el.closest("[data-lever-id]").querySelector("[data-lever-readout]")
    if (readout) readout.textContent = Math.round(value)

    this.queued.set(id, value)
    this.scheduleFlush()
  }

  assign(event) {
    const li = event.target.closest("[data-minion-id]")
    this.send({
      type: "assign_minion",
      minion_id: li.dataset.minionId,
      control_point_id: event.target.value || null
    })
  }

  reset() {
    if (!confirm("Rebuild the engine from cold? Everything in progress is lost.")) return
    this.post(this.resetUrlValue, {})
  }

  resync() {
    this.send({ type: "resync" })
  }

  scheduleFlush() {
    if (this.timer) return
    this.timer = setTimeout(() => {
      this.timer = null
      for (const [id, value] of this.queued) {
        this.send({ type: "set_control", control_point_id: id, value })
      }
      this.queued.clear()
    }, this.constructor.THROTTLE_MS)
  }

  send(command) {
    this.post(this.commandsUrlValue, command)
  }

  async post(url, body) {
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          // Forgery protection stays ON. Skipping it on a state-changing endpoint is a real
          // hole, and the alternative is this one line.
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content || ""
        },
        body: JSON.stringify(body)
      })
      if (!response.ok && response.status !== 202) {
        this.setStatus(`command ${response.status}`, "text-amber-300")
      }
    } catch (error) {
      this.setStatus("send failed", "text-rose-300")
    }
  }

  setStatus(text, colourClass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className =
      `text-xs px-2 py-0.5 rounded-full bg-slate-800 ${colourClass}`
  }
}
