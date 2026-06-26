module MessagesHelper
  STATUS_LABELS = {
    active: "Active",
    pending: "Pending",
    past: "Past"
  }.freeze

  # Section titles for the tenant/landlord board: grouped by whether the viewer
  # has a pending action.
  GROUP_TITLES = {
    needs_action: "Needs Your Action",
    everything_else: "All Other Negotiations"
  }.freeze

  # Section titles for the mediator board: simple active/past split.
  MEDIATOR_GROUP_TITLES = {
    active: "Active Mediations",
    past: "Past Mediations"
  }.freeze

  # Section titles for the admin board: needs-assignment cases surface first,
  # then the active/past split.
  ADMIN_GROUP_TITLES = {
    needs_assignment: "Needs Action",
    active: "Active Mediations",
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

  # Display name summarising both parties, used on mediator/admin cards where
  # there is no single "counterparty".
  def mediation_parties_summary(mediation)
    tenant_name   = full_name(mediation.tenant).presence   || mediation.tenant&.Email   || "Unknown Tenant"
    landlord_name = mediation.landlord&.CompanyName.presence ||
                    full_name(mediation.landlord).presence  ||
                    mediation.landlord&.Email                || "Unknown Landlord"
    "#{tenant_name} & #{landlord_name}"
  end

  # Human-readable description of where a mediation stands, from the viewer's
  # perspective, shown on its card.
  def mediation_substatus(mediation, viewer_role)
    case viewer_role
    when "Mediator"
      mediation.past? ? past_substatus(mediation) : "In progress"
    when "Admin"
      if mediation.past?
        past_substatus(mediation)
      elsif mediation.MediatorAssigned?
        "In progress"
      else
        "Awaiting mediator assignment"
      end
    else
      case mediation.status_category
      when :active
        "In progress"
      when :past
        past_substatus(mediation)
      when :pending
        pending_substatus(mediation.pending_stage, viewer_role)
      end
    end
  end

  # Lowercased text blob used by the client-side search filter.
  def mediation_search_terms(mediation, viewer_role)
    if [ "Mediator", "Admin" ].include?(viewer_role)
      [
        mediation.tenant&.FName,
        mediation.tenant&.LName,
        mediation.tenant&.Email,
        mediation.landlord&.FName,
        mediation.landlord&.LName,
        mediation.landlord&.Email,
        mediation.landlord&.CompanyName,
        mediation.tenant&.formatted_tenant_address,
        STATUS_LABELS.fetch(mediation.past? ? :past : :active, "")
      ].compact.join(" ").downcase
    else
      party = mediation_counterparty(mediation, viewer_role)
      [
        party&.FName,
        party&.LName,
        party&.Email,
        party&.CompanyName,
        mediation.tenant&.formatted_tenant_address,
        mediation_status_label(mediation)
      ].compact.join(" ").downcase
    end
  end

  private

  def past_substatus(mediation)
    ended_on  = mediation.deleted_at&.strftime("%B %d, %Y")
    ended_by  = mediation_ended_by_label(mediation)
    base      = ended_on ? "Ended #{ended_on}" : "Ended"
    ended_by  ? "#{base} · by #{ended_by}" : base
  end

  def mediation_ended_by_label(mediation)
    ender_id = mediation.EndedBy
    return nil if ender_id.blank?

    if ender_id == mediation.TenantID
      "Tenant"
    elsif ender_id == mediation.LandlordID
      "Landlord"
    elsif ender_id == mediation.MediatorID
      "Mediator"
    end
  end

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
