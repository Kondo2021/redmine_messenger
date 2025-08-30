# frozen_string_literal: true

class AddNotificationTypeToMessengerSettings < ActiveRecord::Migration[4.2]
  def up
    add_column :messenger_settings, :notification_type, :string, default: 'discord' unless column_exists?(:messenger_settings, :notification_type)
  end

  def down
    remove_column :messenger_settings, :notification_type if column_exists?(:messenger_settings, :notification_type)
  end
end