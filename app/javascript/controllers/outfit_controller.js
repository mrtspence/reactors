import { Controller } from "@hotwired/stimulus"

// Re-render the draft whenever a part is swapped.
//
// The form is a GET back to the same URL, wrapped in a Turbo frame, so submitting it replaces
// the frame and nothing else: the page does not scroll, the header stays put, and the verdict
// updates along with the stats.
//
// The verdict is the whole reason this asks the server at all. Swapping the stats client-side
// would be easy — they are already on the page — but only the simulation can say whether a build
// assembles or what it will do to you, and a screen showing live stats beside stale warnings is
// worse than one that previews neither.
export default class extends Controller {
  static targets = ["form"]

  preview() {
    // `requestSubmit` rather than `submit`, because `submit` bypasses both validation and
    // Turbo's submit-event interception — which would turn this into a full page navigation and
    // throw away the scroll position, silently and only sometimes.
    this.formTarget.requestSubmit()
  }
}
