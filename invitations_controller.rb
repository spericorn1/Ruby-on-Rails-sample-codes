class Users::InvitationsController < Users::BaseController
  respond_to :html, :js, :json
  layout "welcome"
  before_action :set_user, only: [:enter_confirmation_code, :enter_password, :enter_name, :resend_code]
  before_action :authenticate_user!, :set_invitation, only: [:invitation_status]

  skip_before_action :verify_authenticity_token

  def show
    if inviter = User.find_by(magic_link: params[:id])
      cookies[:inviter_id] = inviter.id
      redirect_to enter_phone_nr_users_invitations_path
    else
      raise CanCan::AccessDenied
    end
  end

  def resend_code
    @user.resend_confirmation_code
    redirect_to enter_confirmation_code_users_onboarding_path(@user)
  end

  def enter_phone_nr
    @user = User.new
    @inviter = User.find_by(id: cookies[:inviter_id]) || nil
    if @inviter.present?
      @user.ref = @inviter.id
    end
  end

  def enter_phone_nr_confirm
    @user = User.find_signed_up_or_create_new(user_params[:phone_number])

    if @user.is_step_signed_up?
      redirect_to user_edit_session_path(@user, ref: user_params[:ref])
    else
      if @user.send_confirmation_code
        redirect_to enter_confirmation_code_users_invitation_path(@user)
      else
        @user.errors.add(:phone_number, "invalid")
        @inviter = User.find_by(id: cookies[:inviter_id]) || nil
        @user.ref = @inviter.id
        render :enter_phone_nr
      end
    end
  end

  def enter_confirmation_code
    if @user.present?
      if params[:user].present? and user_params[:provided_confirmation_code].present?
        @user = User.sign_up_enter_confirmation_code(@user, user_params[:provided_confirmation_code])
        unless @user.errors.any?
          redirect_to enter_name_users_invitation_path(@user)
        end
      end
    else
      redirect_to enter_phone_nr_users_invitation_path
    end
  end

  def enter_name
    return redirect_to(enter_phone_nr_users_invitation_path) if @user.nil?

    if request.put?
      @user.name = user_params[:name]
      if @user.confirm_enter_name_step!.errors.any?
        render :enter_name
      else
        redirect_to enter_password_users_invitation_path(@user)
      end
    end
  end

  def enter_password
    if @user.present?
      if params[:user].present?
        @user.password= user_params[:password]
        @user.password_confirmation= user_params[:password_confirmation]
        unless @user.confirm_enter_password_step!.errors.any?
          if cookies[:inviter_id].present?
            # find inviter
            @inviter = User.find_by(id: cookies[:inviter_id])
            # create invitation
            invitation = Invitation.create(inviter_id: cookies[:inviter_id], invitee_id: @user.id, invitation_state: Invitation::ACCEPTED_STATUS)
            # get last visited or random dispensary from inviter
            @dispensary = invitation.inviters_last_visited_dispensary_or_random_dispensary

            # handle points, joints & notifications
            DispensaryPatient.set_points_and_joint_for_user_reeferal(@inviter, @user, @dispensary)

            # send sms to inviter that invitee accepted
            message = I18n.t('sms.invitation_new_user_inviter_a', dispensary: @dispensary.name, friend: @user.name)
            SMS.send_to(@inviter.phone_number, message)
          end
          sign_in @user
          # redirect_to users_root_path
          redirect_to share_link_users_onboarding_path(@user)
        end
      end
    else
      redirect_to enter_phone_nr_users_invitation_path
    end
  end

  def invitation_status
    if Invitation.invitation_states.keys.include?(invitation_params[:invitation_state]) && @invitation.present?
      if @invitation.update(invitation_params)

        if @invitation.invitation_state == Invitation::ACCEPTED_STATUS
          dispensary = @invitation.inviter.last_visited_dispensary_or_random
          DispensaryPatient.set_friendship_points(@invitation.inviter, @invitation.invitee, dispensary)

          #message = I18n.t('sms.invitation_existing_user_invitee', friend: @invitation.inviter.name)
          #SMS.send_to(@invitation.invitee.phone_number, message)

          #message = I18n.t('sms.invitation_existing_user_inviter', friend: @invitation.invitee.name, dispensary: dispensary.name,  url: users_invitation_url(@inviter.magic_link))
          #SMS.send_to(@invitation.inviter.phone_number, message)
        end

        render json: {}, status: :ok
        return
      end
    end
    render json: {}, status: :unprocessable_entity
  end

  private
    def set_invitation
      @invitation = Invitation.where(id: params[:id], invitee_id: current_user.id).first
    end

    def invitation_params
      params.require(:invitation).permit(:invitation_state)
    end

    def user_params
      params.require(:user).permit(:name, :phone_number, :provided_confirmation_code, :password, :password_confirmation, :ref)
    end

    def set_user
      @user = User.friendly.find(params[:id])
    end
end
