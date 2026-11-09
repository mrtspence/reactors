import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// **The frame's one subscription.** It merges each view into the machine's state and announces it
// on `window`, where the controllers that paint listen:
//
//   reactor:view       { state }      after every view, and again on `reactor:request`
//   reactor:incidents  { incidents }  the backfill, then each view's own
//   reactor:cleared                   a new run or a match rebuilt from tick 0
//
// and it sends what they ask for (`reactor:command`, `{ command }`), so one place knows the
// commands URL and reports a failed send.
//
// It lives in the frame, which is `data-turbo-permanent`, so the subscription survives going from
// the console to outfitting and back. Turbo moves a permanent element on each visit, which
// disconnects and reconnects this controller, so teardown waits a turn and a reconnect cancels it.
export default class extends Controller {
  static targets = ["tick", "status"]
  static values = { matchId: String, operationId: String, commandsUrl: String }

  // How long the run we are watching must go quiet before an unfamiliar one is taken as its
  // successor. A restarted runner announces nothing, so silence is the only signal; a reset says
  // `supersedes` and does not wait this out.
  static FOREIGN_RUN_GRACE_MS = 2000

  // **Two deadlines, because silence means different things before and after the first view.**
  // A subscription that has never delivered one never took, and a working stream answers a resync
  // at once, so that is caught in a moment. Once it has spoken, quiet is ordinary — unchanged
  // ticks are skipped — and `ViewBroadcaster::FULL_VIEW_TICKS` puts a 10 s floor under it.
  static HANDSHAKE_MS = 1500
  static STALE_MS = 15000
  static WATCHDOG_MS = 250

  initialize() {
    this.state = this.emptyState()
    this.runId = null
    this.lastRunAt = 0
    this.foreignAt = 0
    this.leaving = null
  }

  connect() {
    if (this.leaving) {
      clearTimeout(this.leaving)
      this.leaving = null
      this.unmute()
      this.replay()
      return
    }

    this.onRequest = () => this.replay()
    this.onCommand = (event) => this.send(event.detail.command)
    this.unmute()

    this.live = true
    // **Deferred by a microtask so a frame being replaced has already let go.** Stimulus makes no
    // promise that the outgoing controller's `disconnect` runs before this `connect`.
    queueMicrotask(() => this.live && this.subscribe())
    this.watchdog = setInterval(() => this.checkStream(), this.constructor.WATCHDOG_MS)
  }

  // **Silent from the moment it disconnects**: a frame being replaced by another machine's must
  // not paint that machine's page with its own readings while its teardown waits.
  disconnect() {
    this.mute()
    this.leaving = setTimeout(() => this.teardown(), 0)
  }

  mute() {
    this.muted = true
    window.removeEventListener("reactor:request", this.onRequest)
    window.removeEventListener("reactor:command", this.onCommand)
  }

  unmute() {
    this.muted = false
    window.addEventListener("reactor:request", this.onRequest)
    window.addEventListener("reactor:command", this.onCommand)
  }

  teardown() {
    this.leaving = null
    this.live = false
    this.subscription?.unsubscribe()
    this.subscription = null
    if (this.watchdog) clearInterval(this.watchdog)
  }

  subscribe() {
    // Never two at once: a leftover would go on consuming the stream this one is judged by.
    this.subscription?.unsubscribe()
    this.lastMessageAt = Date.now()
    this.speaking = false

    this.subscription = consumer.subscriptions.create(
      {
        channel: "OperationChannel",
        match_id: this.matchIdValue,
        operation_id: this.operationIdValue,
        // **The nonce stops one frame cancelling another's subscription.** Action Cable keys
        // subscriptions by the JSON of these params, so two frames naming the same machine share a
        // key and an unsubscribe from the one torn down removes the new one. The channel ignores it.
        nonce: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
      },
      {
        connected: () => {
          this.setStatus("live", "text-emerald-300")
          this.lastMessageAt = Date.now()
          // A full view now rather than the periodic one up to 10 s away.
          this.resync()
        },
        disconnected: () => this.setStatus("disconnected", "text-rose-300"),
        rejected: () => this.setStatus("rejected", "text-rose-300"),
        received: (message) => this.apply(message)
      }
    )
  }

