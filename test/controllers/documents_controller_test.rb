require "test_helper"
require "tempfile"
require "tmpdir"
require "minitest/mock"
require_relative "../support/cable_authorization_helpers"

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  include CableAuthorizationHelpers

  %w[Primary Side].each do |role|
    test "HTTP denies #{role} document access through an overlapping wrong-type group" do
      build_security_case
      file = build_document_role_overlap(role)
      [@outsider, @other_mediator].each do |user|
        log_in_as(user)
        get document_path(file.FileID)
        assert_response :not_found
        get download_file_path(file.FileID)
        assert_response :not_found
        get view_inline_document_path(file.FileID)
        assert_response :not_found
      end
    end
  end

  test "HTTP viewing and shared lookup agree for primary document viewers" do
    build_security_case
    file = build_security_document
    [@landlord, @tenant, @mediator, @outsider, @admin].each do |user|
      log_in_as(user)
      get document_path(file.FileID)
      if FileDraft.find_viewable_by(user, file.FileID)
        assert_response :success
      else
        assert_response :not_found
      end
    end
    log_in_as(@landlord)
    file.update!(UserDeletedAt: Time.current)
    get document_path(file.FileID)
    assert_response :not_found
  end

  test "agreement review sends one actor-aware email to the other party per action" do
    file = create_agreement_draft
    log_in_as(@landlord)
    assert_enqueued_emails 1 do
      patch update_review_document_path(file.FileID), params: agreement_params.merge(
        agreement_version: 1, vacate_date: "2026-05-15"
      )
    end
    log_in_as(@tenant)
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :agreement_notification,
        args: [ @landlord, @mediation.ConversationID, "agreement_revised", file.FileID, @tenant,
                [ "Vacate date: 2026-05-01 → 2026-05-15" ],
                "No suggestions remain pending. The agreement is ready for signing." ] do
        patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }
      end
    end
    assert_no_enqueued_emails do
      patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }
    end
  end

  teardown do
    Array(@legacy_agreement_fixture_paths).each { |path| File.delete(path) if File.exist?(path) }
    Rails.application.config.x.document_storage = @previous_document_storage
    FileUtils.remove_entry(@document_storage_root) if @document_storage_root && File.exist?(@document_storage_root)
  end

  setup do
    @previous_document_storage = Rails.application.config.x.document_storage
    @document_storage_root = Dir.mktmpdir("document-creation-", Rails.root.join("tmp"))
    Rails.application.config.x.document_storage = DocumentStorageConfiguration.new(
      root: @document_storage_root, public_root: Rails.root.join("public")
    )
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediator = users(:mediator1)
    @outsider = users(:tenant2)
    @mediation = primary_message_groups(:one)
  end


  test "mediator suggestion requires both parties to accept before updating agreement" do
    file = create_agreement_draft
    original_date = file.agreement_terms["vacate_date"]
    confirmation_text = "Both the landlord and tenant have approved a suggested change."

    # Mediator proposes a change.
    log_in_as(@mediator)

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    assert_response :redirect

    proposal = file.reload.agreement_proposal

    assert_equal true, proposal["mediator_proposal"]
    assert_equal "pending", proposal["changes"]["vacate_date"]["party_decisions"]["landlord"]
    assert_equal "pending", proposal["changes"]["vacate_date"]["party_decisions"]["tenant"]

    # Landlord accepts first.
    log_in_as(@landlord)

    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_response :redirect
    assert_equal original_date, file.reload.agreement_terms["vacate_date"]
    assert_equal "accepted",
                 file.agreement_proposal["changes"]["vacate_date"]["party_decisions"]["landlord"]

    assert_equal 0, Message.where(
      ConversationID: file.agreement_conversation_id,
      is_system: true
    ).where("Contents LIKE ?", "%#{confirmation_text}%").count

    # Tenant accepts second.
    log_in_as(@tenant)

    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_response :redirect
    assert_equal "2026-05-15", file.reload.agreement_terms["vacate_date"]
    assert_equal "accepted", file.agreement_proposal["changes"]["vacate_date"]["decision"]
    assert_not file.agreement_suggestions_pending?

    assert_equal 1, Message.where(
      ConversationID: file.agreement_conversation_id,
      is_system: true
    ).where("Contents LIKE ?", "%#{confirmation_text}%").count

    # Repeated approval must not create another confirmation.
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_equal 1, Message.where(
      ConversationID: file.agreement_conversation_id,
      is_system: true
    ).where("Contents LIKE ?", "%#{confirmation_text}%").count
  end


  test "mediator suggestion rejection leaves agreement unchanged" do
    file = create_agreement_draft
    original_date = file.agreement_terms["vacate_date"]

    log_in_as(@mediator)

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    assert_response :redirect
    assert_equal true, file.reload.agreement_proposal["mediator_proposal"]

    # Tenant rejects the mediator's suggestion.
    log_in_as(@tenant)

    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "rejected" }

    assert_response :redirect

    file.reload

    assert_equal original_date, file.agreement_terms["vacate_date"]
    assert_equal "rejected", file.agreement_proposal["changes"]["vacate_date"]["decision"]
    assert_equal "rejected",
                file.agreement_proposal["changes"]["vacate_date"]["party_decisions"]["tenant"]
    assert_not file.agreement_suggestions_pending?

    # Landlord cannot accept a suggestion that has already been rejected.
    log_in_as(@landlord)

    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_response :redirect

    file.reload

    assert_equal original_date, file.agreement_terms["vacate_date"]
    assert_equal "rejected", file.agreement_proposal["changes"]["vacate_date"]["decision"]
  end

  test "landlord counteroffer to mediator suggestion requires tenant acceptance" do
    file = create_agreement_draft
    original_date = file.agreement_terms["vacate_date"]

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )
    assert_equal true, file.reload.agreement_proposal["mediator_proposal"]

    log_in_as(@landlord)
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-20" } }

    assert_response :redirect
    change = file.reload.agreement_proposal["changes"]["vacate_date"]
    assert_equal "2026-05-20", change["to"]
    assert_equal @landlord.UserID, change["offered_by_id"]
    assert_equal "accepted", change["party_decisions"]["landlord"]
    assert_equal "pending", change["party_decisions"]["tenant"]
    assert_equal original_date, file.agreement_terms["vacate_date"]

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_response :redirect
    assert_equal "2026-05-20", file.reload.agreement_terms["vacate_date"]
    assert_not file.agreement_suggestions_pending?
  end

  test "tenant counteroffer to mediator suggestion requires landlord acceptance" do
    file = create_agreement_draft

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    log_in_as(@tenant)
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-25" } }

    assert_response :redirect
    change = file.reload.agreement_proposal["changes"]["vacate_date"]
    assert_equal "accepted", change["party_decisions"]["tenant"]
    assert_equal "pending", change["party_decisions"]["landlord"]

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_response :redirect
    assert_equal "2026-05-25", file.reload.agreement_terms["vacate_date"]
  end

  test "mediator suggestion supports repeated counteroffers" do
    file = create_agreement_draft
    original_date = file.agreement_terms["vacate_date"]

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    log_in_as(@landlord)
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-20" } }

    log_in_as(@tenant)
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-25" } }

    change = file.reload.agreement_proposal["changes"]["vacate_date"]
    assert_equal "2026-05-25", change["to"]
    assert_equal "pending", change["party_decisions"]["landlord"]
    assert_equal "accepted", change["party_decisions"]["tenant"]
    assert_equal original_date, file.agreement_terms["vacate_date"]

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_equal "2026-05-25", file.reload.agreement_terms["vacate_date"]
  end

  test "mediator counteroffer rejection does not change agreement" do
    file = create_agreement_draft
    original_date = file.agreement_terms["vacate_date"]

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    log_in_as(@landlord)
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-20" } }

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "rejected" }

    assert_response :redirect
    assert_equal original_date, file.reload.agreement_terms["vacate_date"]
    assert_equal "rejected", file.agreement_proposal["changes"]["vacate_date"]["decision"]
    assert_not file.agreement_suggestions_pending?
  end

  test "accepting one mediator suggestion preserves other pending suggestions" do
    file = create_agreement_draft
    original_amount = file.agreement_terms["money_owed"]

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15",
      money_owed: "1200"
    )

    assert_equal 2, file.reload.agreement_proposal["changes"].size

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    file.reload
    assert_equal "2026-05-15", file.agreement_terms["vacate_date"]
    assert_equal original_amount, file.agreement_terms["money_owed"]
    assert file.agreement_suggestions_pending?

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "money_owed"),
          params: { decision: "accepted" }

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "money_owed"),
          params: { decision: "accepted" }

    assert_equal "1200", file.reload.agreement_terms["money_owed"]
    assert_not file.agreement_suggestions_pending?
  end

  test "mediator grouped payment suggestion requires both parties" do
    file = create_agreement_draft
    original_amount = file.agreement_terms["amount1"]
    original_date = file.agreement_terms["date1"]

    log_in_as(@mediator)

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      amount1: "750",
      date1: "2026-06-01"
    )

    file.reload


    item = file.agreement_suggestion_items.find do |suggestion|
      suggestion[:key] == "payment1"
    end

    assert_not_nil item, "Expected grouped payment suggestion"

    # Landlord accepts first.
    log_in_as(@landlord)

    patch decide_document_suggestion_path(file.FileID, "payment1"),
          params: { decision: "accepted" }

    file.reload

    assert_equal original_amount, file.agreement_terms["amount1"]
    assert_equal original_date, file.agreement_terms["date1"]

    # Tenant accepts second.
    log_in_as(@tenant)

    patch decide_document_suggestion_path(file.FileID, "payment1"),
          params: { decision: "accepted" }

    file.reload

    assert_equal "750", file.agreement_terms["amount1"]
    assert_equal "2026-06-01", file.agreement_terms["date1"]
  end

  test "mediator suggestion prevents duplicate and outsider decisions" do
    file = create_agreement_draft

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_equal "accepted",
                file.reload.agreement_proposal["changes"]["vacate_date"]["party_decisions"]["landlord"]

    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "rejected" }

    assert_equal "accepted",
                file.reload.agreement_proposal["changes"]["vacate_date"]["party_decisions"]["landlord"]

    log_in_as(@outsider)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    assert_not_equal "accepted",
                    file.reload.agreement_proposal["changes"]["vacate_date"]["party_decisions"]["tenant"]
    assert_equal "pending", file.agreement_proposal["changes"]["vacate_date"]["decision"]
  end

  test "mediator cannot approve own suggestion or sign agreement" do
    file = create_agreement_draft

    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: file.AgreementVersion,
      vacate_date: "2026-05-15"
    )

    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
          params: { decision: "accepted" }

    change = file.reload.agreement_proposal["changes"]["vacate_date"]
    assert_equal "pending", change["party_decisions"]["tenant"]
    assert_equal "pending", change["party_decisions"]["landlord"]

    get view_file_path(file.FileID)
    assert_response :success

    assert_select "button", text: /Sign Agreement/i, count: 0
  end


  test "admin cannot generate documents from intake" do
    log_in_as(users(:admin1))

    post generate_from_intake_path(template: "a"), params: { conversation_id: @mediation.ConversationID }

    assert_redirected_to admin_mediations_path
    assert_equal "Administrators have read-only access and cannot generate documents.", flash[:alert]
  end

  test "redirects to login when not authenticated" do
    get documents_path
    assert_redirected_to login_path
  end

  test "renders index for logged in user" do
    log_in_as(@tenant)

    get documents_path
    assert_response :success
  end

  test "create redirects when file is missing" do
    log_in_as(@tenant)

    post documents_path

    assert_redirected_to new_document_path
    assert_equal "Please choose a file to upload.", flash[:alert]
  end

  test "template intake renders with conversation data" do
    log_in_as(@tenant)

    get template_intake_path(template: "a"), params: { conversation_id: @mediation.ConversationID }

    assert_response :success
    assert_select "input[type='hidden'][name='additional_terms']", count: 1
  end

  [ :template_intake, :intake_template_view ].each do |endpoint|
    test "#{endpoint} permits both conversation parties" do
      [ @tenant, @landlord ].each do |party|
        log_in_as(party)
        get_template_information(endpoint, @mediation.ConversationID)

        assert_response :success
        assert_equal @tenant, assigns(:tenant)
        assert_equal @landlord, assigns(:landlord)
      end
    end

    test "#{endpoint} permits the currently assigned mediator" do
      @mediation.update!(MediatorID: @mediator.UserID, MediatorAssigned: true)
      log_in_as(@mediator)

      get_template_information(endpoint, @mediation.ConversationID)

      assert_response :success
      assert_equal @tenant, assigns(:tenant)
      assert_equal @landlord, assigns(:landlord)
    end

    test "#{endpoint} rejects unrelated users before loading case information" do
      log_in_as(@outsider)

      get_template_information(endpoint, @mediation.ConversationID)

      assert_template_information_not_found
    end

    test "#{endpoint} rejects a former mediator after reassignment" do
      @mediation.update!(MediatorID: @outsider.UserID, MediatorAssigned: true)
      log_in_as(@mediator)

      get_template_information(endpoint, @mediation.ConversationID)

      assert_template_information_not_found
    end

    test "#{endpoint} rejects a matching mediator whose assignment is inactive" do
      @mediation.update!(MediatorID: @mediator.UserID, MediatorAssigned: false)
      log_in_as(@mediator)

      get_template_information(endpoint, @mediation.ConversationID)

      assert_template_information_not_found
    end

    test "#{endpoint} rejects missing conversations without loading case information" do
      log_in_as(@tenant)

      get_template_information(endpoint, PrimaryMessageGroup.maximum(:ConversationID) + 1)

      assert_template_information_not_found
    end

    test "#{endpoint} redirects anonymous users before loading case information" do
      get_template_information(endpoint, @mediation.ConversationID)

      assert_redirected_to login_path
      assert_nil assigns(:template_conversation)
      assert_nil assigns(:tenant)
      assert_nil assigns(:landlord)
      assert_nil assigns(:intake)
    end
  end

  test "template intake preserves standalone generation without a conversation" do
    log_in_as(@tenant)

    get template_intake_path(template: "a")

    assert_response :success
    assert_nil assigns(:template_conversation)
    assert_select "form[action=?]", generate_from_intake_path(template: "a")
    assert_select "input[name='conversation_id']", count: 0
  end

  test "generated agreement titles use both entered party names for every template" do
    log_in_as(@mediator)

    { "a" => "Agree to Vacate", "b" => "Pay and Stay Agreement", "c" => "Mediation Agreement" }.each do |template, name|
      file_ids_before = FileDraft.pluck(:FileID)

      post generate_from_intake_path(template: template),
          params: (template == "b" ? pay_and_stay_params : agreement_params).merge(conversation_id: @mediation.ConversationID)

      assert_redirected_to documents_path

      file = FileDraft.where.not(FileID: file_ids_before).sole

      assert_equal "Jane Doe - John Doe - #{name}", file.FileName
      assert_nil file.AgreementConversationID
      assert_not FileAttachment.exists?(FileID: file.FileID)
    end
  end

  test "vacate agreement displays amount owed and additional terms without a payment schedule" do
    log_in_as(@tenant)
    post generate_from_intake_path(template: "a"), params: agreement_params.except(
      :amount1, :date1, :amount2, :date2
    ).merge(conversation_id: @mediation.ConversationID, additional_terms: "Return all keys.")
    file = FileDraft.where(
      CreatorID: @tenant.UserID,
      AgreementTemplate: "a"
    ).order(FileDraft.primary_key => :desc).first!
    document = Nokogiri::HTML(File.read(DocumentStorage.configured.resolve(file.FileURLPath)))

    assert_match "The Tenant owes Landlord $900. Tenant agrees to pay Landlord in the following manner:",
                 document.at_css("body > ol > li:nth-child(5)").text.squish
    assert_equal "900", document.at_css('[data-agreement-field="money_owed"]').text
    assert_equal "Return all keys.", document.at_css('[data-agreement-field="additional_terms"]').text
    assert_equal 8, document.css("body > ol > li:not([data-agreement-payment-anchor])").count
  end

  test "vacate amount owed and additional terms can be suggested and accepted" do
    file = create_agreement_draft
    document = Nokogiri::HTML(File.read(DocumentStorage.configured.resolve(file.FileURLPath)))
    assert document.at_css('[data-agreement-field="additional_terms"]')

    log_in_as(@landlord)
    get view_file_path(file.FileID, edit: 1)
    assert_response :success
    assert_select "input[data-agreement-term='money_owed']"
    assert_select "input[data-agreement-term='additional_terms']"

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, money_owed: "1000", additional_terms: "Return all keys."
    )
    assert_equal %w[additional_terms money_owed], file.reload.agreement_proposal["changes"].keys.sort

    log_in_as(@tenant)
    %w[money_owed additional_terms].each do |field|
      patch decide_document_suggestion_path(file.FileID, field), params: { decision: "accepted" }
    end
    assert_not file.reload.agreement_suggestions_pending?
    assert_equal "1000", file.agreement_terms["money_owed"]
    assert_equal "Return all keys.", file.agreement_terms["additional_terms"]
    document = Nokogiri::HTML(File.read(DocumentStorage.configured.resolve(file.FileURLPath)))
    assert_equal "1000", document.at_css('[data-agreement-field="money_owed"]').text
    assert_equal "Return all keys.", document.at_css('[data-agreement-field="additional_terms"]').text
  end

  test "template intake handles unknown template" do
    log_in_as(@tenant)

    get template_intake_path(template: "z")

    assert_response :success
  end

  test "template preview renders" do
    log_in_as(@tenant)

    get template_preview_path(template: "b")

    assert_response :success
  end

  test "template preview falls back for unknown template" do
    log_in_as(@tenant)

    get template_preview_path(template: "unknown")

    assert_response :success
  end

  test "template preview supports mediation template" do
    log_in_as(@tenant)

    get template_preview_path(template: "c")

    assert_response :success
  end

  test "create rejects unsupported upload type" do
    log_in_as(@tenant)

    file = build_uploaded_file("bad.exe", "application/octet-stream", "MZ")
    post documents_path, params: { file: file }

    assert_redirected_to new_document_path
    assert_match "Unsupported file type", flash[:alert]
  end

  test "create accepts valid upload" do
    log_in_as(@tenant)

    file = build_uploaded_file("ok.txt", "text/plain", "hello world")

    assert_difference("FileDraft.count", 1) do
      post documents_path, params: { file: file }
    end

    assert_redirected_to documents_path
    assert_equal "File uploaded.", flash[:notice]
  end

  test "create rejects file larger than 25mb" do
    log_in_as(@tenant)

    file = build_large_uploaded_file("large.pdf", "application/pdf", 26 * 1024 * 1024)
    post documents_path, params: { file: file }

    assert_redirected_to new_document_path
    assert_equal "File too large (max 25 MB).", flash[:alert]
  end

  test "show returns not found for unknown file" do
    log_in_as(@tenant)

    get view_file_path("missing-file")

    assert_response :not_found
  end

  test "download returns not found for unknown file" do
    log_in_as(@tenant)

    get download_file_path("missing-file")

    assert_response :not_found
  end

  test "view_inline returns not found for unknown file" do
    log_in_as(@tenant)

    get view_inline_document_path("missing-file")

    assert_response :not_found
  end

  test "destroy denies user with no access" do
    log_in_as(@outsider)

    delete document_path(file_drafts(:one).FileID)

    assert_response :forbidden
  end

  test "destroy returns not found when file is missing" do
    log_in_as(@tenant)

    delete document_path("missing-file")

    assert_response :not_found
  end

  test "destroy denies former creator without conversation permission" do
    file = file_drafts(:two)
    former_creator = User.find(file.CreatorID)
    log_in_as(former_creator)
    FileDraft.where(FileID: file.FileID).update_all(CreatorID: @outsider.UserID)
    attributes = FileDraft.find(file.FileID).attributes
    attachments = FileAttachment.where(FileID: file.FileID).pluck(:MessageID)

    delete document_path(file.FileID)

    assert_response :forbidden
    # The login redirect's notice can still be present on this request.
    assert_not_equal "Document deleted.", flash[:notice]
    assert_equal attributes, file.reload.attributes
    assert_equal attachments, FileAttachment.where(FileID: file.FileID).pluck(:MessageID)
  end

  test "creator can destroy document" do
    file = file_drafts(:two)
    log_in_as(@tenant)

    delete document_path(file.FileID)

    assert_redirected_to documents_path
    assert_equal "Document deleted.", flash[:notice]
  end

  test "failed deletion emits no success flash email or broadcast" do
    file = file_drafts(:two)
    log_in_as(@tenant)
    attributes = file.attributes
    attachments = FileAttachment.where(FileID: file.FileID).order(:MessageID).map(&:attributes)
    deletion = DocumentDeletion.new
    DocumentDeletion.stub(:new, deletion) do
      deletion.stub(:call, ->(**) { raise DocumentDeletion::Failure }) do
        ActionCable.server.stub(:broadcast, ->(*) { flunk "failed deletion broadcast success" }) do
          assert_no_enqueued_emails { delete document_path(file.FileID) }
        end
      end
    end
    assert_response :service_unavailable
    # The login redirect's notice can still be present on this request.
    assert_not_equal "Document deleted.", flash[:notice]
    assert_nil file.reload.UserDeletedAt
    assert FileAttachment.exists?(FileID: file.FileID)
    assert_equal attributes, file.attributes
    assert_equal attachments, FileAttachment.where(FileID: file.FileID).order(:MessageID).map(&:attributes)
  end

  test "conversation party retains deletion permission without being creator" do
    file = file_drafts(:one)
    file.update!(CreatorID: @outsider.UserID)
    message = Message.find(FileAttachment.find_by!(FileID: file.FileID).MessageID)
    message.update!(ConversationID: @mediation.ConversationID)
    log_in_as(@tenant)
    delete document_path(file.FileID)
    assert_redirected_to documents_path
    assert file.reload.UserDeletedAt
    assert Message.exists?(MessageID: message.MessageID)
    assert PrimaryMessageGroup.exists?(ConversationID: @mediation.ConversationID)
    assert_empty FileAttachment.where(FileID: file.FileID)
  end

  test "apply signature requires signature name" do
    file = file_drafts(:one)
    log_in_as(@tenant)

    post apply_signature_document_path(file.FileID), params: { signature_name: "" }

    assert_redirected_to view_file_path(file.FileID)
    assert_equal "Please provide your name to sign the document.", flash[:alert]
  end

  test "apply signature blocks unauthorized user" do
    file = file_drafts(:one)
    log_in_as(users(:mediator1))

    post apply_signature_document_path(file.FileID), params: { signature_name: "Not Allowed" }

    assert_redirected_to view_file_path(file.FileID)
    assert_equal "You are not authorized to sign this document.", flash[:alert]
  end

  test "show succeeds for conversation participant" do
    log_in_as(@tenant)

    get view_file_path(file_drafts(:one).FileID)

    assert_response :success
  end

  test "download serves existing physical file" do
    log_in_as(@tenant)
    file = create_stored_file_draft(creator_id: @tenant.UserID, ext: ".txt", content: "download me")

    get download_file_path(file.FileID)

    assert_response :success
    assert_match(/attachment/, response.headers["Content-Disposition"])
  end

  test "view_inline serves existing physical file" do
    log_in_as(@tenant)
    file = create_stored_file_draft(creator_id: @tenant.UserID, ext: ".txt", content: "view me")

    get view_inline_document_path(file.FileID)

    assert_response :success
    assert_match(/inline/, response.headers["Content-Disposition"])
  end

  %w[download_file download_document view_inline_document].each do |route|
    test "#{route} preserves authorized legacy delivery while rejecting unsafe legacy locators" do
      file = create_stored_file_draft(creator_id: @tenant.UserID, ext: ".txt", content: "legacy protected bytes")
      path = Rails.root.join("public", file.FileURLPath)
      begin
        get public_send("#{route}_path", file.FileID)
        assert_redirected_to login_path
        log_in_as(@outsider)
        get public_send("#{route}_path", file.FileID)
        assert_response :not_found
        log_in_as(@tenant)
        get public_send("#{route}_path", file.FileID)
        assert_response :success
        assert_equal "legacy protected bytes", response.body
        assert_match(route == "view_inline_document" ? /inline/ : /attachment/, response.headers["Content-Disposition"])
        assert_includes response.headers["Cache-Control"], "no-store"

        ["userFiles/missing-#{SecureRandom.hex(8)}.txt", "userFiles/../secret.txt",
         "userFiles/%2e%2e.txt", "userFiles/nested/file.txt", "userFiles/a\\b.txt"].each do |locator|
          file.update!(FileURLPath: locator)
          get public_send("#{route}_path", file.FileID)
          assert_response :not_found
          assert_not_includes response.body, Rails.root.to_s
          assert_not_includes response.body, locator
        end
      ensure
        File.delete(path) if path.exist?
      end
    end

    test "#{route} sandboxes untrusted stored HTML without changing bytes or disposition" do
      log_in_as(@tenant)
      html = '<!doctype html><script>parent.document.body.textContent = document.cookie</script><p>Document</p>'
      locator = DocumentStorage.configured.store(io: StringIO.new(html), extension: "html")
      file = FileDraft.create!(CreatorID: @tenant.UserID, FileName: "untrusted", FileTypes: "html", FileURLPath: locator)

      get public_send("#{route}_path", file.FileID)

      assert_response :success
      assert_equal html, response.body
      assert_equal "text/html", response.media_type
      assert_equal "sandbox allow-same-origin", response.headers["Content-Security-Policy"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_match(route == "view_inline_document" ? /inline/ : /attachment/, response.headers["Content-Disposition"])
    end

    test "#{route} preserves native PDF delivery without a CSP sandbox" do
      log_in_as(@tenant)
      pdf = Prawn::Document.new.render
      locator = DocumentStorage.configured.store(io: StringIO.new(pdf), extension: "pdf")
      file = FileDraft.create!(CreatorID: @tenant.UserID, FileName: "preview", FileTypes: "pdf", FileURLPath: locator)

      get public_send("#{route}_path", file.FileID)

      assert_response :success
      assert_equal pdf.b, response.body.b
      assert_equal "application/pdf", response.media_type
      assert_no_match(/\bsandbox\b/, response.headers["Content-Security-Policy"].to_s)
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_match(route == "view_inline_document" ? /inline/ : /attachment/, response.headers["Content-Disposition"])
    end

    test "#{route} delivers private bytes with authenticated noncacheable delivery" do
      log_in_as(@tenant)
      locator = DocumentStorage.configured.store(io: StringIO.new("private delivery bytes"), extension: "txt")
      file = FileDraft.create!(CreatorID: @tenant.UserID, FileName: "private", FileTypes: "txt", FileURLPath: locator)

      get public_send("#{route}_path", file.FileID)

      assert_response :success
      assert_equal "private delivery bytes", response.body
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_match(route == "view_inline_document" ? /inline/ : /attachment/, response.headers["Content-Disposition"])
    end

    test "#{route} authorizes before resolving storage" do
      file = FileDraft.create!(CreatorID: @tenant.UserID, FileName: "private", FileTypes: "txt", FileURLPath: "privateDocuments/missing.txt")
      get public_send("#{route}_path", file.FileID)
      assert_redirected_to login_path

      log_in_as(@outsider)
      DocumentStorage.stub(:configured, -> { flunk "Unauthorized request resolved storage" }) do
        get public_send("#{route}_path", file.FileID)
        assert_response :not_found
      end
      log_in_as(@tenant)
      file.update!(UserDeletedAt: Time.current)
      get public_send("#{route}_path", file.FileID)
      assert_response :not_found
    end

    test "#{route} handles invalid missing empty and unavailable storage without exposing paths" do
      log_in_as(@tenant)
      file = FileDraft.create!(CreatorID: @tenant.UserID, FileName: "private", FileTypes: "txt", FileURLPath: "../secret.txt")
      ["../secret.txt", "privateDocuments/missing.txt"].each do |locator|
        file.update!(FileURLPath: locator)
        get public_send("#{route}_path", file.FileID)
        assert_response :not_found
        assert_not_includes response.body, Rails.root.to_s
      end
      file.update!(FileURLPath: DocumentStorage.configured.store(io: StringIO.new(""), extension: "txt"))
      get public_send("#{route}_path", file.FileID)
      assert_response :unprocessable_entity
      assert_not_includes response.body, @document_storage_root

      DocumentStorage.stub(:configured, -> { raise DocumentStorage::Unavailable, @document_storage_root }) do
        get public_send("#{route}_path", file.FileID)
        assert_response :service_unavailable
        assert_not_includes response.body, @document_storage_root
      end
    end

    test "#{route} preserves historical private conversation access to legacy bytes" do
      build_security_case
      file = build_document_role_overlap("Side")
      legacy = create_stored_file_draft(creator_id: @tenant.UserID, ext: ".txt", content: "historical bytes")
      file.update!(FileURLPath: legacy.FileURLPath)
      @side.update!(deleted_at: Time.current)
      MessageString.find(@side.ConversationID).update!(deleted_at: Time.current)
      @case.update!(deleted_at: Time.current, MediatorID: @other_mediator.UserID, TenantSideConversationID: nil)
      [@tenant, @mediator].each do |user|
        log_in_as(user)
        get public_send("#{route}_path", file.FileID)
        assert_response :success
        assert_equal "historical bytes", response.body
      end
      log_in_as(@other_mediator)
      get public_send("#{route}_path", file.FileID)
      assert_response :not_found
    end

    test "#{route} respects disabled legacy reads" do
      log_in_as(@tenant)
      file = create_stored_file_draft(creator_id: @tenant.UserID, ext: ".txt", content: "legacy bytes")
      Rails.application.config.x.document_storage = DocumentStorageConfiguration.new(
        root: @document_storage_root, public_root: Rails.root.join("public"), legacy_reads_enabled: false
      )
      get public_send("#{route}_path", file.FileID)
      assert_response :not_found
    end
  end

  test "direct legacy HTTP requests deny anonymous and authenticated users despite existing file" do
    middleware = Rails.application.middleware.map(&:klass)
    assert_includes middleware, LegacyDocumentAccessBlocker
    if middleware.include?(ActionDispatch::Static)
      assert_operator middleware.index(LegacyDocumentAccessBlocker), :<, middleware.index(ActionDispatch::Static)
    end
    file = create_stored_file_draft(creator_id: @tenant.UserID, ext: ".txt", content: "direct access forbidden")
    path = Rails.root.join("public", file.FileURLPath)
    begin
      get "/#{file.FileURLPath}"
      assert_response :not_found
      assert_not_includes response.body, "direct access forbidden"
      log_in_as(@tenant)
      get "/#{file.FileURLPath}"
      assert_response :not_found
      assert_not_includes response.body, "direct access forbidden"
      get download_file_path(file.FileID)
      assert_response :success
      assert_equal "direct access forbidden", response.body
    ensure
      File.delete(path) if path.exist?
    end
  end

  test "apply signature succeeds for tenant participant" do
    log_in_as(@tenant)
    file = create_linked_signable_file(conversation_id: @mediation.ConversationID)

    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe" }

    assert_redirected_to view_file_path(file.FileID)
    assert_equal true, file.reload.TenantSignature
    assert_equal "John Doe", file.reload.TenantSignatureName
  end

  %w[a b c].product([false, true], [false, true]).each do |template, legacy, landlord_first|
    test "agreement template #{template} legacy #{legacy} landlord first #{landlord_first} escapes signatures and preserves markup" do
      travel_to Time.zone.local(2026, 11, 5, 12) do
        file = create_agreement_draft(template: template, legacy: legacy)
        metadata = file.attributes.except("FileURLPath", "TenantSignature", "LandlordSignature", "TenantSignedAt", "LandlordSignedAt", "TenantSignatureName", "LandlordSignatureName", "UpdatedAt", "updated_at")
        attachments = file.file_attachments.pluck(:MessageID)
        path = DocumentStorage.configured.resolve(file.FileURLPath)
        original_html = File.read(path)
        original_document = Nokogiri::HTML(original_html)
        names = {
          "Tenant" => %q{Tenant <script>alert("x")</script> & ' \1 \2 \& \` \' \\ &lt;},
          "Landlord" => %q{Landlord <img src=x onerror="alert('x')"> & \1 \2 \& \` \' \\ &amp;}
        }

        names = names.to_a.reverse.to_h if landlord_first
        previous_locator = file.FileURLPath
        names.each do |role, name|
          log_in_as(role == "Tenant" ? @tenant : @landlord)
          post apply_signature_document_path(file.FileID), params: { signature_name: name, agreement_version: 1 }

          assert_redirected_to view_file_path(file.FileID)
          refute_equal previous_locator, file.reload.FileURLPath
          previous_locator = file.FileURLPath
          assert_equal Time.current, file.public_send("#{role}SignedAt")
          assert_equal name, file.reload.public_send("#{role}SignatureName")
          assert_equal true, file.public_send("#{role}Signature")
          assert_equal original_html, File.read(path)
          assert_match(/\AprivateDocuments\//, file.FileURLPath)
          html = DocumentStorage.configured.resolve(file.FileURLPath).read
          assert_includes html, "/s/ #{ERB::Util.html_escape(name)}"
          refute_includes html, name
        end

        signed_document = Nokogiri::HTML(DocumentStorage.configured.resolve(file.FileURLPath).read)
        selectors = { "a" => ".sig-block", "b" => ".signature-block[data-signature-role]", "c" => ".signature-section .signature-line" }
        signature_selectors = { "a" => ".sig-underline", "b" => "span.signature-line", "c" => "span.line" }
        signed_document.css(selectors.fetch(template)).each do |block|
          role = block.text.include?("Landlord") ? "Landlord" : "Tenant"
          assert_equal "/s/ #{names.fetch(role)}", block.at_css(signature_selectors.fetch(template)).text
          assert_includes block.text, "November 05, 2026"
          if template == "b"
            assert_equal names.fetch(role), block.at_css("[data-signature-slot='#{role}-name']").text
          end
        end
        assert_equal metadata, file.attributes.slice(*metadata.keys)
        assert_equal attachments, file.file_attachments.pluck(:MessageID)
        # Only signature text and dates may change; retain all elements and attributes.
        assert_equal original_document.css("*").map { |node| [node.name, node.attributes.transform_values(&:value)] },
          signed_document.css("*").map { |node| [node.name, node.attributes.transform_values(&:value)] }
        restored_html = DocumentStorage.configured.resolve(file.FileURLPath).read
        names.each_value { |name| restored_html.sub!("/s/ #{ERB::Util.html_escape(name)}") { template == "b" ? "___________" : "" } }
        if template == "b"
          names.each do |role, name|
            restored_html.sub!(%Q(data-signature-slot="#{role}-name">#{ERB::Util.html_escape(name)}</span>)) do
              %Q(data-signature-slot="#{role}-name">___________</span>)
            end
          end
        end
        restored_html.gsub!("November 05, 2026", { "a" => "Date", "b" => "___________", "c" => "__________" }.fetch(template))
        assert_equal original_html, restored_html
      end
    end
  end

  %w[missing invalid unreadable legacy_disabled malformed date pdf publication database transformation].each do |failure|
    test "signing #{failure} failure preserves metadata bytes and sends no success events" do
      file = create_agreement_draft(template: "b", legacy: failure == "legacy_disabled")
      storage = DocumentStorage.configured
      source = storage.resolve(file.FileURLPath)
      case failure
      when "missing" then file.update!(FileURLPath: "privateDocuments/absent.html")
      when "invalid" then file.update!(FileURLPath: "../outside.html")
      when "malformed" then source.write(source.read.gsub("___________", "broken"))
      when "date" then source.write(source.read.gsub('class="date-line"', 'class="broken"'))
      when "pdf" then file.update!(FileTypes: "pdf")
      end
      before = file.reload.attributes
      bytes = source.binread
      publications = Dir.children(@document_storage_root).sort
      log_in_as(@tenant)
      request = -> {
        assert_no_enqueued_emails do
          assert_no_difference("Message.count") do
            ActionCable.server.stub(:broadcast, ->(*) { flunk "Failure broadcast success" }) do
              post apply_signature_document_path(file.FileID), params: { signature_name: "Tenant", agreement_version: 1 }
            end
          end
        end
      }
      case failure
      when "publication"
        File.stub(:link, ->(*) { raise Errno::EACCES }) { request.call }
      when "database"
        record = FileDraft.find(file.FileID)
        record.stub(:save!, ->(*) { raise ActiveRecord::RecordInvalid.new(record) }) do
          FileDraft.stub(:find_viewable_by, record) { request.call }
        end
      when "unreadable"
        File.stub(:binread, ->(*) { raise IOError, "Unreadable source" }) { request.call }
      when "legacy_disabled"
        Rails.application.config.x.document_storage = DocumentStorageConfiguration.new(
          root: @document_storage_root, public_root: Rails.root.join("public"), legacy_reads_enabled: false
        )
        request.call
      when "transformation"
        transformer = Object.new
        def transformer.call(*) = raise(AgreementSignature::Invalid)
        AgreementSignature.stub(:new, transformer) { request.call }
      else
        request.call
      end
      assert_redirected_to view_file_path(file.FileID)
      assert_equal "Failed to save signature. Please try again.", flash[:alert]
      assert_equal before, file.reload.attributes
      assert_equal bytes, source.binread
      assert_equal publications, Dir.children(@document_storage_root).sort
    end
  end

  %w[duplicate stale pending outsider mediator admin].each do |rejection|
    test "signing #{rejection} rejection leaves private document unchanged without success events" do
      file = create_agreement_draft
      case rejection
      when "duplicate" then file.update!(TenantSignature: true, TenantSignedAt: Time.current, TenantSignatureName: "Prior")
      when "pending"
        file.update!(AgreementProposal: { base_version: 1, changes: { vacate_date: { decision: "pending" } } }.to_json)
      end
      actor = { "outsider" => @outsider, "mediator" => @mediator, "admin" => users(:admin1) }.fetch(rejection, @tenant)
      log_in_as(actor)
      before = file.reload.attributes
      source = DocumentStorage.configured.resolve(file.FileURLPath)
      bytes = source.binread
      publications = Dir.children(@document_storage_root).sort
      assert_no_enqueued_emails do
        assert_no_difference("Message.count") do
          ActionCable.server.stub(:broadcast, ->(*) { flunk "Rejected signature broadcast success" }) do
            post apply_signature_document_path(file.FileID), params: {
              signature_name: "Signer", agreement_version: rejection == "stale" ? 0 : 1
            }
          end
        end
      end
      assert_nil flash[:success]
      assert_equal before, file.reload.attributes
      assert_equal bytes, source.binread
      assert_equal publications, Dir.children(@document_storage_root).sort
    end
  end

  test "apply signature prevents duplicate tenant signature" do
    log_in_as(@tenant)
    file = create_linked_signable_file(conversation_id: @mediation.ConversationID)
    file.update!(TenantSignature: true, TenantSignatureName: "John Doe", TenantSignedAt: 1.day.ago)

    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe" }

    assert_redirected_to view_file_path(file.FileID)
    assert_equal "You have already signed this document.", flash[:notice]
  end

  test "generate_from_intake creates html file draft" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_from_intake_path(template: "a"), params: {
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "2026-03-20",
        reason: "Nonpayment",
        money_owed: "900"
      }
    end

    assert_redirected_to documents_path
    assert_equal "Document generated successfully.", flash[:notice]
    assert FileDraft.exists?(FileName: "Jane Doe - John Doe - Agree to Vacate")
  end

  test "generate_from_intake handles invalid negotiation date" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_from_intake_path(template: "a"), params: {
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "not-a-date",
        reason: "Nonpayment",
        money_owed: "900"
      }
    end

    assert_redirected_to documents_path
  end

  test "agreement generation allows a payment schedule with a different total" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_from_intake_path(template: "a"), params: agreement_params.merge(amount2: "300")
    end

    assert_redirected_to documents_path
  end

  test "agreement generation allows an empty payment schedule" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_from_intake_path(template: "a"), params: agreement_params.except(
        :amount1, :date1, :amount2, :date2
      )
    end

    assert_redirected_to documents_path
  end

  test "generate_from_intake supports pay and stay template" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_from_intake_path(template: "b"), params: pay_and_stay_params
    end

    assert_redirected_to documents_path
  end

  test "pay and stay validates conditional details before generation" do
    log_in_as(@tenant)

    [
      [{ rental_assistance: "arrangement", assistance_status: "pending" }, /rental assistance provider/],
      [{ existing_eviction_case: "filed" }, /dismissal details/],
      [{ correction_period: "notice", correction_days: "0" }, /valid correction days/],
      [{ additional_terms_selection: "included", review_payment_arrangement: "1" }, /applicable additional terms/]
    ].each do |terms, error|
      assert_no_difference("FileDraft.count") do
        post generate_from_intake_path(template: "b"), params: pay_and_stay_params.merge(terms)
      end
      assert_response :unprocessable_entity
      assert_match error, response.body
    end
  end

  test "pay and stay renders active terms and escapes agreement text" do
    file = create_agreement_draft(template: "b", terms: pay_and_stay_params.merge(
      rental_assistance: "arrangement", assistance_provider: "<script>program</script>",
      assistance_status: "pending", assistance_amount_status: "unknown", assistance_amount: "9999",
      assistance_tenant_steps: "Submit by April 1", assistance_landlord_steps: "No additional steps agreed",
      assistance_pending: "unchanged", assistance_keep_schedule: "1",
      existing_eviction_case: "filed", eviction_court: "Municipal Court", eviction_case_number: "CV-123",
      dismissal_scope: "possession", dismissal_deadline: "April 2, 2026",
      correction_period: "notice", correction_notice_method: "Email", correction_days: "3",
      correction_start: "receipt of notice", additional_terms_selection: "included",
      review_payment_arrangement: "1", payment_review_date: "2026-04-15",
      other_additional_terms: "1", additional_terms: "Review <records>",
      attachments: "Payment schedule"
    ))
    doc = Nokogiri::HTML(DocumentStorage.configured.resolve(file.FileURLPath).read)

    assert_equal (1..8).to_a, doc.css("h3").map { |heading| heading.text.to_i }
    assert_equal "<script>program</script>", doc.at_css('[data-agreement-field="assistance_provider"]').text
    assert_empty doc.css("script, records, [data-agreement-field='assistance_amount']")
    assert doc.at_css('[data-agreement-choice="assistance_keep_schedule"] .checkbox.checked')
    assert_equal "CV-123", doc.at_css('[data-agreement-field="eviction_case_number"]').text
    assert_equal "3", doc.at_css('[data-agreement-field="correction_days"]').text
    assert_equal "Review <records>", doc.at_css('[data-agreement-field="additional_terms"]').text
    assert_equal "Payment schedule", doc.at_css('[data-agreement-field="attachments"]').text
    assert_equal 2, doc.css(".signature-block").length
  end

  test "pay and stay reviews and counteroffers a case selection with its details" do
    file = create_agreement_draft(template: "b")
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: {
      agreement_version: 1, existing_eviction_case: "filed", eviction_court: "Municipal Court",
      eviction_case_number: "CV-123", dismissal_scope: "possession", dismissal_deadline: "April 2, 2026"
    }
    item = file.reload.agreement_suggestion_items.sole
    assert_equal "existing_eviction_case", item[:key]
    assert_equal 5, item[:fields].size

    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_select '#counteroffer_dismissal_scope option[value="entire_case"]'
    counteroffer = item[:fields].to_h { |field| [field, file.agreement_proposal["changes"][field]["to"]] }
    patch counteroffer_document_suggestion_path(file.FileID, item[:key]),
          params: { counteroffer: counteroffer.merge("dismissal_deadline" => "") }, as: :json
    assert_response :unprocessable_entity
    patch counteroffer_document_suggestion_path(file.FileID, item[:key]),
          params: { counteroffer: counteroffer.merge("dismissal_scope" => "entire_case") }, as: :json
    assert_response :success

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal "entire_case", file.reload.agreement_terms["dismissal_scope"]
    assert_equal 2, file.AgreementVersion
    assert_includes DocumentStorage.configured.resolve(file.FileURLPath).read, "CV-123"
  end

  test "pay and stay validates each selected payment option and custom payment row on the server" do
    log_in_as(@tenant)
    invalid_plans = [
      [{ payment_lump_sum: "0" }, /select at least one additional payment option/i],
      [{ lump_sum_date: "" }, /lump sum date/],
      [{ payment_monthly: "1", monthly_payment_amount: "300" }, /monthly payment months/],
      [{ payment_final: "1", final_payment_amount: "50", final_payment_date: "invalid" }, /valid final payment date/],
      [{ payment_custom_schedule: "1" }, /add at least one payment/i],
      [{ payment_custom_schedule: "1", amount1: "100" }, /amount and due date for custom payment 1/],
      [{ payment_custom_schedule: "1", time2: "14:00", amount1: "100", date1: "2026-04-01" }, /custom payment 2/]
    ]
    invalid_plans.each do |terms, error|
      assert_no_difference("FileDraft.count") do
        post generate_from_intake_path(template: "b"), params: pay_and_stay_params.merge(terms)
      end
      assert_response :unprocessable_entity
      assert_select '[data-agreement-editor-error]', text: error
    end
    assert_select 'input[name="time2"][value="14:00"]'
    frame = Nokogiri::HTML(response.body).at_css("iframe[srcdoc]")
    assert_equal "allow-same-origin", frame["sandbox"]
    assert Nokogiri::HTML(frame["srcdoc"]).at_css('[data-agreement-payment-row="2"]')

    file = create_agreement_draft(template: "b", terms: pay_and_stay_params.merge(
      payment_lump_sum: "0", payment_custom_schedule: "1", amount1: "900", date1: "2026-04-01", time1: "14:00"
    ))
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, date1: "", attachments: "Schedule <April>" }
    assert_response :unprocessable_entity
    assert_select '[data-agreement-editor-error]', text: /custom payment 1/
    assert_select 'input[name="date1"][value=""][data-agreement-original="2026-04-01"]'
    assert_select 'input[name="attachments"][value="Schedule <April>"]'
    refute file.reload.agreement_suggestions_pending?
  end

  test "pay and stay requires complete breakdown rows and reconciles amounts exactly" do
    log_in_as(@tenant)
    terms = pay_and_stay_params.merge(
      rent_period: "January and February", rent_owed: "1000.15",
      credits_description: "February payment", credits_amount: "100.10",
      reductions_description: "Agreed reduction", reductions_amount: "0.05"
    )
    post generate_from_intake_path(template: "b"), params: terms.merge(credits_description: "")
    assert_response :unprocessable_entity
    assert_select '[data-agreement-editor-error]', text: /amount and period or description for credits/
    post generate_from_intake_path(template: "b"), params: terms.merge(money_owed: "899.99")
    assert_response :unprocessable_entity
    assert_select '[data-agreement-editor-error]', text: /total agreed payment amount/
    assert_select 'input[name="money_owed"][value="899.99"]'

    file = create_agreement_draft(template: "b", terms: terms)
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, rent_owed: "1050.15" }
    assert_response :unprocessable_entity

    patch update_review_document_path(file.FileID), params: {
      agreement_version: 1, rent_owed: "1050.15", money_owed: "950", lump_sum_amount: "950"
    }
    item = file.reload.agreement_suggestion_items.sole
    assert_equal "payment_agreement", item[:key]
    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal ["1050.15", "950", "950"], file.reload.agreement_terms.values_at("rent_owed", "money_owed", "lump_sum_amount")
  end

  test "pay and stay rejects a 2500 counteroffer against a 2400 total and allows a coordinated counteroffer" do
    file = create_agreement_draft(template: "b", terms: six_payment_pay_and_stay_params)
    original_terms = file.agreement_terms
    original_path = file.FileURLPath
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, date2: "2026-05-02" }
    assert_response :redirect
    proposal = file.reload.agreement_proposal
    item = file.agreement_suggestion_items.sole
    assert_equal "payment_agreement", item[:key]
    offer = proposal["changes"].transform_values { |change| change.fetch("to") }

    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_select '#counteroffer_amount2[value="400"]'
    assert_select '#counteroffer_money_owed[value="2400"]'
    patch counteroffer_document_suggestion_path(file.FileID, item[:key]),
      params: { counteroffer: offer.merge("amount2" => "500") }
    assert_response :unprocessable_entity
    assert_select ".suggestion-save-error", text: /Section 3 payment schedule must add up/
    assert_select '#counteroffer_amount2[value="500"]'
    assert_equal proposal, file.reload.agreement_proposal
    assert_equal original_terms, file.agreement_terms
    assert_equal original_path, file.FileURLPath

    patch counteroffer_document_suggestion_path(file.FileID, item[:key]),
      params: { counteroffer: offer.merge("amount2" => "500", "money_owed" => "2500") }, as: :json
    assert_response :success
    assert_equal original_terms, file.reload.agreement_terms
    log_in_as(@landlord)
    get view_file_path(file.FileID)
    assert_select "#suggestion-payment_agreement strong", text: /Payment 2 amount: \$500/
    assert_select "#suggestion-payment_agreement strong", text: /Amount Owed: \$2500/
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal 2, file.reload.AgreementVersion
    assert_equal %w[2500 500], file.agreement_terms.values_at("money_owed", "amount2")
    html = Nokogiri::HTML(DocumentStorage.configured.resolve(file.FileURLPath).read)
    assert_equal "2500", html.at_css('[data-agreement-field="money_owed"]').text
    assert_equal "500", html.at_css('[data-agreement-field="amount2"]').text
  end

  test "pay and stay rejects a 2500 schedule at submission and again if already pending" do
    file = create_agreement_draft(template: "b", terms: six_payment_pay_and_stay_params)
    original = file.attributes.slice("AgreementTerms", "AgreementVersion", "FileURLPath")
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, amount2: "500" }
    assert_response :unprocessable_entity
    assert_select "[data-agreement-editor-error]", text: /Section 3 payment schedule must add up/
    refute file.reload.agreement_suggestions_pending?

    # Simulate a pending offer saved before cross-section validation was added.
    file.update!(AgreementProposal: JSON.generate(
      base_version: 1, proposer_id: @tenant.UserID, reviewer_id: @landlord.UserID,
      changes: { amount2: { from: "400", to: "500", decision: "pending", group_key: "additional_payments" } }
    ))
    proposal = file.AgreementProposal
    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "additional_payments"), params: { decision: "accepted" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Section 3 payment schedule must add up/, response.parsed_body.fetch("error"))
    assert_equal original, file.reload.attributes.slice(*original.keys)
    assert_equal proposal, file.AgreementProposal
  end

  test "pay and stay reconciles selected payment arrangements with conditional forgiveness" do
    file = create_agreement_draft(template: "b", terms: pay_and_stay_params.merge(
      lump_sum_amount: "100.10", payment_monthly: "1", monthly_payment_amount: "200.20",
      monthly_payment_months: "2", monthly_payment_day: "15", monthly_payment_start: "2026-04-15",
      payment_final: "1", final_payment_amount: "99.50", final_payment_date: "2026-06-15",
      payment_custom_schedule: "1", amount1: "100", date1: "2026-06-01",
      conditional_reduction: "conditional", forgiveness_amount: "200",
      forgiveness_deadline: "2026-06-15", forgiveness_conditions: "Pay on time",
      forgiveness_remaining_amount: "700", forgiveness_failure_result: "Full balance is due"
    ))
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, forgiveness_amount: "250" }
    assert_response :unprocessable_entity
    assert_select "[data-agreement-editor-error]", text: /must equal the Section 2 total minus/

    patch update_review_document_path(file.FileID), params: {
      agreement_version: 1, forgiveness_amount: "250", forgiveness_remaining_amount: "650",
      payment_custom_schedule: "0", final_payment_amount: "149.50"
    }
    assert_response :redirect
    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "payment_agreement"), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal %w[250 650 0 149.50], file.reload.agreement_terms.values_at(
      "forgiveness_amount", "forgiveness_remaining_amount", "payment_custom_schedule", "final_payment_amount"
    )
  end

  test "pay and stay rejects conflicting rental assistance schedules and accepts matching interim payments" do
    log_in_as(@tenant)
    terms = pay_and_stay_params.merge(
      rental_assistance: "arrangement", assistance_provider: "Program", assistance_status: "pending",
      assistance_amount_status: "unknown", assistance_tenant_steps: "Submit by April 1",
      assistance_landlord_steps: "No additional steps agreed", assistance_pending: "other",
      assistance_pending_details: "$900 on 2026-04-15",
      assistance_alternative_schedule: "1", assistance_alternative_details: "$900 on 2026-04-15"
    )
    post generate_from_intake_path(template: "b"), params: terms.merge(assistance_keep_schedule: "1")
    assert_response :unprocessable_entity
    assert_select '[data-agreement-editor-error]', text: /either the Section 3 schedule or an alternative schedule/
    post generate_from_intake_path(template: "b"), params: terms.merge(
      assistance_review: "1", assistance_review_date: "2026-04-10", assistance_review_schedule: "$500 on 2026-04-18"
    )
    assert_response :unprocessable_entity
    assert_select '[data-agreement-editor-error]', text: /matching payment terms/

    file = create_agreement_draft(template: "b", terms: terms.merge(
      assistance_review: "1", assistance_review_date: "2026-04-10", assistance_review_schedule: "$900 on 2026-04-15"
    ))
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, assistance_keep_schedule: "1" }
    assert_response :unprocessable_entity
    refute file.reload.agreement_suggestions_pending?
  end

  test "Pay-and-Stay rejects overlapping pending and delayed payment instructions at generation and review" do
    terms = pay_and_stay_params.merge(
      rental_assistance: "arrangement", assistance_provider: "Program", assistance_status: "pending",
      assistance_amount_status: "unknown", assistance_tenant_steps: "Submit documents",
      assistance_landlord_steps: "Provide ledger", assistance_pending: "unchanged", assistance_keep_schedule: "1"
    )
    file = create_agreement_draft(template: "b", terms: terms)
    conflicting = { assistance_pending: "deferred", assistance_deferral_date: "2026-05-01" }
    assert_no_difference("FileDraft.count") do
      post generate_from_intake_path(template: "b"), params: terms.merge(conflicting)
    end
    assert_response :unprocessable_entity
    assert_select "[data-agreement-editor-error]", text: /both pending and delayed/
    patch update_review_document_path(file.FileID), params: conflicting.merge(agreement_version: 1)
    assert_response :unprocessable_entity
    refute file.reload.agreement_suggestions_pending?

    matching = {
      assistance_pending: "other", assistance_pending_details: "$900 on May 1", assistance_keep_schedule: "0",
      assistance_alternative_schedule: "1", assistance_alternative_details: "$900 on May 1"
    }
    patch update_review_document_path(file.FileID), params: matching.merge(agreement_version: 1)
    assert_response :redirect
    proposal = file.reload.agreement_proposal
    offered = proposal.fetch("changes").transform_values { |change| change.fetch("to") }
    log_in_as(@landlord)
    patch counteroffer_document_suggestion_path(file.FileID, "rental_assistance"),
      params: { counteroffer: offered.merge("assistance_alternative_details" => "$900 on June 1") }, as: :json
    assert_response :unprocessable_entity
    assert_match(/both pending and delayed/, response.parsed_body.fetch("error"))
    assert_equal proposal, file.reload.agreement_proposal

    stale_offer = file.agreement_proposal
    stale_offer["changes"]["assistance_alternative_details"]["to"] = "$900 on June 1"
    file.update!(AgreementProposal: stale_offer.to_json)
    patch decide_document_suggestion_path(file.FileID, "rental_assistance"), params: { decision: "accepted" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/both pending and delayed/, response.parsed_body.fetch("error"))
    assert_equal 1, file.reload.AgreementVersion
    file.update!(AgreementProposal: proposal.to_json)

    patch decide_document_suggestion_path(file.FileID, "rental_assistance"), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal ["$900 on May 1", "$900 on May 1"], file.reload.agreement_terms.values_at(
      "assistance_pending_details", "assistance_alternative_details"
    )

    # A historical schedule remains usable when no Section 4 schedule edit is proposed.
    previous = file.agreement_terms.merge("assistance_alternative_details" => "$900 on June 1")
    file.update!(AgreementTerms: previous.to_json)
    patch update_review_document_path(file.FileID), params: { agreement_version: 2, reason: "March rent" }
    assert_response :redirect
    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "reason"), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal "$900 on June 1", file.reload.agreement_terms["assistance_alternative_details"]
  end

  test "pay and stay reviews payment application choice and instructions in one decision" do
    file = create_agreement_draft(template: "b")
    original = file.agreement_terms
    locator = file.FileURLPath
    changes = { agreement_version: 1, payment_application: "different", payment_application_instructions: "Credit April first" }
    patch update_review_document_path(file.FileID), params: changes
    item = file.reload.agreement_suggestion_items.sole
    assert_equal %w[payment_application payment_application_instructions], item[:fields]

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "rejected" }, as: :json
    assert_response :success
    assert_equal original, file.reload.agreement_terms
    assert_equal locator, file.FileURLPath

    log_in_as(@tenant)
    patch update_review_document_path(file.FileID), params: changes
    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal ["different", "Credit April first"], file.reload.agreement_terms.values_at(*item[:fields])
    assert_includes DocumentStorage.configured.resolve(file.FileURLPath).read, "Credit April first"
  end

  test "editing a checkpoint pay and stay agreement preserves its legal text and signing format" do
    file = create_checkpoint_pay_and_stay_draft
    assert_includes response.body, "Any pending eviction case will be dismissed by the next court date."
    refute_includes response.body, "Dismissal filing deadline:"
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, reason: "Unpaid March rent" }

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "reason"), params: { decision: "accepted" }, as: :json
    assert_response :success
    file.reload
    refute file.revised_pay_and_stay?
    html = DocumentStorage.configured.resolve(file.FileURLPath).read
    assert_includes html, "Unpaid March rent"
    assert_includes html, "Any pending eviction case will be dismissed by the next court date."
    refute_includes html, "Dismissal filing deadline:"

    post apply_signature_document_path(file.FileID), params: { agreement_version: 2, signature_name: "Jane Doe" }
    assert file.reload.LandlordSignature
    assert_includes DocumentStorage.configured.resolve(file.FileURLPath).read, "/s/ Jane Doe"
  end

  [false, true].each do |mediator|
    test "accepted #{mediator ? 'mediator' : 'party'} edits preserve an original Pay-and-Stay document" do
      file = create_agreement_draft(template: "b")
      terms = file.agreement_terms.except("pay_and_stay_draft_version").merge(
        "reason" => "March rent", "lump_sum_amount" => "850", "additional_terms" => "Mail a receipt",
        "rent_owed" => "900"
      )
      file.update!(AgreementTerms: terms.to_json)
      source = DocumentStorage.configured.resolve(file.FileURLPath)
      original = legacy_pay_and_stay_html("original", terms)
      source.binwrite(original)
      get view_inline_document_path(file.FileID, editable_preview: 1)
      assert_response :success
      assert_select "h3", text: "2. Amount Currently Owed"
      assert_select '[data-agreement-field="reason"]', text: "March rent", count: 2

      if mediator
        log_in_as(@mediator)
      else
        post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "John Doe" }
        assert file.reload.TenantSignature
      end
      patch update_review_document_path(file.FileID), params: { agreement_version: 1, reason: "March <rent>" }
      assert_response :redirect
      if mediator
        log_in_as(@tenant)
        patch decide_document_suggestion_path(file.FileID, "reason"), params: { decision: "accepted" }, as: :json
        assert_response :success
        assert_equal original, source.read
      end
      log_in_as(@landlord)
      patch decide_document_suggestion_path(file.FileID, "reason"), params: { decision: "accepted" }, as: :json
      assert_response :success
      revised = DocumentStorage.configured.resolve(file.reload.FileURLPath).read
      assert_equal original.gsub(">March rent<", ">March &lt;rent&gt;<"), revised
      assert_equal original, source.read
      assert_equal terms.merge("reason" => "March <rent>"), file.agreement_terms
      refute file.TenantSignature

      post apply_signature_document_path(file.FileID), params: { agreement_version: 2, signature_name: "Jane Doe" }
      log_in_as(@tenant)
      post apply_signature_document_path(file.FileID), params: { agreement_version: 2, signature_name: "John Doe" }
      assert file.reload.agreement_fully_executed?
    end
  end

  test "an original Pay-and-Stay revision does not replace unrecognized saved wording" do
    file = create_agreement_draft(template: "b")
    terms = file.agreement_terms.except("pay_and_stay_draft_version")
    file.update!(AgreementTerms: terms.to_json)
    html = legacy_pay_and_stay_html("original", terms).sub(
      "<h3>4. Rental Assistance</h3>", "<h3>4. Rental Assistance</h3><p>The parties agreed to a supplemental clause.</p>"
    )
    DocumentStorage.configured.resolve(file.FileURLPath).binwrite(html)
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, reason: "March rent" }
    assert_response :redirect
    original_attributes = file.reload.attributes

    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "reason"), params: { decision: "accepted" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/could not be applied safely/, response.parsed_body.fetch("error"))
    assert_equal original_attributes, file.reload.attributes
    assert_equal html, DocumentStorage.configured.resolve(file.FileURLPath).read
  end

  test "a saved inconsistent Pay-and-Stay cannot receive its first or final signature" do
    file = create_agreement_draft(template: "b", terms: six_payment_pay_and_stay_params)
    terms = file.agreement_terms.merge("amount2" => "500")
    file.update!(AgreementTerms: terms.to_json)
    path = DocumentStorage.configured.resolve(file.FileURLPath)
    path.binwrite(path.read.sub('data-agreement-field="amount2">400', 'data-agreement-field="amount2">500'))
    locator = file.FileURLPath

    assert_no_enqueued_emails do
      post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "John Doe" }
    end
    assert_redirected_to view_file_path(file.FileID)
    assert_match(/cannot be signed.*Section 3 payment schedule/, flash[:alert])
    refute file.reload.TenantSignature
    assert_equal locator, file.FileURLPath

    file.update!(TenantSignature: true)
    log_in_as(@landlord)
    assert_no_enqueued_emails do
      post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "Jane Doe" }
    end
    assert_redirected_to view_file_path(file.FileID)
    assert_match(/cannot be signed.*Section 3 payment schedule/, flash[:alert])
    refute file.reload.LandlordSignature
    refute file.agreement_fully_executed?
    assert_equal locator, file.FileURLPath
  end

  test "sparse Pay-and-Stay payments keep their review numbers when dates are reordered" do
    file = create_agreement_draft(template: "b", terms: pay_and_stay_params.merge(
      payment_lump_sum: "0", payment_custom_schedule: "1",
      amount2: "400", date2: "2026-04-01", amount5: "500", date5: "2026-05-01"
    ))
    get view_inline_document_path(file.FileID)
    assert_equal %w[2 5], Nokogiri::HTML(response.body).css(".custom-payment-schedule tbody tr td:first-child").map(&:text)

    patch update_review_document_path(file.FileID), params: { agreement_version: 1, date5: "2026-03-25", time5: "14:00" }
    assert_response :redirect
    log_in_as(@landlord)
    get view_file_path(file.FileID)
    assert_select "#suggestion-payment_agreement strong", text: "Payment 5 due date: 2026-03-25"
    assert_select "#suggestion-payment_agreement strong", text: "Payment 5 due time: 14:00"
    patch decide_document_suggestion_path(file.FileID, "payment_agreement"), params: { decision: "accepted" }, as: :json
    assert_response :success
    get view_inline_document_path(file.FileID)
    rows = Nokogiri::HTML(response.body).css(".custom-payment-schedule tbody tr")
    assert_equal %w[5 2], rows.map { |row| row.at_css("td").text }
    assert_equal "500", rows.first.at_css('[data-agreement-field="amount5"]').text
    assert_equal "2026-03-25", rows.first.at_css('[data-agreement-field="date5"]').text
  end

  { "omitted" => nil, "blank" => " \n\t ", "None" => "  None\n nOnE \n" }.each do |label, value|
    test "pay and stay with #{label} additional signers has only landlord and tenant signatures" do
      terms = pay_and_stay_params
      terms[:additional_signature_parties] = value unless value.nil?
      file = create_agreement_draft(template: "b", terms: terms)
      assert_equal 2, Nokogiri::HTML(DocumentStorage.configured.resolve(file.FileURLPath).read).css(".signature-block").size

      get view_file_path(file.FileID)
      assert_select "iframe.document-iframe[src=?]", view_inline_document_path(file.FileID)
      get view_inline_document_path(file.FileID)
      assert_response :success
      assert_select ".signature-block", count: 2

      post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "John Doe" }
      log_in_as(@landlord)
      post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "Jane Doe" }
      assert file.reload.agreement_fully_executed?
      get view_file_path(file.FileID)
      assert_select ".completion-banner", count: 1
      get view_inline_document_path(file.FileID)
      assert_response :success
      assert_select ".signature-block", count: 2
      assert_select ".signature-block .signature-line", text: "/s/ Jane Doe"
      assert_select ".signature-block .signature-line", text: "/s/ John Doe"
    end
  end

  test "additional required signatures keep a pay and stay agreement out of completion notifications and summary" do
    file = create_agreement_draft(template: "b")
    terms = file.agreement_terms.merge("additional_signature_parties" => "None\n Alex <Lee>\n\nMorgan Reed")
    file.update!(AgreementTerms: terms.to_json)
    extra_signer_fields = ".signature-block:not([data-signature-role]) p:nth-child(2) .field"
    generated_html = render_pay_and_stay_fixture("pay_and_stay", terms)
    DocumentStorage.configured.resolve(file.FileURLPath).binwrite(generated_html)
    names = ["Alex <Lee>", "Morgan Reed"]
    assert_equal names, Nokogiri::HTML(generated_html).css(extra_signer_fields).map(&:text)

    get view_file_path(file.FileID)
    assert_select "iframe.document-iframe[src=?]", view_inline_document_path(file.FileID)
    get view_inline_document_path(file.FileID)
    assert_response :success
    assert_equal names, Nokogiri::HTML(response.body).css(extra_signer_fields).map(&:text)

    patch update_review_document_path(file.FileID), params: { agreement_version: 1, additional_signature_parties: "" }
    assert_response :unprocessable_entity
    assert_equal terms, file.reload.agreement_terms

    post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "John Doe" }
    assert file.reload.TenantSignature
    log_in_as(@landlord)
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :agreement_notification,
        args: [@tenant, @mediation.ConversationID, "agreement_signed", file.FileID, @landlord] do
        post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "Jane Doe" }
      end
    end
    assert file.reload.LandlordSignature
    refute file.agreement_fully_executed?
    refute Message.where(ConversationID: @mediation.ConversationID).any? { |message| message.Contents.start_with?("Document fully executed:") }
    get view_file_path(file.FileID)
    assert_select ".completion-banner", count: 0
    assert_includes response.body, PayAndStayTerms::ADDITIONAL_SIGNERS_NOTICE
    get view_inline_document_path(file.FileID)
    assert_response :success
    assert_equal names, Nokogiri::HTML(response.body).css(extra_signer_fields).map(&:text)
    assert_equal terms, file.reload.agreement_terms

    @mediation.update_columns(deleted_at: Time.current)
    get mediation_summary_path(@mediation.ConversationID)
    assert_response :success
    assert_select ".signed-documents-list a", text: file.FileName, count: 0
  end

  test "Pay-and-Stay rejects additional required signers in new documents and revisions" do
    log_in_as(@tenant)
    get template_preview_path(template: "b")
    assert_select '[data-agreement-field="additional_signature_parties"]', count: 0
    assert_no_difference("FileDraft.count") do
      post generate_from_intake_path(template: "b"), params: pay_and_stay_params.merge(additional_signature_parties: "Alex Lee")
    end
    assert_response :unprocessable_entity
    assert_select "[data-agreement-editor-error]", text: /only landlord and tenant signatures/
    file = create_agreement_draft(template: "b")
    patch update_review_document_path(file.FileID), params: { agreement_version: 1, additional_signature_parties: "Alex Lee" }
    assert_response :unprocessable_entity
    refute file.reload.agreement_suggestions_pending?
    refute file.additional_pay_and_stay_signers?

    file.update!(AgreementProposal: {
      base_version: 1, proposer_id: @tenant.UserID, reviewer_id: @landlord.UserID,
      changes: { additional_signature_parties: { from: "", to: "Alex Lee", decision: "pending" } }
    }.to_json)
    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "additional_signature_parties"),
      params: { decision: "accepted" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/only landlord and tenant signatures/, response.parsed_body.fetch("error"))
    refute file.reload.additional_pay_and_stay_signers?
  end

  test "pay and stay payment methods round trip as a six option multi-select counteroffer" do
    file = create_agreement_draft(template: "b")
    patch update_review_document_path(file.FileID), params: {
      agreement_version: 1, payment_method: "online_portal, personal_check, money_order", payment_portal_name: "Property portal"
    }
    item = file.reload.agreement_suggestion_items.sole
    assert_equal "payment_method", item[:key]

    log_in_as(@landlord)
    get view_file_path(file.FileID)
    assert_select 'select#counteroffer_payment_method[multiple] option', count: 6
    assert_select 'select#counteroffer_payment_method option[value="personal_check"][selected]'
    assert_select 'select#counteroffer_payment_method option[value="cash"]'
    counteroffer = { payment_method: ["", "cash", "personal_check", "other"], payment_portal_name: "", payment_method_other_description: "" }
    patch counteroffer_document_suggestion_path(file.FileID, item[:key]), params: { counteroffer: counteroffer }
    assert_response :unprocessable_entity
    assert_select ".suggestion-save-error", text: /Describe the other payment method/
    assert_select 'select#counteroffer_payment_method option[value="cash"][selected]'

    patch counteroffer_document_suggestion_path(file.FileID, item[:key]),
          params: { counteroffer: counteroffer.merge(payment_method_other_description: "Bank transfer") }, as: :json
    assert_response :success
    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal "cash,personal_check,other", file.reload.agreement_terms["payment_method"]
    html = Nokogiri::HTML(DocumentStorage.configured.resolve(file.FileURLPath).read)
    assert_equal %w[personal_check cash other], html.css('[data-agreement-choice="payment_method"] .checked').map { |box| box.parent["data-agreement-value"] }
    assert_equal "Bank transfer", html.at_css('[data-agreement-field="payment_method_other_description"]').text
  end

  %w[a c].each do |template|
    test "template #{template} ignores pay and stay fields during creation and review" do
      unrelated = { rental_assistance: "invalid", payment_application: "invalid", additional_signature_parties: "Alex" }
      file = create_agreement_draft(template: template, terms: agreement_params.merge(unrelated))
      assert_empty file.agreement_terms.slice(*unrelated.keys.map(&:to_s))

      # A record previously created by the shared allowlist can still be reviewed.
      file.update!(AgreementTerms: file.agreement_terms.merge(unrelated.stringify_keys).to_json)
      patch update_review_document_path(file.FileID), params: agreement_params.merge(unrelated).merge(
        agreement_version: 1, reason: "Updated reason"
      )
      assert_equal ["reason"], file.reload.agreement_proposal.fetch("changes").keys
      log_in_as(@landlord)
      patch decide_document_suggestion_path(file.FileID, "reason"), params: { decision: "accepted" }, as: :json
      assert_response :success
      assert_equal "Updated reason", file.reload.agreement_terms["reason"]
      refute file.additional_pay_and_stay_signers?
    end
  end

  test "pay and stay prints dismissal terms only for a filed eviction case" do
    file = create_agreement_draft(template: "b")
    html = Nokogiri::HTML(DocumentStorage.configured.resolve(file.FileURLPath).read)
    refute_includes html.text, "Landlord will provide Tenant a copy of the filed dismissal."
    assert_nil html.at_css('[data-agreement-field="dismissal_deadline"]')
    assert html.at_css('.page [data-agreement-choice="correction_period"]')

    get template_preview_path(template: "b")
    assert_select '[data-agreement-field="landlord_representative"][title="Name and capacity"]'
    assert_select '[data-agreement-field="regular_rent_change_details"][title="Amount, due date, and/or duration"]'
    assert_select '[data-agreement-conditional="existing_eviction_case"] [data-agreement-field="dismissal_deadline"]'
    assert_includes response.body, "Additional Payments – Select All That Apply</strong> *"
  end

  test "mediator custom schedule stays grouped through both parties' decisions" do
    file = create_agreement_draft(template: "b")
    log_in_as(@mediator)
    patch update_review_document_path(file.FileID), params: {
      agreement_version: 1, payment_lump_sum: "0", payment_custom_schedule: "1",
      amount1: "900", date1: "2026-04-01", time1: "12:00"
    }
    assert_response :redirect
    item = file.reload.agreement_suggestion_items.sole
    assert_equal "payment_agreement", item[:key]
    assert_includes item[:fields], "amount1"
    assert_includes item[:fields], "date1"
    assert_includes item[:fields], "time1"

    log_in_as(@landlord)
    get view_file_path(file.FileID)
    assert_select '#counteroffer_time1[type="time"][value="12:00"]'
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_nil file.reload.agreement_terms["amount1"]
    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, item[:key]), params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal %w[0 1 900 2026-04-01 12:00], file.reload.agreement_terms.values_at(
      "payment_lump_sum", "payment_custom_schedule", "amount1", "date1", "time1"
    )
  end

  test "a revised pay and stay marker does not change signing for another template" do
    file = create_agreement_draft(template: "a")
    path = DocumentStorage.configured.resolve(file.FileURLPath)
    marker = '<div class="signature-block" data-signature-role="Tenant"></div>'
    path.binwrite(path.binread.sub("</body>", "#{marker}</body>"))
    file.update!(AgreementTerms: file.agreement_terms.merge("pay_and_stay_draft_version" => "1").to_json)

    post apply_signature_document_path(file.FileID), params: { agreement_version: 1, signature_name: "John Doe" }
    assert file.reload.TenantSignature
    html = DocumentStorage.configured.resolve(file.FileURLPath).read
    assert_includes html, "/s/ John Doe"
    assert_includes html, marker
  end

  test "generate_from_intake saves without sharing and returns to conversation" do
    log_in_as(@tenant)

    return_path = message_path(@mediation.ConversationID)

    assert_difference("FileDraft.count", 1) do
      assert_no_difference("Message.count") do
        assert_no_difference("FileAttachment.count") do
          post generate_from_intake_path(template: "a"), params: {
            landlord_name: "Jane Doe",
            tenant_name: "John Doe",
            address: "123 Main Street",
            negotiation_date: "2026-03-20",
            reason: "Nonpayment",
            money_owed: "900",
            conversation_id: @mediation.ConversationID,
            return_to: return_path
          }
        end
      end
    end

    assert_redirected_to return_path

    generated_document = FileDraft.find_by!(FileID: FileDraft.where(CreatorID: @tenant.UserID).order(FileDraft.primary_key => :desc).first.FileID)
    assert_nil generated_document.AgreementConversationID
  end

  test "conversation agreement can be reviewed and signed immediately after reading it" do
    file = create_agreement_draft
    assert file.agreement_document?
    assert_equal @mediation.ConversationID, file.AgreementConversationID

    log_in_as(@landlord)
    get view_file_path(file.FileID)
    assert_response :success
    assert_select "a[href='#{download_file_path(file.FileID)}']", text: /Download/
    assert_select "a[href='#{review_document_path(file.FileID)}']", text: "Suggest Changes"
    assert_select "form[action='#{apply_signature_document_path(file.FileID)}']"
    assert_select "input#sign-document-button[disabled]"
    assert_select "#sign-scroll-hint", text: /Scroll to the bottom/
    assert_operator response.body.index("document-preview-card"), :<, response.body.index("signature-form")

    post apply_signature_document_path(file.FileID), params: { signature_name: "Jane Doe", agreement_version: 1 }
    assert file.reload.LandlordSignature

    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_response :success
    assert_select "form[action='#{apply_signature_document_path(file.FileID)}']"
    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe", agreement_version: 1 }
    assert file.reload.TenantSignature
    assert file.LandlordSignature
    get view_file_path(file.FileID)
    assert_select "form[action='#{apply_signature_document_path(file.FileID)}']", count: 0
    assert_select "a[href='#{review_document_path(file.FileID)}']", count: 0
  end

  test "stored agreement HTML is sandboxed while editable preview renders escaped saved terms" do
    file = create_agreement_draft
    stored_html = '<!doctype html><script>parent.document.body.remove()</script><p>Stored bytes</p>'
    File.write(DocumentStorage.configured.resolve(file.FileURLPath), stored_html)
    terms = file.agreement_terms.merge("additional_terms" => '<script>alert("saved term")</script>')
    file.update!(AgreementTerms: JSON.generate(terms))
    log_in_as(@landlord)

    get view_inline_document_path(file.FileID)
    assert_response :success
    assert_equal stored_html, response.body
    assert_equal "sandbox allow-same-origin", response.headers["Content-Security-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]

    get view_file_path(file.FileID, edit: 1)
    assert_response :success
    assert_select "[data-agreement-editor]"
    assert_select "iframe[src='#{view_inline_document_path(file.FileID, editable_preview: 1)}']"

    get view_inline_document_path(file.FileID, editable_preview: 1)
    assert_response :success
    assert_no_match(/\bsandbox\b/, response.headers["Content-Security-Policy"].to_s)
    assert_select "[data-agreement-field='vacate_date']"
    assert_includes response.body, ERB::Util.html_escape(terms["additional_terms"])
    assert_not_includes response.body, stored_html
    assert_select "script", count: 0
  end

  test "accepted suggestions update the document immediately while remaining suggestions stay pending" do
    file = create_agreement_draft
    log_in_as(@landlord)
    get review_document_path(file.FileID)
    assert_redirected_to view_file_path(file.FileID, edit: 1)
    get view_file_path(file.FileID, edit: 1)
    assert_response :success
    assert_select "[data-agreement-editor]"
    assert_select "input[name='amount2'][value='400']"
    assert_select "input[name='date2'][value='2026-04-30']"
    assert_select "[data-agreement-finish][disabled]", count: 1
    get view_inline_document_path(file.FileID, editable_preview: 1)
    assert_response :success
    assert_select "[data-agreement-field='vacate_date']"
    assert_select "[data-agreement-payment-row='2']"

    post apply_signature_document_path(file.FileID), params: { signature_name: "Jane Doe", agreement_version: 1 }
    assert file.reload.LandlordSignature
    original_html = File.read(DocumentStorage.configured.resolve(file.FileURLPath))

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15", amount2: "400", date2: "2026-05-15"
    )
    assert_redirected_to view_file_path(file.FileID)
    assert_equal 1, file.reload.AgreementVersion
    assert file.LandlordSignature
    assert file.agreement_suggestions_pending?
    assert_equal "2026-04-30", file.agreement_terms["date2"]
    assert_equal original_html, File.read(DocumentStorage.configured.resolve(file.FileURLPath))
    assert_equal 1, file.file_attachments.count
    assert_equal 0, Message.order(:MessageID).last.file_attachments.count

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-06-01"
    )
    assert_equal "2026-05-15", file.reload.agreement_proposal["changes"]["vacate_date"]["to"]

    patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }
    assert file.reload.agreement_suggestions_pending?
    assert_equal "pending", file.agreement_proposal["changes"]["vacate_date"]["decision"]
    assert_equal 1, file.AgreementVersion

    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_select ".agreement-suggestions-card .suggestion-item", count: 2
    assert_select "form[action='#{apply_signature_document_path(file.FileID)}']", count: 0
    assert_select "form[action='#{decide_document_suggestion_path(file.FileID, 'date2')}']", count: 2
    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe", agreement_version: 1 }
    assert_not file.reload.TenantSignature
    assert_match(/Suggested changes must be accepted or rejected/, flash[:alert])

    patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }
    assert_redirected_to view_file_path(file.FileID, anchor: "suggestion-vacate_date")
    assert file.reload.agreement_suggestions_pending?
    assert_equal 2, file.AgreementVersion
    assert_equal 2, file.agreement_proposal["base_version"]
    assert_not file.LandlordSignature
    assert_equal "2026-05-15", file.agreement_terms["vacate_date"]
    assert_equal "2026-04-30", file.agreement_terms["date2"]
    assert_not_equal original_html, File.read(DocumentStorage.configured.resolve(file.FileURLPath))
    assert_equal "Landlord Jane Doe suggested changes to the agreement. Review the document to see them.", Message.order(:MessageID).last.Contents
    patch decide_document_suggestion_path(file.FileID, "date2"), params: { decision: "rejected" }
    assert_redirected_to view_file_path(file.FileID, anchor: "suggestion-date2")
    assert_equal 2, file.reload.AgreementVersion
    assert_not file.agreement_suggestions_pending?
    assert_not file.LandlordSignature
    assert_nil file.LandlordSignedAt
    assert_equal "2026-05-15", file.agreement_terms["vacate_date"]
    assert_equal "2026-04-30", file.agreement_terms["date2"]
    assert_not_equal original_html, File.read(DocumentStorage.configured.resolve(file.FileURLPath))
    revision_message = Message.order(:MessageID).last
    assert_equal "Agreement revised to version 2 by Tenant John Doe. Please review the new terms.", revision_message.Contents
    assert_equal 0, revision_message.file_attachments.count

    patch decide_document_suggestion_path(file.FileID, "date2"), params: { decision: "accepted" }
    assert_equal 2, file.reload.AgreementVersion

    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe", agreement_version: 1 }
    assert_not file.reload.TenantSignature
    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe", agreement_version: 2 }
    assert file.reload.TenantSignature
  end

  test "suggestion decisions can save without navigating away from the review" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15", date2: "2026-05-15"
    )

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
      params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal({ "status" => "updated", "field" => "vacate_date", "decision" => "accepted" }, response.parsed_body)
    assert_equal 2, file.reload.AgreementVersion
    assert file.agreement_suggestions_pending?

    get view_file_path(file.FileID)
    assert_select "#suggestion-vacate_date .suggestion-actions", count: 0
    assert_select "#suggestion-date2 .suggestion-actions", count: 1
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
      params: { decision: "rejected" }, as: :json
    assert_response :conflict
    assert_equal "accepted", file.reload.agreement_proposal["changes"]["vacate_date"]["decision"]

    patch decide_document_suggestion_path(file.FileID, "date2"),
      params: { decision: "rejected" }, as: :json
    assert_response :success
    assert_equal({ "status" => "rejected", "field" => "date2", "decision" => "rejected" }, response.parsed_body)
    assert_equal 2, file.reload.AgreementVersion
    assert_not file.agreement_suggestions_pending?
  end

  test "payment suggestions can be accepted and rejected independently of amount owed" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, money_owed: "1000", amount1: "600"
    )
    assert file.reload.agreement_suggestions_pending?

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "money_owed"), params: { decision: "accepted" }
    patch decide_document_suggestion_path(file.FileID, "amount1"), params: { decision: "rejected" }
    assert_equal 2, file.reload.AgreementVersion
    assert_not file.agreement_suggestions_pending?
    assert_equal "1000", file.agreement_terms["money_owed"]
    assert_equal "500", file.agreement_terms["amount1"]
  end

  test "payment amount and removed due date suggestions render on signing page" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount1: "600", date2: ""
    )

    get view_file_path(file.FileID)
    assert_response :success
    assert_select ".agreement-suggestions-card .suggestion-item", count: 2
    assert_select ".suggestion-item", text: /Payment 1 amount/
    assert_select ".suggestion-item", text: /Payment 2 due date/
    assert_select ".suggestion-item", text: /Not set/

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "amount1"), params: { decision: "accepted" }
    patch decide_document_suggestion_path(file.FileID, "date2"), params: { decision: "accepted" }
    assert_equal 3, file.reload.AgreementVersion
    assert_equal "900", file.agreement_terms["money_owed"]
    assert_equal "600", file.agreement_terms["amount1"]
    assert_nil file.agreement_terms["date2"]
  end

  test "removing a whole payment is one suggestion and one decision" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount1: "", date1: ""
    )

    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_response :success
    assert_select ".agreement-suggestions-card .suggestion-item", count: 1
    assert_select "#suggestion-payment1", text: /Payment 1 removed/
    assert_select "#suggestion-payment1", text: /\$500/
    assert_select "#suggestion-payment1", text: /2026-03-30/
    assert_select "form[action='#{decide_document_suggestion_path(file.FileID, 'payment1')}']", count: 2

    patch decide_document_suggestion_path(file.FileID, "payment1"), params: { decision: "accepted" }
    assert_redirected_to view_file_path(file.FileID, anchor: "suggestion-payment1")
    assert_equal 2, file.reload.AgreementVersion
    assert_nil file.agreement_terms["amount1"]
    assert_nil file.agreement_terms["date1"]
    assert_not file.agreement_suggestions_pending?
  end

  test "rejecting a whole payment removal keeps its amount and due date" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount1: "", date1: ""
    )

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "payment1"), params: { decision: "rejected" }
    assert_redirected_to view_file_path(file.FileID, anchor: "suggestion-payment1")
    assert_equal 1, file.reload.AgreementVersion
    assert_equal "500", file.agreement_terms["amount1"]
    assert_equal "2026-03-30", file.agreement_terms["date1"]
    assert_not file.agreement_suggestions_pending?
  end

  test "adding a payment is one decision and a date cannot be accepted without an amount" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount3: "250", date3: "2026-06-01"
    )
    assert file.reload.agreement_suggestions_pending?

    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_select ".agreement-suggestions-card .suggestion-item", count: 1
    assert_select "#suggestion-payment3", text: /Payment 3 added/
    assert_select "#suggestion-payment3", text: /\$250/
    assert_select "#suggestion-payment3", text: /2026-06-01/
    patch decide_document_suggestion_path(file.FileID, "date3"), params: { decision: "accepted" }, as: :json
    assert_response :conflict
    patch decide_document_suggestion_path(file.FileID, "payment3"), params: { decision: "accepted" }
    assert_equal 2, file.reload.AgreementVersion
    assert_equal "250", file.agreement_terms["amount3"]
    assert_equal "2026-06-01", file.agreement_terms["date3"]
    assert_includes File.read(DocumentStorage.configured.resolve(file.FileURLPath)), "data-agreement-payment-row=\"3\""
  end

  test "a date-only payment suggestion is refused while the schedule remains optional" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, date3: "2026-06-01"
    )
    assert_redirected_to view_file_path(file.FileID, edit: 1)
    assert_not file.reload.agreement_suggestions_pending?
    assert_nil file.agreement_terms["amount3"]

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount3: "250"
    )
    assert file.reload.agreement_suggestions_pending?
    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "payment3"), params: { decision: "accepted" }
    assert_equal "250", file.reload.agreement_terms["amount3"]
    assert_nil file.agreement_terms["date3"]
  end

  test "an older split payment offer cannot accept a date without its amount" do
    file = create_agreement_draft
    proposal = { "base_version" => 1, "proposer_id" => @landlord.UserID,
                 "reviewer_id" => @tenant.UserID,
                 "changes" => {
                   "amount3" => { "from" => "", "to" => "250", "decision" => "rejected" },
                   "date3" => { "from" => "", "to" => "2026-06-01", "decision" => "pending" }
                 } }
    file.update!(AgreementProposal: JSON.generate(proposal))

    patch decide_document_suggestion_path(file.FileID, "date3"),
      params: { decision: "accepted" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/payment date needs a payment amount/, response.parsed_body["error"])
    assert_equal 1, file.reload.AgreementVersion
    assert_nil file.agreement_terms["date3"]
    assert_equal "pending", file.agreement_proposal["changes"]["date3"]["decision"]
  end

  test "rejecting every suggestion keeps the agreement and signatures" do
    file = create_agreement_draft
    log_in_as(@landlord)
    post apply_signature_document_path(file.FileID), params: { signature_name: "Jane Doe", agreement_version: 1 }
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15"
    )

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "rejected" }
    assert_equal 1, file.reload.AgreementVersion
    assert file.LandlordSignature
    assert_not file.agreement_suggestions_pending?
    assert_equal "2026-05-01", file.agreement_terms["vacate_date"]
  end

  test "counteroffer transfers an individual suggestion back without changing other decisions" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15", amount2: "450"
    )
    assert file.reload.agreement_suggestions_pending?

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "amount2"), params: { decision: "rejected" }
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-20" } }, as: :json
    assert_response :success
    assert_equal "countered", response.parsed_body["status"]
    proposal = file.reload.agreement_proposal
    assert_equal "rejected", proposal["changes"]["amount2"]["decision"]
    assert_equal "2026-05-20", proposal["changes"]["vacate_date"]["to"]
    assert_equal @tenant.UserID, proposal["changes"]["vacate_date"]["offered_by_id"]
    assert_equal 1, file.AgreementVersion
    assert file.agreement_suggestions_pending?

    get view_file_path(file.FileID)
    assert_select "#suggestion-vacate_date", text: /Offered by Tenant/
    assert_select "#suggestion-vacate_date .suggestion-counteroffer-toggle", count: 0

    patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }, as: :json
    assert_response :conflict
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-22" } }, as: :json
    assert_response :unprocessable_entity

    log_in_as(@landlord)
    get view_file_path(file.FileID)
    assert_select "#suggestion-vacate_date .suggestion-counteroffer-toggle", count: 1
    assert_select "#counteroffer-vacate_date.suggestion-counteroffer-panel[hidden]", count: 1
    assert_select "#counteroffer-vacate_date .suggestion-counteroffer-form", count: 1
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
          params: { counteroffer: { vacate_date: "2026-05-20" } }
    assert_redirected_to view_file_path(file.FileID, counteroffer_error: "vacate_date", anchor: "suggestion-vacate_date")
    follow_redirect!
    assert_select "#counteroffer-vacate_date:not([hidden]) .suggestion-save-error", text: "Enter a different value for this counteroffer."
    patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }
    assert_equal 2, file.reload.AgreementVersion
    assert_equal "2026-05-20", file.agreement_terms["vacate_date"]
    assert_equal "400", file.agreement_terms["amount2"]
  end

  test "a counteroffer to a removed payment stays one suggestion" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount1: "", date1: ""
    )
    log_in_as(@tenant)
    patch counteroffer_document_suggestion_path(file.FileID, "payment1"),
          params: { counteroffer: { amount1: "550", date1: "2026-04-05" } }, as: :json
    assert_response :success
    item = file.reload.agreement_suggestion_items.find { |suggestion| suggestion[:key] == "payment1" }
    assert_equal %w[amount1 date1], item[:fields]
    assert_equal false, item[:removed_payment]
    assert_equal @tenant.UserID, item[:offered_by_id]
    assert_equal 1, file.AgreementVersion
  end

  test "counteroffers and accepted decisions update the agreement one item at a time" do
    file = create_agreement_draft
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15", date2: "2026-05-15",
      money_owed: "950", amount1: "600"
    )
    initial_messages = Message.where(ConversationID: @mediation.ConversationID).count

    log_in_as(@landlord)
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
      params: { counteroffer: { vacate_date: "2026-05-20" } }, as: :json
    assert_response :success
    patch counteroffer_document_suggestion_path(file.FileID, "date2"),
      params: { counteroffer: { date2: "2026-05-25" } }, as: :json
    assert_response :success
    assert_equal false, response.parsed_body["round_complete"]
    assert_equal initial_messages, Message.where(ConversationID: @mediation.ConversationID).count
    assert_equal "2026-05-15", file.reload.agreement_proposal["changes"]["vacate_date"]["to"]
    assert_equal @landlord.UserID, file.agreement_proposal["reviewer_id"]
    assert_equal "2026-05-20", file.agreement_proposal["draft_counteroffers"]["vacate_date"]["vacate_date"]
    get view_file_path(file.FileID)
    assert_select "#suggestion-vacate_date .suggestion-actions", count: 0
    assert_select "#suggestion-vacate_date .suggestion-review-note", text: "Decision recorded. This item is closed."
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
      params: { decision: "accepted" }, as: :json
    assert_response :conflict
    patch counteroffer_document_suggestion_path(file.FileID, "vacate_date"),
      params: { counteroffer: { vacate_date: "2026-05-21" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal "2026-05-20", file.reload.agreement_proposal["draft_counteroffers"]["vacate_date"]["vacate_date"]
    log_in_as(@tenant)
    get view_file_path(file.FileID)
    assert_select "#suggestion-vacate_date .suggestion-actions", count: 0
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
      params: { decision: "accepted" }, as: :json
    assert_response :conflict
    log_in_as(@landlord)
    patch decide_document_suggestion_path(file.FileID, "money_owed"),
      params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal "updated", response.parsed_body["status"]
    assert_equal 2, file.reload.AgreementVersion
    assert_equal "950", file.agreement_terms["money_owed"]
    assert_equal "500", file.agreement_terms["amount1"]
    assert file.agreement_suggestions_pending?
    assert_equal initial_messages, Message.where(ConversationID: @mediation.ConversationID).count
    patch decide_document_suggestion_path(file.FileID, "amount1"),
      params: { decision: "rejected" }, as: :json
    assert_response :success
    assert_equal "rejected", response.parsed_body["status"]
    assert_equal 2, file.reload.AgreementVersion
    assert file.agreement_suggestions_pending?
    assert_equal initial_messages + 1, Message.where(ConversationID: @mediation.ConversationID).count
    assert_equal @tenant.UserID, file.agreement_proposal["reviewer_id"]
    assert_nil file.agreement_proposal["draft_counteroffers"]
    assert_equal "2026-05-20", file.agreement_proposal["changes"]["vacate_date"]["to"]

    get view_file_path(file.FileID)
    assert_select "#suggestion-money_owed .suggestion-actions", count: 0
    assert_select "#suggestion-amount1 .suggestion-actions", count: 0
    patch decide_document_suggestion_path(file.FileID, "money_owed"),
      params: { decision: "rejected" }, as: :json
    assert_response :conflict
    assert_equal "accepted", file.reload.agreement_proposal["changes"]["money_owed"]["decision"]

    log_in_as(@tenant)
    patch decide_document_suggestion_path(file.FileID, "vacate_date"),
      params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal 3, file.reload.AgreementVersion
    assert_equal "2026-05-20", file.agreement_terms["vacate_date"]
    assert_equal "2026-04-30", file.agreement_terms["date2"]
    assert file.agreement_suggestions_pending?
    assert_equal initial_messages + 1, Message.where(ConversationID: @mediation.ConversationID).count
    patch decide_document_suggestion_path(file.FileID, "date2"),
      params: { decision: "accepted" }, as: :json
    assert_response :success
    assert_equal 4, file.reload.AgreementVersion
    assert_not file.agreement_suggestions_pending?
    assert_equal "2026-05-20", file.agreement_terms["vacate_date"]
    assert_equal "2026-05-25", file.agreement_terms["date2"]
    assert_equal "950", file.agreement_terms["money_owed"]
    assert_equal "500", file.agreement_terms["amount1"]
    assert_equal initial_messages + 2, Message.where(ConversationID: @mediation.ConversationID).count
  end

  test "unmatched payment suggestion keeps the signed document unchanged until reviewed" do
    file = create_agreement_draft
    unsigned_locator = file.FileURLPath
    log_in_as(@landlord)
    post apply_signature_document_path(file.FileID), params: { signature_name: "Jane Doe", agreement_version: 1 }
    assert_redirected_to view_file_path(file.FileID)

    # Signing publishes a new private revision; capture that revision after reloading.
    file.reload
    signed_locator = file.FileURLPath
    assert_not_equal unsigned_locator, signed_locator
    assert_match(/\AprivateDocuments\//, signed_locator)
    assert file.LandlordSignature
    assert_not file.TenantSignature
    assert_equal "Jane Doe", file.LandlordSignatureName
    assert_not_nil file.LandlordSignedAt
    signed_html = File.binread(DocumentStorage.configured.resolve(signed_locator))
    assert_includes signed_html, "/s/ Jane Doe"
    assert_includes signed_html, file.LandlordSignedAt.strftime("%B %d, %Y")
    signature_metadata = file.attributes.slice(
      "LandlordSignature", "TenantSignature", "LandlordSignedAt", "TenantSignedAt",
      "LandlordSignatureName", "TenantSignatureName"
    )
    signed_version = file.AgreementVersion
    assert_equal 1, signed_version

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount2: "300"
    )

    assert_redirected_to view_file_path(file.FileID)
    assert_equal signed_version, file.reload.AgreementVersion
    assert_equal signed_locator, file.FileURLPath
    assert_equal signature_metadata, file.attributes.slice(*signature_metadata.keys)
    assert file.agreement_suggestions_pending?
    assert_equal signed_html, File.binread(DocumentStorage.configured.resolve(file.FileURLPath))
  end

  test "unrelated users cannot revise an agreement" do
    file = create_agreement_draft
    log_in_as(@outsider)
    get review_document_path(file.FileID)
    assert_response :not_found
    get view_inline_document_path(file.FileID, editable_preview: 1)
    assert_response :not_found
    patch update_review_document_path(file.FileID), params: agreement_params.merge(agreement_version: 1)
    assert_response :not_found
    patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }
    assert_response :not_found
    assert file.reload.agreement_document?
  end

  test "unrelated users cannot publish a draft into another conversation" do
    log_in_as(@outsider)
    assert_no_difference("FileDraft.count") do
      post generate_from_intake_path(template: "a"), params: agreement_params.merge(conversation_id: @mediation.ConversationID)
    end
    assert_response :forbidden
  end

  test "pay and stay review retains selected payment plan details" do
    log_in_as(@tenant)
    post generate_from_intake_path(template: "b"), params: pay_and_stay_params.merge(
      conversation_id: @mediation.ConversationID, payment_lump_sum: "0", payment_monthly: "1",
      monthly_payment_amount: "300", monthly_payment_months: "3",
      monthly_payment_day: "15", monthly_payment_start: "2026-04-01",
      payment_method: "money_order"
    )
    file = FileDraft.where(
      CreatorID: @tenant.UserID,
      AgreementTemplate: "b"
    ).order(FileDraft.primary_key => :desc).first!

    # Share the generated agreement before testing the review workflow.
    post messages_path, params: {
      ConversationID: @mediation.ConversationID,
      Contents: "Agreement shared for review",
      file_id: file.FileID
    }

    assert FileAttachment.exists?(FileID: file.FileID)
    assert_equal @mediation.ConversationID, file.reload.agreement_conversation_id

    log_in_as(@landlord)
    get review_document_path(file.FileID)
    assert_redirected_to view_file_path(file.FileID, edit: 1)
    get view_file_path(file.FileID, edit: 1)
    assert_response :success
    assert_select "input[name='payment_monthly'][value='1']"
    assert_select "input[name='monthly_payment_day'][value='15']"
    assert_select "input[name='payment_method'][value='money_order']"

    patch update_review_document_path(file.FileID), params: { agreement_version: 1, monthly_payment_day: "16" }

    item = file.reload.agreement_suggestion_items.sole
    assert_equal "payment_agreement", item[:key]
    assert_equal "16", file.agreement_proposal.dig("changes", "monthly_payment_day", "to")
    assert_includes item[:fields], "monthly_payment_start"
  end

  test "agreements without a conversation do not enter the review workflow" do
    log_in_as(@tenant)
    post generate_from_intake_path(template: "a"), params: agreement_params
    file = FileDraft.where(CreatorID: @tenant.UserID, FileTypes: "html").order(Arel.sql("[CreatedAt] DESC")).first
    assert_equal "a", file.AgreementTemplate
    assert_nil file.agreement_conversation_id
    assert_not file.agreement_signable?
  end

  test "sending a generated agreement from the chat attaches it and starts review" do
    activate_mediation(@mediation)
    log_in_as(@tenant)
    post generate_from_intake_path(template: "a"), params: agreement_params
    file = FileDraft.where(CreatorID: @tenant.UserID, FileTypes: "html").order(Arel.sql("[CreatedAt] DESC")).first

    assert_difference("Message.count", 1) do
      post messages_path, params: { ConversationID: @mediation.ConversationID,
                                    Contents: "", file_id: file.FileID }
    end
    assert_redirected_to message_path(@mediation.ConversationID)
    assert_equal @mediation.ConversationID, file.reload.agreement_conversation_id
    assert file.agreement_document?
    assert FileAttachment.exists?(FileID: file.FileID)

    get message_path(@mediation.ConversationID)
    assert_response :success
    assert_select "a", text: "Review & Sign"
  end

  test "generate_filled_template creates pdf file draft" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_filled_template_path, params: {
        template: "a",
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "2026-03-20",
        reason: "Nonpayment",
        money_owed: "900",
        best_option: "Move Out",
        amount1: "900",
        date1: "2026-03-30"
      }
    end

    assert_redirected_to documents_path
    assert_equal "Document generated.", flash[:notice]
    assert FileDraft.exists?(FileName: "Jane Doe - John Doe - Agree to Vacate", FileTypes: "pdf")
  end

  test "legacy pay and stay generation opens the current agreement editor" do
    log_in_as(@tenant)

    assert_no_difference("FileDraft.count") do
      post generate_filled_template_path, params: { template: "b", conversation_id: @mediation.ConversationID }
    end

    assert_response :see_other
    assert_redirected_to template_intake_path(template: "b", conversation_id: @mediation.ConversationID)
  end

  test "generate_filled_template supports mediation template" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_filled_template_path, params: {
        template: "c",
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "2026-03-20",
        reason: "Nonpayment",
        money_owed: "900",
        monthly_rent: "1200",
        best_option: "Payment Plan",
        amount1: "300",
        date1: "2026-03-30"
      }
    end

    assert_redirected_to documents_path
  end

  %w[upload html pdf].each do |workflow|
    test "#{workflow} creation publishes private bytes without public files" do
      log_in_as(@tenant)
      legacy_files = Dir.glob(Rails.root.join("public", "userFiles", "*"))
      assert_difference("FileDraft.count", 1) { perform_creation(workflow) }
      locator = "privateDocuments/#{File.basename(Dir.glob(File.join(@document_storage_root, "*")).sole)}"
      file = FileDraft.find_by(FileURLPath: locator)
      assert file
      bytes = File.binread(DocumentStorage.configured.resolve(file.FileURLPath))
      case workflow
      when "upload" then assert_equal "private upload bytes", bytes
      when "html" then assert_includes bytes, "Jane Doe"
      when "pdf" then assert bytes.start_with?("%PDF-")
      end
      assert_equal legacy_files, Dir.glob(Rails.root.join("public", "userFiles", "*"))
      assert_redirected_to documents_path
    end

    test "#{workflow} creation handles unavailable storage without database records" do
      log_in_as(@tenant)
      FileUtils.remove_entry(@document_storage_root)
      assert_no_difference(["FileDraft.count", "Message.count", "FileAttachment.count"]) do
        perform_creation(workflow)
      end
      assert_response :service_unavailable
      assert_equal "Unable to create document. Please try again.", response.body
    end

    test "#{workflow} creation removes published bytes when database persistence fails" do
      log_in_as(@tenant)
      FileDraft.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid.new(FileDraft.new) }) do
        assert_no_difference(["FileDraft.count", "Message.count", "FileAttachment.count"]) do
          perform_creation(workflow)
        end
      end
      assert_response :service_unavailable
      assert_empty Dir.children(@document_storage_root)
    end
  end

  test "HTML agreement generation saves a private document without sharing" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      assert_no_difference("Message.count") do
        assert_no_difference("FileAttachment.count") do
          post generate_from_intake_path(template: "a"),
              params: agreement_params.merge(
                conversation_id: @mediation.ConversationID
              )
        end
      end
    end

    assert_redirected_to documents_path

    file = FileDraft.where(
      CreatorID: @tenant.UserID,
      AgreementTemplate: "a"
    ).order(FileDraft.primary_key => :desc).first!

    assert_nil file.AgreementConversationID
    assert_empty file.messages
    assert_match(/\AprivateDocuments\//, file.FileURLPath)
    assert_includes File.read(DocumentStorage.configured.resolve(file.FileURLPath)), "Jane Doe"
  end

  test "HTML agreement generation succeeds without creating a chat attachment" do
    log_in_as(@tenant)

    FileAttachment.stub(:create!, ->(*) {
      raise ActiveRecord::RecordInvalid.new(FileAttachment.new)
    }) do
      assert_difference("FileDraft.count", 1) do
        assert_no_difference("Message.count") do
          assert_no_difference("FileAttachment.count") do
            post generate_from_intake_path(template: "a"),
                params: agreement_params.merge(
                  conversation_id: @mediation.ConversationID
                )
          end
        end
      end
    end

    assert_redirected_to documents_path

    file = FileDraft.where(
      CreatorID: @tenant.UserID,
      AgreementTemplate: "a"
    ).order(FileDraft.primary_key => :desc).first!

    assert_nil file.AgreementConversationID
    assert File.exist?(DocumentStorage.configured.resolve(file.FileURLPath))
  end

  test "PDF generation failure leaves no file or record" do
    log_in_as(@tenant)
    Prawn::Document.stub(:generate, ->(*) { raise IOError, "private generator details" }) do
      assert_no_difference("FileDraft.count") { perform_creation("pdf") }
    end
    assert_response :service_unavailable
    assert_empty Dir.children(@document_storage_root)
    assert_not_includes response.body, "private generator details"
  end

  test "creation handles invalid storage configuration without exposing paths" do
    log_in_as(@tenant)
    Rails.application.config.x.document_storage = DocumentStorageConfiguration.new(
      root: Rails.root.join("public", "invalid-private-root"), public_root: Rails.root.join("public")
    )
    assert_no_difference("FileDraft.count") { perform_creation("upload") }
    assert_response :service_unavailable
    assert_not_includes response.body, Rails.root.to_s
  end

  test "creation persists the completed locator after staging cleanup failure" do
    log_in_as(@tenant)
    with_publication_cleanup_failure do
      assert_difference("FileDraft.count", 1) { perform_creation("upload") }
    end
    assert_redirected_to documents_path
    locator = "privateDocuments/#{File.basename(Dir.glob(File.join(@document_storage_root, "*.txt")).sole)}"
    assert FileDraft.exists?(FileURLPath: locator)
    assert_equal "private upload bytes", File.binread(DocumentStorage.configured.resolve(locator))
  end

  test "creation removes completed publication after staging cleanup and database failures" do
    log_in_as(@tenant)
    with_publication_cleanup_failure do
      FileDraft.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid.new(FileDraft.new) }) do
        assert_no_difference("FileDraft.count") { perform_creation("upload") }
      end
    end
    assert_response :service_unavailable
    assert_empty Dir.children(@document_storage_root)
  end

  test "creation preserves the persistence failure when private cleanup also fails" do
    log_in_as(@tenant)
    storage = DocumentStorage.configured
    DocumentStorage.stub(:configured, storage) do
      storage.stub(:delete_private, ->(*) { raise DocumentStorage::Unavailable, "cleanup details" }) do
        FileDraft.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid.new(FileDraft.new) }) do
          assert_no_difference("FileDraft.count") { perform_creation("upload") }
        end
      end
    end
    assert_response :service_unavailable
    assert_equal 1, Dir.children(@document_storage_root).size
    assert_not_includes response.body, "cleanup details"
  end

  test "HTML write failure leaves no file or record" do
    log_in_as(@tenant)
    original_write = File.method(:write)
    failing_write = ->(path, *args) do
      raise IOError, "private write details" if path.to_s.start_with?(@document_storage_root)
      original_write.call(path, *args)
    end
    File.stub(:write, failing_write) do
      assert_no_difference("FileDraft.count") { perform_creation("html") }
    end
    assert_response :service_unavailable
    assert_empty Dir.children(@document_storage_root)
  end

  test "upload streaming failure leaves no file or record" do
    log_in_as(@tenant)
    original_copy_stream = IO.method(:copy_stream)
    storage_write_attempted = false
    failing_copy_stream = ->(source, destination, *args) do
      if destination.respond_to?(:path) && File.dirname(destination.path) == @document_storage_root
        storage_write_attempted = true
        destination.write("partial upload")
        raise IOError, "private upload details"
      end
      original_copy_stream.call(source, destination, *args)
    end
    IO.stub(:copy_stream, failing_copy_stream) do
      assert_no_difference(["FileDraft.count", "Message.count", "FileAttachment.count"]) { perform_creation("upload") }
    end
    assert storage_write_attempted
    assert_response :service_unavailable
    assert_empty Dir.children(@document_storage_root)
    assert_not_includes response.body, "private upload details"
  end

  %w[a b c].each do |template|
    test "revision renders template #{template} with escaped accepted terms" do
      file = create_agreement_draft(template: template)
      value = %q{<script>alert("revision")</script> & home}
      log_in_as(@landlord)
      terms = template == "b" ? {} : agreement_params
      patch update_review_document_path(file.FileID), params: terms.merge(agreement_version: 1, address: value)
      log_in_as(@tenant)
      patch decide_document_suggestion_path(file.FileID, "address"), params: { decision: "accepted" }, as: :json
      assert_response :success
      assert_equal "updated", response.parsed_body["status"]
      document = Nokogiri::HTML(DocumentStorage.configured.resolve(file.reload.FileURLPath).read)
      assert_equal value, document.at_css('[data-agreement-field="address"]').text
      assert_empty document.css("script")
      assert document.at_css("h1")
    end
  end

  [false, true].each do |mediator|
    [false, true].each do |legacy|
      test "#{mediator ? 'mediator final' : 'ordinary'} acceptance preserves #{legacy ? 'legacy' : 'private'} source" do
        file = prepare_agreement_revision(mediator: mediator, legacy: legacy)
        locator = file.FileURLPath
        path = DocumentStorage.configured.resolve(locator)
        bytes = path.binread
        attachments = FileAttachment.where(FileID: file.FileID).pluck(:MessageID)
        public_files = Dir.glob(Rails.root.join("public", "userFiles", "*"))
        patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }, as: :json
        assert_response :success
        assert_equal "updated", response.parsed_body["status"]
        file.reload
        assert_equal 2, file.AgreementVersion
        assert_equal "2026-05-15", file.agreement_terms["vacate_date"]
        assert_not file.LandlordSignature
        assert_not file.TenantSignature
        assert_nil file.LandlordSignedAt
        assert_nil file.TenantSignedAt
        assert_nil file.LandlordSignatureName
        assert_nil file.TenantSignatureName
        assert_equal "accepted", file.agreement_proposal["changes"]["vacate_date"]["decision"]
        assert_match %r{\AprivateDocuments/}, file.FileURLPath
        assert_not_equal locator, file.FileURLPath
        assert_equal bytes, path.binread
        assert_equal attachments, FileAttachment.where(FileID: file.FileID).pluck(:MessageID)
        assert_equal public_files, Dir.glob(Rails.root.join("public", "userFiles", "*"))
        assert_includes DocumentStorage.configured.resolve(file.FileURLPath).read, "2026"
      end
    end

    [:missing, :publication, :database, :rollback].each do |failure|
      test "#{mediator ? 'mediator final' : 'ordinary'} #{failure} failure preserves persisted review without success events" do
        file = prepare_agreement_revision(mediator: mediator)
        before = file.attributes
        path = DocumentStorage.configured.resolve(file.FileURLPath)
        bytes = path.binread
        File.delete(path) if failure == :missing
        files = Dir.children(@document_storage_root).sort
        message_count = Message.count
        request_revision = -> {
          assert_no_enqueued_emails do
            ActionCable.server.stub(:broadcast, ->(*) { flunk "Failed revision broadcast success" }) do
              patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }, as: :json
            end
          end
          assert_response :service_unavailable
          assert_equal "application/json", response.media_type
          assert_equal({ "error" => "Unable to revise agreement. Please try again." }, response.parsed_body)
        }
        case failure
        when :publication
          File.stub(:link, ->(*) { raise Errno::EACCES }) { request_revision.call }
        when :database, :rollback
          save = FileDraft.instance_method(:save!)
          FileDraft.define_method(:save!) do |*args, **kwargs|
            if self.AgreementVersion == 2
              raise ActiveRecord::Rollback if failure == :rollback
              raise ActiveRecord::RecordInvalid.new(self)
            end
            save.bind(self).call(*args, **kwargs)
          end
          begin
            request_revision.call
          ensure
            FileDraft.define_method(:save!, save)
          end
        else
          request_revision.call
        end
        assert_equal before, file.reload.attributes
        assert_equal message_count, Message.count
        assert_equal files, Dir.children(@document_storage_root).sort
        assert_equal bytes, path.binread unless failure == :missing
        assert_nil flash[:notice]
      end
    end

    test "#{mediator ? 'mediator' : 'ordinary'} rejection is database only" do
      file = prepare_agreement_revision(mediator: mediator)
      locator = file.FileURLPath
      files = Dir.children(@document_storage_root).sort
      DocumentRevision.stub(:new, ->(*) { flunk "Rejection invoked revision" }) do
        patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "rejected" }, as: :json
      end
      assert_response :success
      assert_equal locator, file.reload.FileURLPath
      assert_equal 1, file.AgreementVersion
      assert file.LandlordSignature
      assert_equal files, Dir.children(@document_storage_root).sort
    end

    [:stale, :unauthorized].each do |reason|
      test "#{mediator ? 'mediator' : 'ordinary'} #{reason} acceptance cannot revise" do
        file = prepare_agreement_revision(mediator: mediator)
        file.update!(AgreementVersion: 2) if reason == :stale
        log_in_as(@landlord) if reason == :unauthorized
        before = file.reload.attributes
        DocumentRevision.stub(:new, ->(*) { flunk "Unavailable suggestion invoked revision" }) do
          assert_no_enqueued_emails do
            patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }, as: :json
          end
        end
        assert_response :conflict
        assert_equal before, file.reload.attributes
      end
    end
  end

  private

  def with_publication_cleanup_failure
    storage = DocumentStorage.configured
    original_write = storage.method(:write)
    completed_write = ->(extension:, &writer) do
      locator = original_write.call(extension: extension, &writer)
      raise DocumentStorage::CleanupFailure.new(locator: locator)
    end
    DocumentStorage.stub(:configured, storage) do
      storage.stub(:write, completed_write) { yield }
    end
  end

  def perform_creation(workflow)
    case workflow
    when "upload"
      post documents_path, params: { file: build_uploaded_file("private.txt", "text/plain", "private upload bytes") }
    when "html"
      post generate_from_intake_path(template: "a"), params: agreement_params
    when "pdf"
      post generate_filled_template_path, params: agreement_params.merge(template: "a")
    end
  end

  def get_template_information(endpoint, conversation_id)
    if endpoint == :template_intake
      get template_intake_path(template: "a"), params: { conversation_id: conversation_id }
    else
      get intake_template_view_path(conversation_id: conversation_id)
    end
  end

  def assert_template_information_not_found
    assert_response :not_found
    assert_empty response.body
    assert_nil assigns(:tenant)
    assert_nil assigns(:landlord)
    assert_nil assigns(:intake)
    assert_nil assigns(:pmg)
  end

  def prepare_agreement_revision(mediator:, legacy: false)
    file = create_agreement_draft(legacy: legacy)
    log_in_as(mediator ? @mediator : @landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15"
    )
    if mediator
      log_in_as(@landlord)
      DocumentRevision.stub(:new, ->(*) { flunk "First mediator approval invoked revision" }) do
        patch decide_document_suggestion_path(file.FileID, "vacate_date"), params: { decision: "accepted" }, as: :json
      end
      assert_equal "pending", response.parsed_body["status"]
    end
    file.reload.update!(LandlordSignature: true, LandlordSignedAt: Time.current, LandlordSignatureName: "Jane")
    log_in_as(@tenant)
    get view_file_path(file.FileID)
    file.reload
  end

  def agreement_params
    { landlord_name: "Jane Doe", tenant_name: "John Doe", address: "123 Main Street",
      negotiation_date: "2026-03-20", reason: "Failure to Pay Rent", money_owed: "900",
      best_option: "Move Out", vacate_date: "2026-05-01",
      amount1: "500", date1: "2026-03-30", amount2: "400", date2: "2026-04-30" }
  end

  def pay_and_stay_params
    agreement_params.except(:vacate_date, :amount1, :date1, :amount2, :date2).merge(
      monthly_rent: "1200", regular_rent_due_day: "1", regular_rent_arrangement: "unchanged",
      unresolved_payment_issues: "no", conditional_reduction: "none", payment_application: "standard",
      payment_method: "money_order", payment_recipient_instructions: "Mail to the property office",
      payment_lump_sum: "1", lump_sum_amount: "900", lump_sum_date: "2026-04-01",
      rental_assistance: "none", satisfaction_business_days: "5", existing_eviction_case: "none",
      correction_period: "none", additional_terms_selection: "none", attachments: "None"
    )
  end

  def six_payment_pay_and_stay_params
    terms = pay_and_stay_params.merge(money_owed: "2400", payment_lump_sum: "0", payment_custom_schedule: "1")
    (1..6).each do |number|
      terms[:"amount#{number}"] = "400"
      terms[:"date#{number}"] = Date.new(2026, number + 3, 1).iso8601
    end
    terms
  end

  def create_agreement_draft(template: "a", legacy: false, terms: nil)
    log_in_as(@tenant)
    terms ||= template == "b" ? pay_and_stay_params : agreement_params

    post generate_from_intake_path(template: template),
        params: terms.merge(conversation_id: @mediation.ConversationID)

    assert_response :redirect

    file = FileDraft.where(
      CreatorID: @tenant.UserID,
      FileTypes: "html"
    ).order(FileDraft.primary_key => :desc).first!

    assert_nil file.AgreementConversationID

    # Simulate the manual sharing step required before agreement review.
    message = Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      MessageDate: Time.current,
      Contents: "Agreement shared for review"
    )

    FileAttachment.create!(
      MessageID: message.MessageID,
      FileID: file.FileID
    )

    file.update!(
      AgreementConversationID: @mediation.ConversationID
    )

    return file unless legacy

    # Explicit compatibility fixture for permitted legacy reads.
    private_path = DocumentStorage.configured.resolve(file.FileURLPath)
    legacy_locator = "userFiles/#{File.basename(private_path)}"
    FileUtils.mkdir_p(Rails.root.join("public", "userFiles"))
    legacy_path = Rails.root.join("public", legacy_locator)
    FileUtils.cp(private_path, legacy_path)
    (@legacy_agreement_fixture_paths ||= []) << legacy_path
    file.update!(FileURLPath: legacy_locator)
    file
  end

  def create_checkpoint_pay_and_stay_draft
    file = create_agreement_draft(template: "b")
    file.update!(AgreementTerms: file.agreement_terms.except("pay_and_stay_draft_version").to_json)
    DocumentStorage.configured.resolve(file.FileURLPath).binwrite(legacy_pay_and_stay_html("legacy", file.agreement_terms))
    get view_inline_document_path(file.FileID, editable_preview: 1)
    assert_response :success
    file
  end

  def legacy_pay_and_stay_html(format, terms)
    render_pay_and_stay_fixture("pay_and_stay_#{format}", terms)
  end

  def render_pay_and_stay_fixture(template, terms)
    assigns = terms.symbolize_keys.merge(
      landlord: terms["landlord_name"], tenant: terms["tenant_name"], schedule: [],
      date: Date.iso8601(terms.fetch("negotiation_date")).strftime("%B %d, %Y")
    )
    PayAndStayTerms::PAYMENT_OPTIONS.each_key { |field| assigns[field.to_sym] = terms[field] == "1" }
    DocumentsController.render(template: "documents/templates/#{template}", assigns: assigns, layout: false)
  end

  def build_uploaded_file(filename, content_type, content)
    temp = Tempfile.new([ "upload", File.extname(filename) ])
    temp.binmode
    temp.write(content)
    temp.rewind

    Rack::Test::UploadedFile.new(temp.path, content_type, original_filename: filename)
  end

  def build_large_uploaded_file(filename, content_type, bytes)
    temp = Tempfile.new([ "upload-large", File.extname(filename) ])
    temp.binmode
    temp.truncate(bytes)
    temp.rewind

    Rack::Test::UploadedFile.new(temp.path, content_type, original_filename: filename)
  end

  def create_stored_file_draft(creator_id:, ext:, content:)
    file_id = "test-file-#{SecureRandom.hex(8)}"
    dir = Rails.root.join("public", "userFiles")
    FileUtils.mkdir_p(dir)
    File.write(dir.join("#{file_id}#{ext}"), content)

    FileDraft.create!(
      FileID: file_id,
      CreatorID: creator_id,
      FileName: "stored",
      FileTypes: ext.delete("."),
      FileURLPath: "userFiles/#{file_id}#{ext}",
      TenantSignature: false,
      LandlordSignature: false
    )
  end

  def create_linked_signable_file(conversation_id:)
    file = create_checkpoint_pay_and_stay_draft
    file.update!(AgreementTemplate: nil, AgreementVersion: nil, AgreementConversationID: nil)
    message = Message.create!(
      ConversationID: conversation_id,
      SenderID: @landlord.UserID,
      MessageDate: Time.current,
      Contents: "Please sign"
    )
    FileAttachment.create!(FileID: file.FileID, MessageID: message.MessageID)
    file
  end
end
