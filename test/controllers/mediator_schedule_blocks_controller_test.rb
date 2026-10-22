require "test_helper"

class MediatorScheduleBlocksControllerTest < ActionDispatch::IntegrationTest
  setup do
    mediator = User.find_by!(UserID: 4)
    post login_path, params: {
      email: mediator.Email,
      password: "password"
    }
    assert_response :redirect
  end

  def block_params
    {
      block: {
        StartTime: "2026-10-26 13:00:00",
        EndTime: "2026-10-26 15:00:00",
        Reason: "Unavailable"
      }
    }
  end

  def create_block(mediator_id = 4)
    MediatorScheduleBlock.create!(
      MediatorID: mediator_id,
      StartTime: "2026-10-26 13:00:00",
      EndTime: "2026-10-26 15:00:00"
    )
  end

  test "lists own blocked periods" do
    create_block(4)
    create_block(8)

    get mediator_schedule_blocks_path

    assert_response :success
    assert_equal [4], response.parsed_body.map { |b| b["MediatorID"] }
  end

  test "creates blocked period" do
    assert_difference "MediatorScheduleBlock.count", 1 do
      post mediator_schedule_blocks_path, params: block_params
    end

    assert_response :created
    assert_equal 4, response.parsed_body["MediatorID"]
  end

  test "rejects invalid blocked period" do
    params = block_params
    params[:block][:EndTime] = "2026-10-26 12:00:00"

    post mediator_schedule_blocks_path, params: params

    assert_response :unprocessable_entity
  end

  test "updates own blocked period" do
    block = create_block

    patch mediator_schedule_block_path(block),
          params: { block: { Reason: "Vacation" } }

    assert_response :success
    assert_equal "Vacation", block.reload.Reason
  end

  test "deletes own blocked period" do
    block = create_block

    assert_difference "MediatorScheduleBlock.count", -1 do
      delete mediator_schedule_block_path(block)
    end

    assert_response :no_content
  end

  test "cannot update another mediators block" do
    block = create_block(8)

    patch mediator_schedule_block_path(block),
          params: { block: { Reason: "Changed" } }

    assert_response :not_found
    assert_nil block.reload.Reason
  end

  test "cannot delete another mediators block" do
    block = create_block(8)

    assert_no_difference "MediatorScheduleBlock.count" do
      delete mediator_schedule_block_path(block)
    end

    assert_response :not_found
  end

  test "cannot impersonate another mediator when creating block" do
    params = block_params
    params[:block][:MediatorID] = 8

    post mediator_schedule_blocks_path, params: params

    assert_response :created
    assert_equal 4, response.parsed_body["MediatorID"]
  end

  test "requires login to access schedule blocks" do
    delete logout_path

    get mediator_schedule_blocks_path

    assert_response :unauthorized
    assert_equal "Login required", response.parsed_body["error"]
  end

  test "rejects non mediator access to schedule blocks" do
    delete logout_path

    landlord = User.find_by!(UserID: 1)
    post login_path, params: {
      email: landlord.Email,
      password: "password"
    }

    assert_response :redirect

    get mediator_schedule_blocks_path

    assert_response :forbidden
    assert_equal "Mediator access required", response.parsed_body["error"]
  end
end