  // **The one failure the protocol cannot heal on its own**: a subscription torn down and never
  // replaced receives nothing and reads "live" forever. Resubscribing rather than resyncing,
  // because a resync's answer comes back over the very cable being doubted.
  checkStream() {
    const deadline = this.speaking ? this.constructor.STALE_MS : this.constructor.HANDSHAKE_MS
    if (Date.now() - this.lastMessageAt < deadline) return

    this.setStatus("reconnecting", "text-amber-300")
    this.subscribe()
  }

  // --- incoming ------------------------------------------------------------

  apply(message) {
    this.lastMessageAt = Date.now()

    // **A backfill is not proof the stream is flowing.** It is transmitted to the subscription the
    // moment it is accepted, so even one about to be cancelled delivers one; only a broadcast view
    // says the stream works. It arrives before any view, from the durable log, so a late joiner
    // is told what has already gone wrong.
    if (message.kind === "backfill") return this.announce("incidents", { incidents: message.incidents || [] })
    this.speaking = true

    if (!this.admitRun(message)) return

    // A tick going backwards is a different match: a reset or a restarted runner rebuilds from 0.
    if (this.state.tick !== null && message.tick < this.state.tick) this.announce("cleared")

    if (message.kind === "full") {
      this.state = {
        gauges: { ...message.view.gauges },
        flags: { ...message.view.flags },
        controls: { ...message.view.controls },
        crew: { ...message.view.crew },
        tick: message.tick
      }
    } else {
      // Compare against prev_tick, NOT tick - 1: unchanged ticks are skipped by design.
      if (message.prev_tick !== this.state.tick) return this.resync()

      Object.assign(this.state.gauges, message.view.gauges)
      Object.assign(this.state.flags, message.view.flags)
      Object.assign(this.state.controls, message.view.controls)
      Object.assign(this.state.crew, message.view.crew)
      this.state.tick = message.tick
    }

    // Incidents are APPENDED: the simulation replaces its list every tick, so a delta carries only
    // this tick's.
    const incidents = message.view.incidents || []
    if (incidents.length) this.announce("incidents", { incidents })
    this.replay()
  }

  // Whether this message describes the match we are watching. A second runner broadcasting onto
  // the stream holds its own cold match; a run changes legitimately on a reset, which says so, and
  // on a runner restart, which cannot — so silence from our own run stands in for that.
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
        console.warn(`stream: ignoring views from run ${runId}; watching ${this.runId}. ` +
                     "Two runners are broadcasting to this match.")
      }
      this.foreignAt = now
      this.setStatus("two runners", "text-amber-300")
      return false
    }

    this.runId = runId
    this.lastRunAt = now
    this.announce("cleared")
    this.state = this.emptyState()
    if (message.kind !== "full") {
      this.resync()
      return false
    }
    return true
  }

  // The state as it stands, to every painter — after a view, and to a page that has just
  // connected under a frame that was already live.
  replay() {
    if (this.state.tick === null) return
    if (this.hasTickTarget) this.tickTarget.textContent = this.state.tick
    this.announce("view", { state: this.state })
  }

  announce(name, detail = {}) {
    if (this.muted) return
    window.dispatchEvent(new CustomEvent(`reactor:${name}`, { detail }))
  }

  emptyState() {
    return { gauges: {}, flags: {}, controls: {}, crew: {}, tick: null }
  }

  // --- outgoing ------------------------------------------------------------

  reset({ params: { resetUrl } }) {
    if (!confirm("Rebuild the engine from cold? Everything in progress is lost.")) return
    this.post(resetUrl, {})
  }

  resync() {
    this.send({ type: "resync" })
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
    this.statusTarget.className = `text-xs px-2 py-0.5 rounded-full bg-slate-800 ${colourClass}`
  }
}
