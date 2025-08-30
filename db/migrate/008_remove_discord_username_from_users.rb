# frozen_string_literal: true

class RemoveDiscordUsernameFromUsers < ActiveRecord::Migration[4.2]
  def change
    remove_column :users, :discord_username, :string
  end
end