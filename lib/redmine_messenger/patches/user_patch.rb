# frozen_string_literal: true

module RedmineMessenger
  module Patches
    module UserPatch
      extend ActiveSupport::Concern

      included do
        include InstanceMethods
        
        safe_attributes 'discord_username'
      end

      module InstanceMethods
        def discord_mention
          discord_username.present? ? "@#{discord_username}" : nil
        end
      end
    end
  end
end