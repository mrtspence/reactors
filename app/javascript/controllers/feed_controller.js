import { Controller } from "@hotwired/stimulus"
import { words } from "console/words"

// **The feed**: what has gone wrong, newest first. It sits in the permanent frame, so its history
// lasts across this machine's screens and clears only when the match does.
export default class extends Controller {
  static targets = ["list"]

  connect() {
    this.onIncidents = (event) => this.append(event.detail.incidents)
    this.onCleared = () => this.clear()
    window.addEventListener("reactor:incidents", this.onIncidents)
    window.addEventListener("reactor:cleared", this.onCleared)
  }

  disconnect() {
    window.removeEventListener("reactor:incidents", this.onIncidents)
    window.removeEventListener("reactor:cleared", this.onCleared)
  }

  clear() {
    const empty = document.createElement("li")
    empty.className = "text-slate-500 italic"
    empty.dataset.feedEmpty = "true"
    empty.textContent = "nothing has gone wrong yet"
    this.listTarget.replaceChildren(empty)
  }

  append(incidents) {
    if (!incidents.length) return
    this.listTarget.querySelector("[data-feed-empty]")?.remove()
    for (const incident of incidents) this.listTarget.prepend(this.build(incident))
  }

  // **What a part BECAME is the headline, not what broke it**: `mode` is the word a driver would
  // use — exploded, blown head — and `cause` is the post-mortem.
  build(incident) {
    const critical = incident.severity === "critical"
    const li = document.createElement("li")
    li.className = `border-l-2 pl-2 py-0.5 ${critical ? "border-rose-500" : "border-amber-500"}`
    li.dataset.severity = incident.severity || "warning"

    const headline = document.createElement("div")
    headline.className = critical ? "font-semibold text-rose-200" : "text-amber-200"
    headline.textContent = `${incident.label || incident.node} — ${words(incident.mode || incident.type)}`
    li.append(headline)

    for (const line of this.detail(incident)) {
      const div = document.createElement("div")
      div.className = "text-[11px] text-slate-400"
      div.textContent = line
      li.append(div)
    }
    return li
  }

  // What a driver needs first: that it got worse, then what it took with it, then the forensics.
  detail(incident) {
    const lines = []
    if (incident.escalated_from) lines.push(`worsened from ${words(incident.escalated_from)}`)
    if (incident.damaged?.length) lines.push(`took ${incident.damaged.map((n) => words(n)).join(", ")} with it`)
    lines.push(`t${incident.tick} · ${words(incident.cause || "unknown")}`)
    return lines
  }
}
