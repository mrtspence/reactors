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
  # The outfitting screen. Nested under the operation rather than the match, because a loadout
  # belongs to one machine and a match will eventually hold several.
  # Three ways in, two of which render the same screen.
  #
  #   GET  …/components          what is fitted
  #   POST …/components/preview  what you are *considering* — the draft, into a Turbo frame
  #   POST …/components          commit it and rebuild the engine
  #
  # **The preview is a POST rather than a GET on purpose.** A GET form would carry the CSRF
  # token in the query string on every dropdown change — into history, logs and anywhere the
  # URL is pasted — which is a poor trade for a bookmarkable draft nobody wants.
  get "matches/:match_id/operations/:operation_id/components",
      to: "components#show", as: :components
  post "matches/:match_id/operations/:operation_id/components/preview",
       to: "components#show", as: :preview_components
  post "matches/:match_id/operations/:operation_id/components", to: "components#fit"
  post "matches/:match_id/commands", to: "commands#create", as: :match_commands
  post "matches/:match_id/reset", to: "matches#reset", as: :match_reset

  root to: redirect("/matches/#{DevMatch::ID}/operations/#{DevMatch::OPERATION_ID}")
end
