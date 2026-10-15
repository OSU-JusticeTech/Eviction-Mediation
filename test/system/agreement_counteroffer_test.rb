require "application_system_test_case"

class AgreementCounterofferTest < ApplicationSystemTestCase
  setup do
    @landlord = users(:landlord1)
    @tenant = users(:tenant1)
    @conversation = primary_message_groups(:one)
    file_id = "counteroffer-#{SecureRandom.hex(8)}"
    @saved_path = Rails.root.join("public", "userFiles", "#{file_id}.html")
    FileUtils.mkdir_p(@saved_path.dirname)
    File.write(@saved_path, "<html><body><p>Agreement preview</p></body></html>")
    terms = { "landlord_name" => "Jane Doe", "tenant_name" => "John Doe", "address" => "123 Main Street",
              "negotiation_date" => "2026-10-16", "reason" => "Failure to Pay Rent", "money_owed" => "900",
              "vacate_date" => "2026-10-20", "amount1" => "1000", "date1" => "2026-10-14" }
    proposal = { "base_version" => 1, "proposer_id" => @tenant.UserID,
                 "changes" => { "vacate_date" => { "from" => "2026-10-20", "to" => "2026-10-30", "decision" => "pending" } } }
    @file = FileDraft.create!(FileID: file_id, CreatorID: @tenant.UserID,
                              FileName: "Agreement", FileTypes: "html", FileURLPath: "userFiles/#{file_id}.html",
                              AgreementTemplate: "a", AgreementTerms: JSON.generate(terms),
                              AgreementVersion: 1, AgreementProposal: JSON.generate(proposal),
                              AgreementConversationID: @conversation.ConversationID,
                              TenantSignature: false, LandlordSignature: false)
    message = Message.create!(ConversationID: @conversation.ConversationID, SenderID: @tenant.UserID,
                              Contents: "Agreement for review", MessageDate: Time.current)
    FileAttachment.create!(MessageID: message.MessageID, FileID: @file.FileID)
  end

  teardown do
    File.delete(@saved_path) if @saved_path && File.exist?(@saved_path)
  end

  test "counteroffer stays in the current suggestion without jumping to the top" do
    visit login_path
    fill_in "email", with: @landlord.Email
    fill_in "password", with: "password"
    click_button "Log In"
    click_button "OK" if page.has_button?("OK", wait: 1)

    page.driver.browser.manage.window.resize_to(1200, 650)
    visit view_file_path(@file.FileID)
    assert_current_path view_file_path(@file.FileID)
    assert_selector "#suggestion-vacate_date"
    assert_selector "#counteroffer-vacate_date[hidden]", visible: :all
    within "#suggestion-vacate_date" do
      click_button "Counteroffer"
      assert_selector "#counteroffer-vacate_date:not([hidden])"
      find("input[type=date]").set("2026-11-05")
    end
    page.execute_script("document.querySelector('#counteroffer-vacate_date input[type=submit]').scrollIntoView({block: 'center'})")
    before = page.evaluate_script("document.body.scrollTop")
    assert_operator before, :>, 0
    within "#suggestion-vacate_date" do
      click_button "Save Counteroffer"
    end
    assert_selector "#suggestion-vacate_date", text: "Offered by Landlord"
    after = page.evaluate_script("document.body.scrollTop")
    assert_operator after, :>, 0
    assert_operator after, :>, before - 400
  end

  test "counteroffer waits for the other decisions before it is shared" do
    proposal = @file.agreement_proposal
    proposal["changes"]["date1"] = { "from" => "2026-10-14", "to" => "2026-10-20", "decision" => "pending" }
    @file.update!(AgreementProposal: JSON.generate(proposal))
    messages_before = Message.where(ConversationID: @conversation.ConversationID).count

    visit login_path
    fill_in "email", with: @landlord.Email
    fill_in "password", with: "password"
    click_button "Log In"
    click_button "OK" if page.has_button?("OK", wait: 1)
    visit view_file_path(@file.FileID)

    within "#suggestion-vacate_date" do
      click_button "Counteroffer"
      page.execute_script("document.querySelector('#counteroffer-vacate_date input[type=date]').value = '2026-11-05'")
      click_button "Save Counteroffer"
      assert_text(/Counteroffer ready/i)
      assert_text "2026-11-05"
    end
    assert_equal messages_before, Message.where(ConversationID: @conversation.ConversationID).count
    assert_equal "2026-10-30", @file.reload.agreement_proposal["changes"]["vacate_date"]["to"]
    page.refresh
    assert_selector "#suggestion-vacate_date", text: /Counteroffer ready/i
    within "#suggestion-date1" do
      click_button "Reject"
    end
    assert_selector "#suggestion-vacate_date", text: "Offered by Landlord"
    assert_equal messages_before + 1, Message.where(ConversationID: @conversation.ConversationID).count
    assert_equal "2026-11-05", @file.reload.agreement_proposal["changes"]["vacate_date"]["to"]
  end

  test "a saved decision closes that item while other suggestions remain" do
    proposal = @file.agreement_proposal
    proposal["changes"]["date1"] = { "from" => "2026-10-14", "to" => "2026-10-20", "decision" => "pending" }
    @file.update!(AgreementProposal: JSON.generate(proposal))
    visit login_path
    fill_in "email", with: @landlord.Email
    fill_in "password", with: "password"
    click_button "Log In"
    click_button "OK" if page.has_button?("OK", wait: 1)

    visit view_file_path(@file.FileID)
    page.driver.browser.manage.window.resize_to(1200, 650)
    page.execute_script("document.querySelector('#suggestion-vacate_date').scrollIntoView({block: 'center'})")
    before = page.evaluate_script("document.body.scrollTop")
    assert_operator before, :>, 0
    within "#suggestion-vacate_date" do
      click_button "Accept"
      assert_text "Accepted"
      assert_no_button "Accept"
      assert_no_button "Reject"
      assert_text "Decision recorded. This item is closed."
      assert_text(/Accepted in document/i)
    end
    assert_operator page.evaluate_script("document.body.scrollTop"), :>, 0
    assert_selector "#suggestion-date1 .suggestion-actions"
    assert_equal 2, @file.reload.AgreementVersion
    assert_equal "2026-10-30", @file.agreement_terms["vacate_date"]
    assert @file.agreement_suggestions_pending?
    page.refresh
    assert_no_selector "#suggestion-vacate_date .suggestion-actions"
    assert_selector "#suggestion-date1 .suggestion-actions"
    assert_equal "accepted", @file.reload.agreement_proposal["changes"]["vacate_date"]["decision"]
  end
end
