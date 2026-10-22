require "test_helper"

class MediatorScheduleAvailabilitiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mediator = User.find_by!(UserID: 4)
    post login_path, params: {
      email: @mediator.Email,
      password: "password"
    }
    assert_response :redirect
  end

  def availability_params
    {
      availability: {
        DayOfWeek: 1,
        StartTime: "09:00",
        EndTime: "17:00"
      }
    }
  end

  test "lists mediator availability" do
    MediatorScheduleAvailability.create!(
      MediatorID: 4,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    get mediator_schedule_availabilities_path

    assert_response :success
    assert_equal 1, response.parsed_body.length
  end

  test "creates availability" do
    assert_difference "MediatorScheduleAvailability.count", 1 do
      post mediator_schedule_availabilities_path,
           params: availability_params
    end

    assert_response :created
    assert_equal 4, response.parsed_body["MediatorID"]
  end

  test "rejects invalid availability" do
    params = availability_params
    params[:availability][:EndTime] = "08:00"

    post mediator_schedule_availabilities_path, params: params

    assert_response :unprocessable_entity
  end

  test "updates own availability" do
    availability = MediatorScheduleAvailability.create!(
      MediatorID: 4,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    patch mediator_schedule_availability_path(availability),
          params: { availability: { DayOfWeek: 2 } }

    assert_response :success
    assert_equal 2, availability.reload.DayOfWeek
  end

  test "deletes own availability" do
    availability = MediatorScheduleAvailability.create!(
      MediatorID: 4,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    assert_difference "MediatorScheduleAvailability.count", -1 do
      delete mediator_schedule_availability_path(availability)
    end

    assert_response :no_content
  end

  test "cannot update another mediators availability" do
    availability = MediatorScheduleAvailability.create!(
      MediatorID: 8,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    patch mediator_schedule_availability_path(availability),
          params: { availability: { DayOfWeek: 2 } }

    assert_response :not_found
    assert_equal 1, availability.reload.DayOfWeek
  end

  test "cannot delete another mediators availability" do
    availability = MediatorScheduleAvailability.create!(
      MediatorID: 8,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    assert_no_difference "MediatorScheduleAvailability.count" do
      delete mediator_schedule_availability_path(availability)
    end

    assert_response :not_found
  end

  test "only lists own availability" do
    MediatorScheduleAvailability.create!(
      MediatorID: 4,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    MediatorScheduleAvailability.create!(
      MediatorID: 8,
      DayOfWeek: 2,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    get mediator_schedule_availabilities_path

    assert_response :success
    assert_equal [4], response.parsed_body.map { |a| a["MediatorID"] }
  end

  test "cannot impersonate another mediator when creating" do
    params = availability_params
    params[:availability][:MediatorID] = 8

    post mediator_schedule_availabilities_path, params: params

    assert_response :created
    assert_equal 4, response.parsed_body["MediatorID"]
  end

  test "requires login to access availability" do
    delete logout_path

    get mediator_schedule_availabilities_path

    assert_response :unauthorized
    assert_equal "Login required", response.parsed_body["error"]
  end

  test "rejects non mediator access to availability" do
    delete logout_path

    landlord = User.find_by!(UserID: 1)
    post login_path, params: {
      email: landlord.Email,
      password: "password"
    }

    assert_response :redirect

    get mediator_schedule_availabilities_path

    assert_response :forbidden
    assert_equal "Mediator access required", response.parsed_body["error"]
  end
end
