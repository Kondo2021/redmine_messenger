# frozen_string_literal: true

class MessengerSetting < (defined?(ApplicationRecord) == 'constant' ? ApplicationRecord : ActiveRecord::Base)
  belongs_to :project

  validates :messenger_url, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]), allow_blank: true }
  validates :notification_type, inclusion: { in: %w[slack discord], allow_blank: true }

  def self.find_or_create(project_id)
    setting = MessengerSetting.find_by project_id: project_id
    unless setting
      setting = MessengerSetting.new
      setting.project_id = project_id
      setting.save!
    end

    setting
  end
end
