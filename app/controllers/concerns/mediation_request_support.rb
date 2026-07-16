module MediationRequestSupport
  extend ActiveSupport::Concern

  def find_existing_landlord(email)
    User.find_by(Email: email.to_s.strip)
  end

  def find_existing_tenant(email)
    User.find_by(Email: email.to_s.strip)
  end

  def create_mediation_for_tenant_requester(requester, landlord, intake_id)
    ActiveRecord::Base.transaction do
      message_string = MessageString.create!(Role: "Primary")

      PrimaryMessageGroup.create!(
        ConversationID: message_string.ConversationID,
        TenantID: requester.UserID,
        LandlordID: landlord.UserID,
        CreatedAt: Time.current,
        GoodFaith: false,
        MediatorRequested: false,
        MediatorAssigned: false,
        EndOfConversationGoodFaithLandlord: nil,
        EndOfConversationGoodFaithTenant: nil,
        accepted_by_landlord: false,
        accepted_by_tenant: true,
        requested_by: "Tenant",
        IntakeID: intake_id
      )
    end
  end

  def create_mediation_for_landlord_requester(requester, tenant, landlord_intake_id)
    ActiveRecord::Base.transaction do
      message_string = MessageString.create!(Role: "Primary")

      PrimaryMessageGroup.create!(
        ConversationID: message_string.ConversationID,
        TenantID: tenant.UserID,
        LandlordID: requester.UserID,
        CreatedAt: Time.current,
        GoodFaith: false,
        MediatorRequested: false,
        MediatorAssigned: false,
        EndOfConversationGoodFaithLandlord: nil,
        EndOfConversationGoodFaithTenant: nil,
        accepted_by_landlord: true,
        accepted_by_tenant: false,
        requested_by: "Landlord",
        LandlordIntakeID: landlord_intake_id
      )
    end
  end
end
