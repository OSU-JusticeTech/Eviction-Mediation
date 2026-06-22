require "test_helper"

class MediatorAvailabilityControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mediator_user = users(:mediator1)
    @tenant = users(:tenant1)
  end

  # Authentication Tests
  test "redirects to login when not authenticated" do
    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: false
        }
      }
    }
    assert_redirected_to login_path
  end

  # Authorization Tests
  test "redirects non-mediator users to dashboard" do
    log_in_as(@tenant)

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @tenant.id,
          Available: true
        }
      }
    }
    assert_redirected_to dashboard_path
  end

  # Availability Toggle Tests
  test "mediator can toggle availability from available to unavailable" do
    log_in_as(@mediator_user)
    assert @mediator_user.mediator.Available

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: false
        }
      }
    }

    assert_redirected_to dashboard_path
    assert_equal "Availability updated.", flash[:notice]

    @mediator_user.reload
    assert_not @mediator_user.mediator.Available
  end

  test "mediator can toggle availability from unavailable to available" do
    # Setup: make mediator unavailable
    @mediator_user.mediator.update(Available: false)
    log_in_as(@mediator_user)
    assert_not @mediator_user.mediator.Available

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: true
        }
      }
    }

    assert_redirected_to dashboard_path
    assert_equal "Availability updated.", flash[:notice]

    @mediator_user.reload
    assert @mediator_user.mediator.Available
  end

  # At-Capacity Behavior Tests
  test "mediator can still toggle availability when at capacity" do
    @mediator_user.mediator.update(ActiveMediations: 5, MediationCap: 5)
    log_in_as(@mediator_user)
    assert @mediator_user.mediator.Available

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: false
        }
      }
    }

    assert_redirected_to dashboard_path
    assert_equal "Availability updated.", flash[:notice]

    @mediator_user.reload
    assert_not @mediator_user.mediator.Available
  end

  # Redirect Tests
  test "redirects to dashboard after successful update" do
    log_in_as(@mediator_user)

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: false
        }
      }
    }

    assert_redirected_to dashboard_path
  end

  # Flash Message Tests
  test "shows success flash message on successful update" do
    log_in_as(@mediator_user)

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: false
        }
      }
    }

    assert_equal "Availability updated.", flash[:notice]
  end


  # Database Persistence Tests
  test "availability change persists in database" do
    log_in_as(@mediator_user)
    original_availability = @mediator_user.mediator.Available

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: !original_availability
        }
      }
    }

    @mediator_user.reload
    assert_equal !original_availability, @mediator_user.mediator.Available
  end

  # Security Tests
  test "only updates Available field, not other mediator attributes" do
    log_in_as(@mediator_user)
    original_cap = @mediator_user.mediator.MediationCap
    original_active = @mediator_user.mediator.ActiveMediations

    patch mediator_availability_path, params: {
      user: {
        mediator_attributes: {
          id: @mediator_user.mediator.id,
          Available: false,
          MediationCap: 999,
          ActiveMediations: 999
        }
      }
    }

    @mediator_user.reload
    assert_equal original_cap, @mediator_user.mediator.MediationCap
    assert_equal original_active, @mediator_user.mediator.ActiveMediations
    assert_not @mediator_user.mediator.Available
  end
end
