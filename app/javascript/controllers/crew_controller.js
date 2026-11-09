import { Controller } from "@hotwired/stimulus"
import { postings } from "console/postings"
import { words } from "console/words"

// **The crew**: where each of them is, what has happened to them, and where they are sent — each
// person's row in the panel of the place they are in, and a line in the panel of the place they
// are walking to.
//
// A control is written only when it is NOT focused, so a player part-way through choosing a
// posting does not have the dropdown yanked back under their cursor four times a second — and a
// row is not moved while its dropdown is open, which would close it.
export default class extends Controller {
  // Place id to label; post id to the place it stands in; the panel for anybody whose place has
  // none. An operation with no geometry ships empty maps, and every lookup misses.
  static values = { places: Object, stations: Object, fallback: String }

  connect() {
    this.crew = new Map()
    this.element.querySelectorAll("[data-minion-id]").forEach((el) => {
      this.crew.set(el.dataset.minionId, el)
    })
    this.panels = new Set([ ...this.element.querySelectorAll("[data-crew-here]") ].map((el) => el.dataset.crewHere))
    this.coming = new Map()

    this.onView = (event) => this.paint(event.detail.state)
    window.addEventListener("reactor:view", this.onView)
    window.dispatchEvent(new CustomEvent("reactor:request"))
  }

  disconnect() {
    window.removeEventListener("reactor:view", this.onView)
  }

  paint(state) {
    for (const [id, el] of this.crew) this.paintMinion(el, state.crew[id])
    this.paintPostings(state.crew)
    this.placeRows(state.crew)
    this.paintArrivals(state.crew)
  }

  panelFor(place) {
    return place && this.panels.has(place) ? place : this.fallbackValue
  }

  list(kind, panel) {
    return this.element.querySelector(`[data-crew-${kind}="${CSS.escape(panel)}"]`)
  }

  // Into the panel of where they are, kept in roster order.
  placeRows(crew) {
    const moved = new Set()
    for (const [id, el] of this.crew) {
      if (!crew[id] || el.contains(document.activeElement)) continue

      const list = this.list("here", this.panelFor(crew[id].place))
      if (!list || el.parentElement === list) continue
      list.append(el)
      moved.add(list)
    }

    for (const list of moved) {
      [ ...list.children ]
        .sort((a, b) => Number(a.dataset.minionOrder) - Number(b.dataset.minionOrder))
        .forEach((el) => list.append(el))
    }
  }

  // Where a posting takes somebody: the post's place, or the place of the person sent for.
  destination(posting, crew) {
    if (posting in this.stationsValue) return this.stationsValue[posting]
    return crew[posting]?.place
  }

  // How many are in each place, and who is walking to it.
  paintArrivals(crew) {
    const here = new Map()
    const coming = new Map()
    for (const [id, member] of Object.entries(crew || {})) {
      const at = this.panelFor(member.place)
      here.set(at, (here.get(at) || 0) + 1)
      if (!member.posting || member.station) continue

      const to = this.panelFor(this.destination(member.posting, crew))
      if (to === at) continue
      coming.set(to, [ ...(coming.get(to) || []), this.arrival(id, member) ])
    }

    for (const panel of this.panels) {
      const lines = coming.get(panel) || []
      const count = this.list("count", panel)
      if (count) {
        const n = here.get(panel) || 0
        count.textContent = `${n ? `${n} here` : "nobody here"}${lines.length ? `, ${lines.length} on the way` : ""}`
      }
      this.writeComing(panel, lines)
    }
  }

  arrival(id, member) {
    const name = this.crew.get(id)?.dataset.minionName || words(id)
    const posting = this.crew.get(id)?.querySelector(`option[value="${CSS.escape(member.posting)}"]`)
    const to = posting?.dataset.stationLabel || posting?.textContent || words(member.posting)
    const share = typeof member.travel === "number" ? Math.round(Math.min(Math.max(member.travel, 0), 1) * 100) : 0
    return `${name} — to ${to}, ${share}%`
  }

  // Rewritten only when it changes, so the list does not churn four times a second.
  writeComing(panel, lines) {
    const key = lines.join("\n")
    if (this.coming.get(panel) === key) return
    this.coming.set(panel, key)

    const list = this.list("coming", panel)
    if (list) list.replaceChildren(...lines.map((line) => Object.assign(document.createElement("li"), { textContent: line })))
    this.list("coming-heading", panel)?.classList.toggle("hidden", lines.length === 0)
  }

  // A full post is disabled in everybody's dropdown but its own members'. The engine refuses it
  // regardless — this is a courtesy, not the gate.
  paintPostings(crew) {
    const { sent } = postings(crew)
    for (const [id, el] of this.crew) {
      const select = el.querySelector("[data-minion-station]")
      if (!select || document.activeElement === select) continue

      const own = crew[id]?.posting
      for (const option of select.querySelectorAll("option[data-station-capacity]")) {
        const capacity = parseInt(option.dataset.stationCapacity, 10)
        const taken = sent.get(option.value) || 0
        option.textContent = `${option.dataset.stationLabel} ${taken}/${capacity}`
        option.disabled = taken >= capacity && own !== option.value
      }
    }
  }

