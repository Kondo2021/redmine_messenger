# frozen_string_literal: true

class AddDiscordUserIdToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :discord_user_id, :string
    
    # discord_username column is kept for display purposes
    # discord_user_id is the actual numeric ID for mentions
  end
end