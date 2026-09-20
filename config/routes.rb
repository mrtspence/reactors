Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # `:match_id` is in the path even though there is exactly one match. It costs nothing now and
  # avoids re-pathing every route, every Stimulus fetch and every cable stream name the day
  # there is a second one. Controllers 404 anything that is not the dev match.
  get "matches/:match_id/operations/:operation_id", to: "consoles#show", as: :console

  # **Standard actions only** (`app/CLAUDE.md`, "Controllers are routing, not logic"), which
  # means the verbs a player thinks in — fit, preview, reset — each had to find the noun that
  # makes them standard:
  #
  #   GET   …/loadout/edit   the outfitting screen
  #   PATCH …/loadout        fit it, and rebuild the engine from cold
  #   POST  …/loadout_draft  evaluate a build without storing it, into a Turbo frame
  #   POST  …/matches/:id/reset   ask for a rebuild
  #
  # A **draft** is a resource in its own right: changing a dropdown asks what a build *would* be,
  # and the answer is a rendering rather than a saved record, so `create` is the honest verb. A
  # **reset** likewise — what it creates is a request that the runner start again.
  #
  # The loadout is nested under the operation rather than the match, because a loadout belongs to
  # one machine and a match will eventually hold several. Singular (`resource`) because a machine
  # has exactly one.
  #   GET   …/crew/edit      the pre-match crew screen
  #   PATCH …/crew           post them, and rebuild the engine from cold
  #   POST  …/crew_draft     evaluate a roster without storing it
  #
  # A crew is a loadout by another name, so it gets the same three routes and the same nouns. The
  # draft earns its keep harder here than it does for parts: changing who holds a job changes
  # **which kit is offered**, because equipment is owned per minion.
  # **Commands are nested under the OPERATION, not the match**, because a command names the
  # machine it is for and a match may hold several. It was match-level while there was exactly
  # one operation and `CommandsController` wrote `DevMatch::OPERATION_ID` into every payload —
  # which is precisely what stopped a second console driving a second engine.
  scope "matches/:match_id/operations/:operation_id" do
    resource :loadout, only: %i[edit update]
    resource :loadout_draft, only: %i[create]
    resource :crew, only: %i[edit update]
    resource :crew_draft, only: %i[create]
    post "commands", to: "commands#create", as: :operation_commands
  end
  resource :match_reset, only: %i[create], path: "matches/:match_id/reset"

  root to: redirect("/matches/#{DevMatch::ID}/operations/#{DevMatch::PRIMARY}")
end