  paintMinion(el, crew) {
    if (!crew) return

    // **Bound to `posting`, not `station`**: somebody walking to the far face has been sent there
    // and has not arrived, and the order must not read as lost for the whole journey.
    const select = el.querySelector("[data-minion-station]")
    if (select && document.activeElement !== select) select.value = crew.posting || ""

    this.paintPlace(el, crew)
    this.paintTravel(el, crew)
    this.paintFatigue(el, crew)
    this.paintAsphyxia(el, crew)
    this.paintCarrying(el, crew)

    const injury = el.querySelector("[data-minion-injury]")
    if (!injury) return

    injury.textContent = crew.injury ? words(crew.injury) : ""
    injury.classList.toggle("hidden", !crew.injury)
    // A scratch and being carried out are not the same news.
    const onTheirFeet = crew.injury === "minor" || crew.injury === "significant"
    injury.classList.toggle("text-amber-400", onTheirFeet)
    injury.classList.toggle("text-rose-400", Boolean(crew.injury) && !onTheirFeet)
  }

  // Carrying and being carried, painted from opposite ends. **Set down is on the carried
  // person's row**, so it is per person with no list to pick from, and hidden unless somebody is
  // holding them.
  paintCarrying(el, crew) {
    const held = Array.isArray(crew.carrying) ? crew.carrying : []
    const carrying = el.querySelector("[data-minion-carrying]")
    if (carrying) {
      carrying.textContent = held.length ? `carrying ${held.map((id) => words(id)).join(", ")}` : ""
      carrying.classList.toggle("hidden", held.length === 0)
    }

    const drop = el.querySelector("[data-minion-drop]")
    if (!drop) return

    drop.classList.toggle("hidden", !crew.carried_by)
    drop.title = crew.carried_by ? `Carried by ${words(crew.carried_by)}` : ""
  }

  paintPlace(el, crew) {
    const place = el.querySelector("[data-minion-place]")
    if (!place) return

    const label = crew.place ? this.placesValue[crew.place] : null
    place.textContent = label ? ` · ${label}` : ""
  }

  // Sent somewhere and not there yet: `posting` set with no `station`. `travel` is the share of
  // the whole journey, so the bar fills once, and the metres left ride along as the tooltip.
  paintTravel(el, crew) {
    const travel = el.querySelector("[data-minion-travel]")
    if (!travel) return

    const walking = Boolean(crew.posting) && !crew.station
    travel.textContent = walking ? "on the road" : ""
    travel.classList.toggle("hidden", !walking)

    const wrap = el.querySelector("[data-minion-travel-bar]")
    if (!wrap) return

    wrap.classList.toggle("hidden", !walking)
    const progress = typeof crew.travel === "number" ? crew.travel : 0
    const bar = wrap.querySelector("[data-minion-progress]")
    if (bar) bar.style.width = `${Math.round(Math.min(Math.max(progress, 0), 1) * 100)}%`

    const left = crew.remaining_m
    wrap.title = typeof left === "number" ? `${Math.round(left)} m to go` : "On the road"
  }

  // A spent worker mans nothing, so the bar filling is the cue to swap somebody in.
  paintFatigue(el, crew) {
    const bar = el.querySelector("[data-minion-fatigue]")
    if (!bar) return

    const fatigue = typeof crew.fatigue === "number" ? crew.fatigue : 0
    bar.style.width = `${Math.round(Math.min(Math.max(fatigue, 0), 1) * 100)}%`
    bar.classList.toggle("bg-slate-400", fatigue < 0.5)
    bar.classList.toggle("bg-amber-400", fatigue >= 0.5 && fatigue < 0.85)
    bar.classList.toggle("bg-rose-400", fatigue >= 0.85)
  }

  // **A rescue timer, not a status**: it runs backwards once the air is restored, so it shows
  // before it finishes. Hidden at zero.
  paintAsphyxia(el, crew) {
    const wrap = el.querySelector("[data-minion-asphyxia-bar]")
    if (!wrap) return

    const asphyxia = typeof crew.asphyxia === "number" ? crew.asphyxia : 0
    wrap.classList.toggle("hidden", asphyxia <= 0)

    const bar = wrap.querySelector("[data-minion-asphyxia]")
    if (bar) bar.style.width = `${Math.round(Math.min(Math.max(asphyxia, 0), 1) * 100)}%`
  }

  assign(event) {
    const li = event.target.closest("[data-minion-id]")
    this.command({ type: "assign_minion", minion_id: li.dataset.minionId,
                   control_point_id: event.target.value || null })
  }

  // No destination: somebody is set down where their carrier is standing.
  drop(event) {
    const li = event.target.closest("[data-minion-id]")
    this.command({ type: "drop_minion", minion_id: li.dataset.minionId })
  }

  command(command) {
    this.dispatch("command", { target: window, prefix: "reactor", detail: { command } })
  }
}
