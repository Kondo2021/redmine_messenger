# frozen_string_literal: true

module RedmineMessenger
  module Patches
    module UserPatch
      extend ActiveSupport::Concern

      included do
        include InstanceMethods
        
        safe_attributes 'discord_username', 'discord_user_id'
      end

      module InstanceMethods
        def discord_mention
          # Discord uses <@user_id> format for mentions, not @username
          if discord_user_id.present?
            "<@#{discord_user_id}>"
          elsif discord_username.present?
            "@#{discord_username}"
          else
            nil
          end
        end
      end
    end
  end
end