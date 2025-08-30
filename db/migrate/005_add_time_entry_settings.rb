# frozen_string_literal: true

class AddTimeEntrySettings < ActiveRecord::Migration[4.2]
  def change
    add_column :messenger_settings, :post_time_entries, :integer, default: 0, null: false
    add_column :messenger_settings, :post_time_entry_updates, :integer, default: 0, null: false
  end
end