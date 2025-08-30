# frozen_string_literal: true

class AddSlackUserIdToUsers < ActiveRecord::Migration[4.2]
  def up
    add_column :users, :slack_user_id, :string unless column_exists?(:users, :slack_user_id)
  end

  def down
    remove_column :users, :slack_user_id if column_exists?(:users, :slack_user_id)
  end
end