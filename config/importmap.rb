# Pin npm packages by running ./bin/importmap

pin "application"
pin "agreement_editor", to: "agreement_editor.js"
pin "@hotwired/turbo-rails", to: "turbo.min.js", preload: true
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin_all_from "app/javascript/channels", under: "channels"
pin_all_from "app/javascript/chat", under: "chat"
pin "mediator_schedule", to: "mediator_schedule.js"
