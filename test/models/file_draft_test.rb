require "test_helper"

class FileDraftTest < ActiveSupport::TestCase
  #DATABASE TESTS
  test "uses the correct table name and primary key" do
    assert_equal "FileDrafts", FileDraft.table_name
    assert_equal "FileID", FileDraft.primary_key
  end

  test "has many file_attachments" do
    draft = file_drafts(:one)
    assert_respond_to draft, :file_attachments
    assert_equal 1, draft.file_attachments.count
  end

  test "has many messages through file_attachments" do
    draft = file_drafts(:one)
    assert_includes draft.messages, messages(:one)
  end

  #BUSINESS LOGIC TESTS
  test "uploaded_at returns CreatedAt if present" do
    fixed_time = Time.zone.parse("2025-01-01 00:00:00")
    draft = FileDraft.new(CreatedAt: fixed_time)
    assert_equal fixed_time, draft.uploaded_at
  end

  test "uploaded_at returns nil when CreatedAt is nil" do
    draft = FileDraft.new(CreatedAt: nil)
    assert_nil draft.uploaded_at
  end

  test "correctly reads file metadata from fixtures" do
    draft = file_drafts(:one)
    assert_equal "test", draft.FileName
    assert_equal "doc", draft.FileTypes
    assert_equal "home/docs/example", draft.FileURLPath
  end
end
