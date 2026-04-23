class User < ApplicationRecord
  self.primary_key = "UserID"
  has_secure_password
  attr_accessor :ProfileDisclaimer
  validates :ProfileDisclaimer, acceptance: { accept: "yes", message: "You must agree to the Disclaimer to sign up." }

  validates :Email,
            presence: true,
            uniqueness: { case_sensitive: false, message: "is already registered" },
            format: { with: URI::MailTo::EMAIL_REGEXP, message: "must be a valid email address" }

  validate :phone_number_must_be_valid

  validates :password_confirmation, presence: true, if: -> { password.present? }

  validate :role_based_field_requirements

  has_one :mediator, foreign_key: "UserID", primary_key: "UserID", dependent: :destroy
  accepts_nested_attributes_for :mediator

  before_validation :normalize_email

  def display_name
    first = self[:FirstName]
    return first if first.present?

    email = self[:Email]
    return email.split("@").first.titleize if email.present?

    "unnamed"
  end

  def tenant?   = self[:Role] == "Tenant"
  def landlord? = self[:Role] == "Landlord"
  def mediator? = self[:Role] == "Mediator"
  def admin?    = self[:Role] == "Admin"

  def formatted_tenant_address
    street = [ self[:AddressLine1].presence, self[:AddressLine2].presence ].compact.join(", ")
    state_zip = [ self[:State].presence, self[:ZipCode].presence ].compact.join(" ")
    city_state_zip = [ self[:City].presence, state_zip.presence ].compact.join(", ")

    [ street.presence, city_state_zip.presence ].compact.join(", ").presence
  end

  # Two-Factor Authentication methods
  def two_factor_enabled?
    self[:two_factor_enabled] == true
  end

  def phone_verified?
    self[:phone_verified] == true
  end

  def phone_number
    self[:PhoneNumber]
  end

  def format_phone_for_display
    return nil unless phone_number.present?
    # Format
    cleaned = phone_number.gsub(/\D/, "")
    if cleaned.length == 10
      "(#{cleaned[0..2]}) #{cleaned[3..5]}-#{cleaned[6..9]}"
    else
      phone_number
    end
  end

  private

  def normalize_email
    self[:Email] = self[:Email].to_s.strip.downcase
  end

  def role_based_field_requirements
    if self[:Role] == "Tenant"
      errors.add(:AddressLine1, "can't be blank for tenants") if self[:AddressLine1].blank?
      errors.add(:City, "can't be blank for tenants") if self[:City].blank?
      errors.add(:State, "can't be blank for tenants") if self[:State].blank?
      errors.add(:ZipCode, "can't be blank for tenants") if self[:ZipCode].blank?

      if self[:State].present? && self[:State].to_s !~ /\A[A-Za-z]{2}\z/
        errors.add(:State, "must be a 2-letter state code")
      end

      if self[:ZipCode].present? && self[:ZipCode].to_s !~ /\A\d{5}(-\d{4})?\z/
        errors.add(:ZipCode, "must be a valid ZIP code")
      end
    elsif self[:Role] == "Landlord" && self[:CompanyName].present? && self[:CompanyName].length > 255
      errors.add(:CompanyName, "is too long")
    end
  end

  def phone_number_must_be_valid
    return if self[:PhoneNumber].blank?

    digits_only = self[:PhoneNumber].to_s.gsub(/\D/, "")
    return if digits_only.length == 10
    return if digits_only.length == 11 && digits_only.start_with?("1")

    errors.add(:PhoneNumber, "is not a valid phone number")
  end
end
