# frozen_string_literal: true

class RemoveDiscordUsernameFromUsers < ActiveRecord::Migration[4.2]
  def up
    remove_column :users, :discord_username if column_exists?(:users, :discord_username)
  end

  def down
    add_column :users, :discord_username, :string unless column_exists?(:users, :discord_username)
  end
end