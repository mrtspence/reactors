# frozen_string_literal: true

module ReactorSim
  # **Taking cover**: what a person does when a node calls the place they are in to cover — a shot
  # about to be fired (`Nodes::ShotHole`'s `warning:`). Pure, over a person's state; the one die it
  # reads is thrown in phase 0 from their own stream (`Cover.stream`), whether or not anything calls.
  #
  # - **Called, they heed it or not, once a call**: their die against `Minion#misjudges`, so the
  #   boneheaded and the distracted keep working through the shot.
  # - **Heeding, they are under cover where they stand**: crouched behind what is there (`CROUCH`),
  #   or in a shelter of their place while it has a seat (`Nodes::Shelter`), seats taken by sorted
  #   id. **Under cover they man nothing and do not walk**, as a fighter does not.
  # - **A post a shelter covers** (its `stations:` — a machine's cab) is not left: whoever is at it
  #   has its cover, called or not.
  # - **A `sheltered:` peril reaches them by `1 − cover`.** When the call ends the cover goes, and
  #   they are back at work.
  #
  #   minion state: cover — nil uncalled, the share they are under, 0.0 called and not heeding
  module Cover
    # Crouched behind a car, a bank, a barrow: about half of what flies misses.
    CROUCH = 0.5

    module_function

    def stream(minion_id) = :"#{minion_id}/cover"

    def draw(rng) = rng.float

    def taken?(state) = state.fetch(:cover, nil).to_f.positive?

    # What covers them from a `sheltered:` peril: the cover they took, or their post's.
    def share(state, post_cover) = [ state.fetch(:cover, nil).to_f, post_cover.to_f ].max

    # Their cover this tick, called: what they decided when the call first reached them (`heard`,
    # nil if it has not), or their die against how readily they misjudge; then a shelter's seat
    # if one is free (`seat`, the shelter's cover or nil).
    def taken(heard, die, misjudges, seat)
      heeding = heard.nil? ? die >= misjudges : heard.positive?
      return 0.0 unless heeding

      seat ? [ seat, CROUCH ].max : CROUCH
    end
  end
end
