# frozen_string_literal: true

module RedmineMessenger
  module Patches
    module TimeEntryPatch
      extend ActiveSupport::Concern

      included do
        include InstanceMethods

        after_create_commit :send_messenger_time_entry_create
        after_update_commit :send_messenger_time_entry_update
      end

      module InstanceMethods
        def send_messenger_time_entry_create
          channels = Messenger.channels_for_project project
          url = Messenger.url_for_project project

          if Messenger.setting_for_project project, :messenger_direct_users_messages
            messenger_time_entry_to_be_notified.each do |user_obj|
              channels.append "@#{user_obj.login}" unless user_obj == user
            end
          end

          return unless channels.present? && url
          return if issue&.is_private? && !Messenger.setting_for_project(project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            attachment = {}
            attachment[:fields] = []

            # Add hours
            attachment[:fields] << { title: I18n.t(:field_hours),
                                     value: Messenger.markup_format(hours.to_s),
                                     short: true }

            # Add activity (work category)
            if activity.present?
              attachment[:fields] << { title: I18n.t(:field_activity),
                                       value: Messenger.markup_format(activity.to_s),
                                       short: true }
            end

            # Add comments
            if comments.present?
              attachment[:fields] << { title: I18n.t(:field_comments),
                                       value: Messenger.markup_format(comments),
                                       short: false }
            end

            # Add spent date
            attachment[:fields] << { title: I18n.t(:field_spent_on),
                                     value: Messenger.markup_format(spent_on.to_s),
                                     short: true }

            message = if issue.present?
                        l(:label_messenger_time_entry_created_with_issue,
                          project_url: Messenger.project_url_markdown(project),
                          issue_url: "<#{Messenger.object_url issue}|#{Messenger.markup_format issue}>",
                          user: user)
                      else
                        l(:label_messenger_time_entry_created,
                          project_url: Messenger.project_url_markdown(project),
                          user: user)
                      end

            Messenger.speak send_messenger_time_entry_mention_message(message),
                            channels, url, attachment: attachment, project: project
          ensure
            ::I18n.locale = initial_language
          end
        end

        def send_messenger_time_entry_update
          channels = Messenger.channels_for_project project
          url = Messenger.url_for_project project

          if Messenger.setting_for_project project, :messenger_direct_users_messages
            messenger_time_entry_to_be_notified.each do |user_obj|
              channels.append "@#{user_obj.login}" unless user_obj == user
            end
          end

          return unless channels.present? && url
          return if issue&.is_private? && !Messenger.setting_for_project(project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            attachment = {}
            attachment[:fields] = []

            # Add hours
            attachment[:fields] << { title: I18n.t(:field_hours),
                                     value: Messenger.markup_format(hours.to_s),
                                     short: true }

            # Add activity (work category)
            if activity.present?
              attachment[:fields] << { title: I18n.t(:field_activity),
                                       value: Messenger.markup_format(activity.to_s),
                                       short: true }
            end

            # Add comments
            if comments.present?
              attachment[:fields] << { title: I18n.t(:field_comments),
                                       value: Messenger.markup_format(comments),
                                       short: false }
            end

            # Add spent date
            attachment[:fields] << { title: I18n.t(:field_spent_on),
                                     value: Messenger.markup_format(spent_on.to_s),
                                     short: true }

            message = if issue.present?
                        l(:label_messenger_time_entry_updated_with_issue,
                          project_url: Messenger.project_url_markdown(project),
                          issue_url: "<#{Messenger.object_url issue}|#{Messenger.markup_format issue}>",
                          user: user)
                      else
                        l(:label_messenger_time_entry_updated,
                          project_url: Messenger.project_url_markdown(project),
                          user: user)
                      end

            Messenger.speak send_messenger_time_entry_mention_message(message),
                            channels, url, attachment: attachment, project: project
          ensure
            ::I18n.locale = initial_language
          end
        end

        private

        def messenger_time_entry_to_be_notified
          to_be_notified = []
          
          # Include issue assignee if time entry is related to an issue
          if issue.present?
            to_be_notified << issue.assigned_to if issue.assigned_to.present?
            to_be_notified += issue.watcher_users if issue.watcher_users.any?
          end
          
          to_be_notified.compact.uniq
        end

        def send_messenger_time_entry_mention_message(base_message)
          mention_to = ''
          if Messenger.setting_for_project(project, :auto_mentions) ||
             Messenger.textfield_for_project(project, :default_mentions).present?
            mention_to = Messenger.mentions project, comments
          end
          "#{base_message}#{mention_to}"
        end
      end
    end
  end
end