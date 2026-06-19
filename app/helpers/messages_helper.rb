module MessagesHelper
  STATUS_LABELS = {
    active: "Active",
    pending: "Pending",
    past: "Past"
  }.freeze

  # Section titles for the grouped (default) board view.
  GROUP_TITLES = {
    active: "Active Mediations",
    pending: "Pending Mediations",
    past: "Past Mediations"
  }.freeze

  def mediation_status_label(mediation)
    STATUS_LABELS.fetch(mediation.status_category, "")
  end

  # The party on the other side of the mediation from the viewer: a landlord
  # sees their tenant, a tenant sees their landlord.
  def mediation_counterparty(mediation, viewer_role)
    viewer_role == "Tenant" ? mediation.landlord : mediation.tenant
  end

  # Display name for the counterparty. Landlords are shown by company name
  # (falling back to a person/email); tenants by their personal name.
  def mediation_counterparty_name(mediation, viewer_role)
    party = mediation_counterparty(mediation, viewer_role)
    if viewer_role == "Tenant"
      party.CompanyName.presence || full_name(party).presence || party.Email
    else
      full_name(party).presence || party.Email
    end
  end

  # Human-readable description of where a mediation stands, from the viewer's
  # perspective, shown on its card.
  def mediation_substatus(mediation, viewer_role)
    case mediation.status_category
    when :active
      "In progress"
    when :past
      ended_on = mediation.deleted_at&.strftime("%B %d, %Y")
      ended_on ? "Ended #{ended_on}" : "Ended"
    when :pending
      pending_substatus(mediation.pending_stage, viewer_role)
    end
  end

  # Lowercased text blob used by the client-side search filter.
  def mediation_search_terms(mediation, viewer_role)
    party = mediation_counterparty(mediation, viewer_role)
    [
      party&.FName,
      party&.LName,
      party&.Email,
      party&.CompanyName,
      (party&.formatted_tenant_address if viewer_role == "Landlord"),
      mediation_status_label(mediation)
    ].compact.join(" ").downcase
  end

  private

  def full_name(user)
    [ user&.FName, user&.LName ].compact.join(" ").strip
  end

  # Pending sub-stage messaging is written from each viewer's point of view:
  # the same record reads as "action needed" to whoever must act next and as
  # "waiting" to the other party.
  def pending_substatus(stage, viewer_role)
    if viewer_role == "Tenant"
      case stage
      when :awaiting_landlord_acceptance then "Waiting for the landlord to accept the negotiation"
      when :awaiting_tenant_acceptance   then "Action needed: respond to this negotiation request"
      when :awaiting_tenant_intake       then "Action needed: complete your intake questions"
      else ""
      end
    else
      case stage
      when :awaiting_landlord_acceptance then "Action needed: respond to this negotiation request"
      when :awaiting_tenant_acceptance   then "Waiting for the tenant to accept the negotiation"
      when :awaiting_tenant_intake       then "Waiting for the tenant to complete intake questions"
      else ""
      end
    end
  end
end
