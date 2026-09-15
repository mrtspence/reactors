import { Controller } from "@hotwired/stimulus"

// Re-render the draft whenever a part is swapped.
//
// The verdict is the whole reason this asks the server at all. Swapping the stats client-side
// would be easy — they are already on the page — but only the simulation can say whether a build
// assembles or what it will do to you, and a screen showing live stats beside stale warnings is
// worse than one that previews neither.
export default class extends Controller {
  static targets = ["form"]
  static values = { draftUrl: String }

  // The form's own action is FIT — a PATCH to the loadout — so the primary action needs no
  // JavaScript at all. Previewing borrows the form and points it at the DRAFT resource instead,
  // then puts it back. That direction is deliberate: previewing is inherently scripted (it fires
  // on `change`), so degrading to "no live preview" is right where degrading to "cannot fit
  // anything" would not be.
  preview() {
    const form = this.formTarget
    const action = form.getAttribute("action")
    // Rails sends PATCH as a POST carrying `_method`. The draft resource is a real POST, so the
    // override has to come off or the request routes as a PATCH and 404s.
    const override = form.querySelector('input[name="_method"]')
    const method = override ? override.value : null

    form.setAttribute("action", this.draftUrlValue)
    if (override) override.value = ""

    // `requestSubmit` rather than `submit`, because `submit` bypasses both validation and Turbo's
    // submit-event interception — which would turn this into a full page navigation and throw
    // away the scroll position, silently and only sometimes.
    //
    // It dispatches the submit event synchronously and Turbo reads the form during that dispatch,
    // so restoring immediately afterwards is safe.
    form.requestSubmit()

    form.setAttribute("action", action)
    if (override) override.value = method
  }
}
