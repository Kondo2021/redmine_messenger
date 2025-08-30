# frozen_string_literal: true

class AddDiscordUsernameToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :discord_username, :string
  end
end