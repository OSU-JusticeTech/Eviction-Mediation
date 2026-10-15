require "test_helper"
require "tempfile"

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediator = users(:mediator1)
    @outsider = users(:tenant2)
    @mediation = primary_message_groups(:one)
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

  test "creator can destroy document" do
    file = file_drafts(:two)
    log_in_as(@tenant)

    delete document_path(file.FileID)

    assert_redirected_to documents_path
    assert_equal "Document deleted.", flash[:notice]
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

  test "apply signature succeeds for tenant participant" do
    log_in_as(@tenant)
    file = create_linked_signable_file(conversation_id: @mediation.ConversationID)

    post apply_signature_document_path(file.FileID), params: { signature_name: "John Doe" }

    assert_redirected_to view_file_path(file.FileID)
    assert_equal true, file.reload.TenantSignature
    assert_equal "John Doe", file.reload.TenantSignatureName
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
    assert FileDraft.exists?(FileName: "#{@tenant.FName} #{@tenant.LName} - Agree to Vacate")
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
      post generate_from_intake_path(template: "b"), params: {
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "2026-03-20",
        reason: "Nonpayment",
        money_owed: "900",
        monthly_rent: "1200",
        rent_owed: "700",
        late_fees: "100",
        utilities: "50",
        payment_monthly: "1",
        monthly_payment_amount: "300",
        monthly_payment_months: "3",
        monthly_payment_day: "15",
        monthly_payment_start: "2026-04-01"
      }
    end

    assert_redirected_to documents_path
  end

  test "generate_from_intake shares to conversation when conversation is present" do
    log_in_as(@tenant)

    assert_difference("Message.count", 1) do
      post generate_from_intake_path(template: "a"), params: {
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "2026-03-20",
        reason: "Nonpayment",
        money_owed: "900",
        conversation_id: @mediation.ConversationID
      }
    end

    assert_redirected_to message_path(@mediation.ConversationID)
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

  test "accepted suggestions update the document immediately while remaining suggestions stay pending" do
    file = create_agreement_draft
    log_in_as(@landlord)
    get review_document_path(file.FileID)
    assert_response :success
    assert_select "h3", text: "Payment Schedule (Optional)"
    assert_select "input[name='amount2'][value='400']"
    assert_select "input[name='date2'][value='2026-04-30']"

    post apply_signature_document_path(file.FileID), params: { signature_name: "Jane Doe", agreement_version: 1 }
    assert file.reload.LandlordSignature
    original_html = File.read(Rails.root.join("public", file.FileURLPath))

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, vacate_date: "2026-05-15", amount2: "400", date2: "2026-05-15"
    )
    assert_redirected_to view_file_path(file.FileID)
    assert_equal 1, file.reload.AgreementVersion
    assert file.LandlordSignature
    assert file.agreement_suggestions_pending?
    assert_equal "2026-04-30", file.agreement_terms["date2"]
    assert_equal original_html, File.read(Rails.root.join("public", file.FileURLPath))
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
    assert_not_equal original_html, File.read(Rails.root.join("public", file.FileURLPath))
    assert_equal "Landlord Jane Doe suggested changes to the agreement. Review the document to see them.", Message.order(:MessageID).last.Contents
    patch decide_document_suggestion_path(file.FileID, "date2"), params: { decision: "rejected" }
    assert_redirected_to view_file_path(file.FileID, anchor: "suggestion-date2")
    assert_equal 2, file.reload.AgreementVersion
    assert_not file.agreement_suggestions_pending?
    assert_not file.LandlordSignature
    assert_nil file.LandlordSignedAt
    assert_equal "2026-05-15", file.agreement_terms["vacate_date"]
    assert_equal "2026-04-30", file.agreement_terms["date2"]
    assert_not_equal original_html, File.read(Rails.root.join("public", file.FileURLPath))
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
  end

  test "a date-only payment suggestion is refused while the schedule remains optional" do
    file = create_agreement_draft
    log_in_as(@landlord)
    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, date3: "2026-06-01"
    )
    assert_redirected_to review_document_path(file.FileID)
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
    log_in_as(@landlord)
    post apply_signature_document_path(file.FileID), params: { signature_name: "Jane Doe", agreement_version: 1 }
    original_html = File.read(Rails.root.join("public", file.FileURLPath))

    patch update_review_document_path(file.FileID), params: agreement_params.merge(
      agreement_version: 1, amount2: "300"
    )

    assert_redirected_to view_file_path(file.FileID)
    assert_equal 1, file.reload.AgreementVersion
    assert file.LandlordSignature
    assert file.agreement_suggestions_pending?
    assert_equal original_html, File.read(Rails.root.join("public", file.FileURLPath))
  end

  test "unrelated users cannot revise an agreement" do
    file = create_agreement_draft
    log_in_as(@outsider)
    get review_document_path(file.FileID)
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
    post generate_from_intake_path(template: "b"), params: agreement_params.merge(
      conversation_id: @mediation.ConversationID, payment_monthly: "1",
      monthly_payment_amount: "300", monthly_payment_months: "3",
      monthly_payment_day: "15", monthly_payment_start: "2026-04-01",
      payment_method: "money_order"
    )
    file = FileAttachment.order(:MessageID).last.file_draft

    log_in_as(@landlord)
    get review_document_path(file.FileID)
    assert_response :success
    assert_select "input[name='payment_monthly'][checked]"
    assert_select "input[name='monthly_payment_day'][value='15']"
    assert_select "input[name='payment_method'][value='money_order'][checked]"

    patch update_review_document_path(file.FileID), params: agreement_params.except(
      :amount1, :date1, :amount2, :date2
    ).merge(
      agreement_version: 1, payment_monthly: "1", monthly_payment_amount: "300",
      monthly_payment_months: "3", monthly_payment_day: "16",
      monthly_payment_start: "2026-04-01", payment_method: "money_order"
    )
    assert_equal ["monthly_payment_day"], file.reload.agreement_proposal["changes"].keys
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
    assert FileDraft.exists?(FileName: "#{@tenant.FName} #{@tenant.LName} - Agree to Vacate")
  end

  test "generate_filled_template supports pay and stay template" do
    log_in_as(@tenant)

    assert_difference("FileDraft.count", 1) do
      post generate_filled_template_path, params: {
        template: "b",
        landlord_name: "Jane Doe",
        tenant_name: "John Doe",
        address: "123 Main Street",
        negotiation_date: "2026-03-20",
        reason: "Nonpayment",
        money_owed: "900",
        monthly_rent: "1200",
        best_option: "Payment Plan",
        amount1: "450",
        date1: "2026-03-30",
        amount2: "450",
        date2: "2026-04-30"
      }
    end

    assert_redirected_to documents_path
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

  private

  def agreement_params
    { landlord_name: "Jane Doe", tenant_name: "John Doe", address: "123 Main Street",
      negotiation_date: "2026-03-20", reason: "Failure to Pay Rent", money_owed: "900",
      best_option: "Move Out", vacate_date: "2026-05-01",
      amount1: "500", date1: "2026-03-30", amount2: "400", date2: "2026-04-30" }
  end

  def create_agreement_draft
    log_in_as(@tenant)
    post generate_from_intake_path(template: "a"), params: agreement_params.merge(conversation_id: @mediation.ConversationID)
    FileAttachment.order(:MessageID).last.file_draft
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
    file = create_stored_file_draft(creator_id: @landlord.UserID, ext: ".html", content: "<strong>Tenant:</strong> <span class=\"signature-line\">___________</span>")
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
