class DispensaryPatient < ApplicationRecord
  belongs_to :user
  belongs_to :reeferal_user, foreign_key: :reeferal_user_id, class_name:'User'
  belongs_to :dispensary
  
  validates_uniqueness_of :user, scope: [:dispensary]

  has_many :dispensary_redeemables

  before_save :create_reward_notifications

  POINTS = {
    small_reward: 30,
    medium_reward: 90,
    large_reward: 150,
    points_cap: 28,
    first_time_sign_up: 10,
    invitation: 2,
    visit: 10,
    fb_reward: 10,
    restore_invitation: 0
  }

  class << self
    def create_for_in_store_signup(user, dispensary_id)
      # create dispensary_patient
      dispensary_patient = DispensaryPatient.create(
        user_id: user.id,
        dispensary_id: dispensary_id,
        gets_free_joint: false,
        last_visit: DateTime.now,
        points: POINTS[:first_time_sign_up])

      Notification.create_onboarding(user, dispensary_patient.dispensary, :sign_up)
      Notification.create_you_visit(user, dispensary_patient.dispensary)
    end

    def set_friendship_points(inviter, invitee, dispensary)
      # create friendship notifications
      Notification.create_both_friendships(invitee, dispensary, inviter)
    end

    def set_points_and_joint_for_user_reeferal(inviter, invitee, dispensary)
      # find/create dp relation
      inviter_dp = DispensaryPatient.find_or_initialize_by(user_id: inviter.id, dispensary_id: dispensary.id)
      
      # set message for inviter, that he gets free joint when invitee visits
      inviter_dp.free_joint_message = I18n.t('tablet.free_joint_inviter', friend: invitee.name, dispensary: dispensary.name)
      inviter_dp.save

      # create notification for inviter
      # invitee signed up with your link, text for a free joint when friend visits
      Notification.create_invitee_signed_up(inviter, dispensary, invitee)

      # allocate friendship points to invitee & free joint
      invitee_dp = DispensaryPatient.find_or_initialize_by(user_id: invitee.id, dispensary_id: dispensary.id)
      invitee_dp.gets_free_joint = true
      invitee_dp.reeferal_user_id = inviter.id
      invitee_dp.free_joint_message = I18n.t('tablet.free_joint_invitee', friend: inviter.name)
      invitee_dp.save
      
      # you accepted inviters refferal, free joint
      Notification.create_reeferal_free_join(invitee, dispensary, inviter)
    end
  end # class << self

  def cap_limit_reached_with?(points_to_be_added)
    (points_to_be_added + points_cap > POINTS[:points_cap])
  end



  def visit!
    print "USER VISIT,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,"
    if points + POINTS[:visit] > self.dispensary.large_reward.points
      self.points = self.dispensary.large_reward.points
    else
      self.points += POINTS[:visit]
    end
    self.points_cap = 0
    self.last_visit = Time.now
    self.save
    Notification.create_you_visit(user, dispensary)
    
    # store the user visit in visitation table
    UserVisitation.create(user_id: user.id, dispensary_id: dispensary.id, visited_at: DateTime.now)
    # check if it is the 2, 4, 6, 8 and 10th visit
    user_visitations = UserVisitation.where(user_id: user.id).count
    if user_visitations <= 10 && user_visitations % 2 == 0
      # check if user has any friends
      unless user.friends.any?
        return true
      end
    end
    return false
  end

  def redeem_deal!(dispensary_deal)
    return false if self.points < dispensary_deal.points
    self.points = self.points - dispensary_deal.points
    return false unless self.save

    self.dispensary_redeemables.create(
      dispensary_deal_id: dispensary_deal.id,
      dispensary_patient_id: self.id
    )
  end

  def enough_points_for_small_reward?
    points >= self.dispensary.small_reward.points and points <  self.dispensary.medium_reward.points
  end

  def enough_points_for_medium_reward?
    points >= self.dispensary.medium_reward.points and points <  self.dispensary.large_reward.points
  end

  def enough_points_for_large_reward?
    points == self.dispensary.large_reward.points
  end

  def claimed_rewards
    DispensaryRedeemable.where(dispensary_patient: self)
  end

  def last_claimed_small_reward
    DispensaryRedeemable.joins(:dispensary_deal).
      where(dispensary_patient: self).
      where("dispensary_deals.points = ?", self.dispensary.small_reward.points).
      order(redeemed_at: :desc).first
  end

  def last_claimed_medium_reward
    DispensaryRedeemable.joins(:dispensary_deal).
      where(dispensary_patient: self).
      where("dispensary_deals.points = ?", self.dispensary.medium_reward.points).
      order(redeemed_at: :desc).first
  end

  def last_claimed_large_reward
    DispensaryRedeemable.joins(:dispensary_deal).
      where(dispensary_patient: self).
      where("dispensary_deals.points = ?", self.dispensary.large_reward.points).
      order(redeemed_at: :desc).first
  end

  private
  def user_has_small_reward_notification_with_last_visit(user, dispensary_id)
    if last_claimed_small_reward.nil?
      return false
    end
    user.small_reward_notifications.
      where(dispensary_id: dispensary_id).
      where("created_at > ?", last_claimed_small_reward.redeemed_at).any?
  end

  def user_has_medium_reward_notification_with_last_visit(user, dispensary_id)
    if last_claimed_medium_reward.nil?
      return false
    end
    user.medium_reward_notifications.
      where(dispensary_id: dispensary_id).
      where("created_at > ?", last_claimed_medium_reward.redeemed_at).any?
  end

  def user_has_large_reward_notification_with_last_visit(user, dispensary_id)
    if last_claimed_large_reward.nil?
      return false
    end
    user.large_reward_notifications.
      where(dispensary_id: dispensary_id).
      where("created_at > ?", last_claimed_large_reward.redeemed_at).any?
  end

  def create_reward_notifications
    # check if user has enought points and create the proper notification
    if claimed_rewards.any?
      if enough_points_for_small_reward? && !user_has_small_reward_notification_with_last_visit(user, dispensary_id)
        Notification.create_small_reward(user, dispensary)
      elsif enough_points_for_medium_reward? && !user_has_medium_reward_notification_with_last_visit(user, dispensary_id)
        Notification.create_medium_reward(user, dispensary)
      elsif enough_points_for_large_reward? && !user_has_large_reward_notification_with_last_visit(user, dispensary_id)
        Notification.create_large_reward(user, dispensary)
      end
    else
      if enough_points_for_small_reward? &&
        !user.small_reward_notifications.where(dispensary_id: dispensary_id).any?
        Notification.create_small_reward(user, dispensary)
      elsif enough_points_for_medium_reward? &&
        !user.medium_reward_notifications.where(dispensary_id: dispensary_id).any?
        Notification.create_medium_reward(user, dispensary)
      elsif enough_points_for_large_reward? &&
        !user.large_reward_notifications.where(dispensary_id: dispensary_id).any?
        Notification.create_large_reward(user, dispensary)
      end
    end
  end

end
