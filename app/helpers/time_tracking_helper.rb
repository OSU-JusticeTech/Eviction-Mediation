module TimeTrackingHelper
  # Formats tracked seconds for display, e.g. "3h 12m" or "45m".
  def format_duration(seconds)
    total_minutes = seconds.to_i / 60
    hours, minutes = total_minutes.divmod(60)
    hours.positive? ? "#{hours}h #{minutes}m" : "#{minutes}m"
  end

  # The signed-in mediator's running time-tracking session, memoized per
  # request because the navbar and the case page both need it.
  def current_time_entry
    return @current_time_entry if defined?(@current_time_entry)

    @current_time_entry = if current_user&.Role == "Mediator"
      MediatorTimeEntry.current_for(current_user.UserID)
    end
  end
end
