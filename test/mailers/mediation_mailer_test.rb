require "test_helper"

class MediationMailerTest < ActionMailer::TestCase
  test "agreement emails render text and html with one recipient and a document link" do
    MediationMailer::AGREEMENT_EVENTS.each do |event, (title, description)|
      mail = MediationMailer.agreement_notification(users(:tenant1), 1, event, 42)
      assert_equal [ users(:tenant1).Email ], mail.to
      assert_equal title, mail.subject
      assert_includes mail.text_part.body.decoded, description
      assert_includes mail.text_part.body.decoded, "/documents/42/view"
      assert_includes mail.html_part.body.decoded, "View in Eviction Mediation"
      assert_nil mail.cc
    end
  end

  test "new message email links to messages without including message contents" do
    mail = MediationMailer.new_message_notification(users(:tenant1), 1)
    assert_equal [ users(:tenant1).Email ], mail.to
    assert_equal "New mediation message", mail.subject
    assert_includes mail.text_part.body.decoded, "/messages"
    assert_includes mail.html_part.body.decoded, "Sign in to read and respond."
  end

  test "closure emails render each outcome and escape html" do
    (PrimaryMessageGroup::OUTCOMES + [ nil, "<script>outcome</script>" ]).each do |outcome|
      mail = MediationMailer.case_closed_notification(users(:tenant1), 1, outcome)
      assert_equal [ users(:tenant1).Email ], mail.to
      assert_equal "Mediation case closed", mail.subject
      assert_includes mail.text_part.body.decoded, outcome || "The case outcome has not yet been recorded."
      assert_not_includes mail.html_part.body.decoded, "<script>"
    end
  end
end
