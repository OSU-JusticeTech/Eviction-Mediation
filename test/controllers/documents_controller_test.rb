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
