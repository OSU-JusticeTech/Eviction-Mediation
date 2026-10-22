require "test_helper"

class MediationMailerTest < ActionMailer::TestCase
  test "agreement emails name the actor and include document links in text and html" do
    actor = users(:tenant1)
    name = "#{actor.FName} #{actor.LName} (Tenant)"
    MediationMailer::AGREEMENT_EVENTS.each do |event, (title, description)|
      mail = MediationMailer.agreement_notification(users(:landlord1), 1, event, 42, actor)
      assert_equal [ users(:landlord1).Email ], mail.to
      assert_equal title % { actor: name }, mail.subject
      assert_includes mail.text_part.body.decoded, description % { actor: name }
      assert_includes mail.text_part.body.decoded, "/documents/42/view"
      assert_includes mail.html_part.body.decoded, "View in Eviction Mediation"
      assert_nil mail.cc
    end
  end

  test "actor roles are capitalized in email subjects and both body formats" do
    %i[tenant1 landlord1 mediator1].each do |fixture|
      actor = users(fixture)
      label = "#{actor.FName} #{actor.LName} (#{actor.Role.capitalize})"
      mail = MediationMailer.agreement_notification(users(:tenant2), 1, "agreement_signed", 42, actor)
      assert_equal "#{label} signed the agreement", mail.subject
      assert_includes mail.text_part.body.decoded, label
      assert_includes mail.html_part.body.decoded, label
    end
  end

  test "revision email contains changed fields and signing status with escaped html" do
    changes = [ "Amount Owed: $100 → $200", "Additional terms: Not set → <script>example</script>" ]
    mail = MediationMailer.agreement_notification(users(:landlord1), 1, "agreement_revised", 42,
                                                 users(:tenant1), changes, "Suggestions remain pending.")
    changes.each { |change| assert_includes mail.text_part.body.decoded, change }
    assert_includes mail.text_part.body.decoded, "Suggestions remain pending."
    assert_includes mail.html_part.body.decoded, "&lt;script&gt;"
    assert_not_includes mail.html_part.body.decoded, "<script>"
  end

  test "new message email identifies the sender without including chat contents" do
    actor = users(:tenant1)
    mail = MediationMailer.new_message_notification(users(:landlord1), 1, actor)
    assert_equal [ users(:landlord1).Email ], mail.to
    assert_equal "New message from #{actor.FName} #{actor.LName} (Tenant)", mail.subject
    assert_includes mail.text_part.body.decoded, "/messages"
    assert_includes mail.html_part.body.decoded, "sent you a message."
  end

  test "closure emails render each outcome and distinguish outcome updates" do
    (PrimaryMessageGroup::OUTCOMES + [ nil, "<script>outcome</script>" ]).each do |outcome|
      mail = MediationMailer.case_closed_notification(users(:tenant1), 1, outcome, users(:landlord1))
      assert_equal [ users(:tenant1).Email ], mail.to
      assert_equal "Mediation case closed", mail.subject
      assert_includes mail.text_part.body.decoded, "(Landlord) closed the case."
      assert_includes mail.text_part.body.decoded, outcome || "The case outcome has not yet been recorded."
      assert_not_includes mail.html_part.body.decoded, "<script>"
    end
    mail = MediationMailer.case_closed_notification(users(:tenant1), 1, "Closed with agreement", users(:mediator1), true)
    assert_equal "Mediation case outcome updated", mail.subject
    assert_includes mail.text_part.body.decoded, "(Mediator) updated the case outcome."
  end

  test "email document links follow the configured production host and protocol" do
    previous = MediationMailer.default_url_options.dup
    begin
      MediationMailer.default_url_options = { host: "eviction-mediation.novelminds.io", protocol: "https" }
      mail = MediationMailer.agreement_notification(users(:landlord1), 1, "agreement_shared", 42, users(:tenant1))
      assert_includes mail.text_part.body.decoded, "https://eviction-mediation.novelminds.io/documents/42/view"
      assert_not_includes mail.text_part.body.decoded, "localhost"
    ensure
      MediationMailer.default_url_options = previous
    end
  end
end
