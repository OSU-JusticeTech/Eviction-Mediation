require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "uses UserID as the primary key" do
    assert_equal "UserID", User.primary_key
  end

  test "normalizes email before validation" do
    u = User.new
    u[:Email] = "  TeSt@EXAMPLE.Com "
    u.validate
    assert_equal "test@example.com", u[:Email]
  end

  test "display_name prefers FirstName then email local part" do
    u = User.new
    u[:Email] = "sam@example.com"
    assert_equal "Sam", u.display_name

    u2 = User.new
    assert_kind_of String, u2.display_name # Testing for fallback string defined in app/models/user.rb:28
  end

  test "role predicate helpers return correct booleans" do
    u = User.new(Role: "Tenant")
    assert u.tenant?
    refute u.landlord?

    u.Role = "Landlord"
    assert u.landlord?

    u.Role = "Mediator"
    assert u.mediator?

    u.Role = "Admin"
    assert u.admin?
  end

  test "format_phone_for_display formats 10-digit numbers" do
    u = User.new(PhoneNumber: "5551234567")
    assert_equal "(555) 123-4567", u.format_phone_for_display

    u2 = User.new(PhoneNumber: "+1 (555) 123-4567")
    assert_equal "+1 (555) 123-4567", u2.format_phone_for_display

    u3 = User.new(PhoneNumber: "123")
    assert_equal "123", u3.format_phone_for_display
  end

  test "tenant role requires TenantAddress" do
    u = User.new
    u[:Role] = "Tenant"
    u[:Email] = "tenant@example.com"
    u.validate
    assert_includes u.errors.attribute_names.map(&:to_s), "TenantAddress"
  end

  test "profile disclaimer acceptance validation" do
    u = User.new(Email: "d@example.com", ProfileDisclaimer: "no")
    u.validate
    assert_includes u.errors[:ProfileDisclaimer], "You must agree to the Disclaimer to sign up."
  end
end
