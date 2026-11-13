class TermsOfUseController < ApplicationController
  def show
    return_to = params[:return_to]
    if return_to.is_a?(String) && return_to.start_with?("/") && !return_to.start_with?("//")
      @return_path = url_from(return_to)
    end
    @return_path ||= current_user ? dashboard_path : root_path
  end
end
