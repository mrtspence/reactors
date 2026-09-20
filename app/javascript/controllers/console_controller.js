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

  // How long the run we are watching must go quiet before an unfamiliar one is taken as its
  // successor. A restarted runner announces nothing, so silence is the only signal; a reset
  // says `supersedes` and does not wait this out.
  static FOREIGN_RUN_GRACE_MS = 2000

  connect() {
    this.state = { gauges: {}, flags: {}, controls: {}, crew: {}, tick: null }
    this.runId = null
    this.lastRunAt = 0
    this.foreignAt = 0
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
    this.crew = new Map()
    this.element.querySelectorAll("[data-minion-id]").forEach((el) => {
      this.crew.set(el.dataset.minionId, el)
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
    // History, sent once on subscribe from the durable log. It arrives BEFORE any view, so it
    // is handled before the tick-regression check below — which would otherwise have nothing
    // to compare against and does not apply to it anyway.
    //
    // This is what makes joining late honest: the incident list used to accumulate only from
    // ticks this browser happened to be connected for, so a spectator one tick behind the
    // flywheel was told nothing had gone wrong.
    if (message.kind === "backfill") {
      return this.appendIncidents(message.incidents || [])
    }

    if (!this.admitRun(message)) return

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
        crew: { ...message.view.crew },
        tick: message.tick
      }
    } else {
      // A gap means we missed a message. Compare against prev_tick, NOT tick - 1: unchanged
      // ticks are skipped by design, so gaps in the tick sequence are normal.
      if (message.prev_tick !== this.state.tick) return this.resync()

      Object.assign(this.state.gauges, message.view.gauges)
      Object.assign(this.state.flags, message.view.flags)
      Object.assign(this.state.controls, message.view.controls)
      Object.assign(this.state.crew, message.view.crew)
      this.state.tick = message.tick
    }

    // Incidents are APPENDED. The simulation replaces its event list every tick, so a delta
    // carries only this tick's — assigning would lose the record one tick after it appeared.
    this.appendIncidents(message.view.incidents || [])
    this.paint()
  }

  // Whether this message describes the match we are watching.
  //
  // Nothing stops a second `bin/match_runner` broadcasting onto this stream. It holds its own
  // match, at its own tick, with its own levers — and only one of them can hold the command
  // partition, so the other stays cold. An idle engine is skipped until the periodic full view,
  // which then arrives as one frame of a dead machine and replaces the panel wholesale.
  //
  // A run changes legitimately on a reset, which says so, and on a runner restart, which cannot
  // — so silence from our own run stands in for the announcement a restart never makes.
  admitRun(message) {
    const runId = message.run_id
    if (!runId) return true

    const now = Date.now()
    const grace = this.constructor.FOREIGN_RUN_GRACE_MS

    if (this.runId === null || runId === this.runId) {
      this.runId = runId
      this.lastRunAt = now
      if (this.foreignAt && now - this.foreignAt > 5 * grace) {
        this.foreignAt = 0
        this.setStatus("live", "text-emerald-300")
      }
      return true
    }

    if (message.supersedes !== this.runId && now - this.lastRunAt < grace) {
      if (!this.foreignAt) {
        console.warn(`console: ignoring views from run ${runId}; watching ${this.runId}. ` +
                     "Two runners are broadcasting to this match.")
      }
      this.foreignAt = now
      this.setStatus("two runners", "text-amber-300")
      return false
    }

    this.runId = runId
    this.lastRunAt = now
    this.clearIncidents()
    this.state = { gauges: {}, flags: {}, controls: {}, crew: {}, tick: null }
    if (message.kind !== "full") {
      this.resync()
      return false
    }
    return true
  }

  paint() {
    if (this.hasTickTarget) this.tickTarget.textContent = this.state.tick ?? "—"

    for (const [id, el] of this.instruments) {
      this.paintInstrument(el, this.state.gauges[id], this.state.flags[id] || [])
    }
    for (const [id, el] of this.levers) {
      this.paintLever(el, id, this.state.controls[id])
    }
    for (const [id, el] of this.crew) {
      this.paintMinion(el, this.state.crew[id])
    }
  }

  // Where somebody is standing, and what has happened to them.
  //
  // The station select is only written when it is NOT focused. A player part-way through
  // choosing a new posting must not have the dropdown yanked back to the authoritative value
  // under their cursor four times a second — the same reason paintLever leaves a control alone
  // while it is being dragged.
  paintMinion(el, crew) {
    if (!crew) return

    const select = el.querySelector("[data-minion-station]")
    if (select && document.activeElement !== select) {
      select.value = crew.station || ""
    }

    this.paintFatigue(el, crew)

    const injury = el.querySelector("[data-minion-injury]")
    if (!injury) return

    injury.textContent = crew.injury ? this.words(crew.injury) : ""
    injury.classList.toggle("hidden", !crew.injury)
    // A scratch and being carried out are not the same news.
    injury.classList.toggle("text-amber-400", crew.injury === "minor")
    injury.classList.toggle("text-rose-400", Boolean(crew.injury) && crew.injury !== "minor")
  }

  // A spent worker mans nothing at all — capability is exactly zero — so the bar filling is the
  // warning that a station is about to stop producing, and it is the cue to swap somebody in.
  paintFatigue(el, crew) {
    const bar = el.querySelector("[data-minion-fatigue]")
    if (!bar) return

    const fatigue = typeof crew.fatigue === "number" ? crew.fatigue : 0
    bar.style.width = `${Math.round(Math.min(Math.max(fatigue, 0), 1) * 100)}%`
    bar.classList.toggle("bg-slate-400", fatigue < 0.5)
    bar.classList.toggle("bg-amber-400", fatigue >= 0.5 && fatigue < 0.85)
    bar.classList.toggle("bg-rose-400", fatigue >= 0.85)
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

  // A fusible plug melting and a boiler exploding used to read identically here: one flat line
  // of engine vocabulary, same weight, same colour. The two are a ruined day and a ruined
  // engine, and the panel has to say which.
  //
  // **What a part BECAME is the headline, not what broke it.** `mode` is the word a driver
  // would use — exploded, blown head, scored bore — and `cause` is the post-mortem. Leading
  // with the cause buried the one fact that decides what to do next.
  appendIncidents(incidents) {
    if (!incidents.length || !this.hasIncidentsTarget) return
    this.incidentsTarget.querySelector("[data-incidents-empty]")?.remove()

    for (const incident of incidents) {
      this.incidentsTarget.prepend(this.buildIncident(incident))
    }
  }

  buildIncident(incident) {
    const critical = incident.severity === "critical"
    const li = document.createElement("li")
    li.className = `border-l-2 pl-2 py-0.5 ${critical ? "border-rose-500" : "border-amber-500"}`
    li.dataset.severity = incident.severity || "warning"

    const headline = document.createElement("div")
    headline.className = critical
      ? "font-semibold text-rose-200"
      : "text-amber-200"
    headline.textContent =
      `${incident.label || incident.node} — ${this.words(incident.mode || incident.type)}`
    li.append(headline)

    for (const line of this.incidentDetail(incident)) {
      const div = document.createElement("div")
      div.className = "text-[11px] text-slate-400"
      div.textContent = line
      li.append(div)
    }
    return li
  }

  // Ordered by what a driver needs first: that it got worse, then what it took with it, then
  // the forensics. `damaged` is the one that would otherwise arrive later as an unexplained
  // second failure.
  incidentDetail(incident) {
    const lines = []
    if (incident.escalated_from) {
      lines.push(`worsened from ${this.words(incident.escalated_from)}`)
    }
    if (incident.damaged?.length) {
      lines.push(`took ${incident.damaged.map((n) => this.words(n)).join(", ")} with it`)
    }
    lines.push(`t${incident.tick} · ${this.words(incident.cause || "unknown")}`)
    return lines
  }

  words(value) {
    return String(value).replace(/_/g, " ")
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
