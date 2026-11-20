require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  test "welcome email explains that replies are not monitored in both formats" do
    user = users(:tenant1)
    email = UserMailer.welcome_email(user)

    assert_equal [user.Email], email.to
    [email.html_part, email.text_part].each do |part|
      assert_includes part.body.decoded, "no-reply address"
      assert_includes part.body.decoded, "Replies are not monitored."
      assert_not_includes part.body.decoded, "just reply to this email"
    end
  end
end
