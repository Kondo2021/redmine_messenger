# frozen_string_literal: true

module RedmineMessenger
  VERSION = '1.0.15'
  REDMINE_CONTACTS_SUPPORT = Redmine::Plugin.installed? 'redmine_contacts'
  REDMINE_DB_SUPPORT = Redmine::Plugin.installed? 'redmine_db'

  include RedminePluginKit::PluginBase

  class << self
    private

    def setup
      # Patches
      loader.add_patch %w[Issue
                          Project
                          WikiPage
                          TimeEntry]

      loader.add_patch 'Contact' if RedmineMessenger::REDMINE_CONTACTS_SUPPORT
      loader.add_patch 'DbEntry' if RedmineMessenger::REDMINE_DB_SUPPORT
      loader.add_patch 'Password' if Redmine::Plugin.installed? 'redmine_passwords'

      # Helper
      loader.add_helper [{ controller: 'Projects', helper: 'MessengerProjects' }]

      # Global helpers
      loader.add_global_helper RedmineMessenger::Helpers

      # Apply patches and helper
      loader.apply!
    end
  end
end
