namespace :mediators do
  desc "Re-derive every mediator's ActiveMediations counter from live mediation data"
  task resync_caseloads: :environment do
    Mediator.resync_active_case_counts!
    puts "Re-synced ActiveMediations for #{Mediator.count} mediators."
  end
end
