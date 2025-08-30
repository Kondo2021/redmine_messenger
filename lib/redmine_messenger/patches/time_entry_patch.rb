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

          return unless channels.present? && url && Messenger.setting_for_project(project, :post_time_entries)
          return if issue&.is_private? && !Messenger.setting_for_project(project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            attachment = {}
            attachment[:fields] = []

            # Add hours in h:mm format
            hours_formatted = format_hours_hm(hours)
            attachment[:fields] << { title: "作業時間",
                                     value: Messenger.markup_format(hours_formatted),
                                     short: true }

            # Add activity (work category)
            if activity.present?
              attachment[:fields] << { title: "作業分類",
                                       value: Messenger.markup_format(activity.to_s),
                                       short: true }
            end

            # Add spent date
            attachment[:fields] << { title: "日付",
                                     value: Messenger.markup_format(spent_on.to_s),
                                     short: true }

            # Add comments
            if comments.present?
              attachment[:fields] << { title: "コメント",
                                       value: Messenger.markup_format(comments),
                                       short: false }
            end

            main_message = if issue.present?
                            l(:label_messenger_time_entry_created_with_issue,
                              project_name: Messenger.markup_format(project.name),
                              tracker: issue.tracker.name,
                              issue_url: "<#{Messenger.object_url issue}|#{Messenger.markup_format issue.subject}>",
                              user: Messenger.markup_format(user.to_s))
                          else
                            l(:label_messenger_time_entry_created,
                              project_name: Messenger.markup_format(project.name),
                              user: Messenger.markup_format(user.to_s))
                          end
            
            # Add mentions on separate lines
            mentions = build_time_entry_mentions_message
            full_message = "#{main_message}#{mentions}"

            Messenger.speak full_message, channels, url, attachment: attachment, project: project
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

          return unless channels.present? && url && Messenger.setting_for_project(project, :post_time_entry_updates)
          return if issue&.is_private? && !Messenger.setting_for_project(project, :post_private_issues)

          initial_language = ::I18n.locale
          begin
            set_language_if_valid Setting.default_language

            attachment = {}
            attachment[:fields] = []

            # Add hours in h:mm format
            hours_formatted = format_hours_hm(hours)
            attachment[:fields] << { title: "作業時間",
                                     value: Messenger.markup_format(hours_formatted),
                                     short: true }

            # Add activity (work category)
            if activity.present?
              attachment[:fields] << { title: "作業分類",
                                       value: Messenger.markup_format(activity.to_s),
                                       short: true }
            end

            # Add spent date
            attachment[:fields] << { title: "日付",
                                     value: Messenger.markup_format(spent_on.to_s),
                                     short: true }

            # Add comments
            if comments.present?
              attachment[:fields] << { title: "コメント",
                                       value: Messenger.markup_format(comments),
                                       short: false }
            end

            main_message = if issue.present?
                            l(:label_messenger_time_entry_updated_with_issue,
                              project_name: Messenger.markup_format(project.name),
                              tracker: issue.tracker.name,
                              issue_url: "<#{Messenger.object_url issue}|#{Messenger.markup_format issue.subject}>",
                              user: Messenger.markup_format(user.to_s))
                          else
                            l(:label_messenger_time_entry_updated,
                              project_name: Messenger.markup_format(project.name),
                              user: Messenger.markup_format(user.to_s))
                          end
            
            # Add mentions on separate lines
            mentions = build_time_entry_mentions_message
            full_message = "#{main_message}#{mentions}"

            Messenger.speak full_message, channels, url, attachment: attachment, project: project
          ensure
            ::I18n.locale = initial_language
          end
        end

        private

        def format_hours_hm(hours_decimal)
          return "0:00" if hours_decimal.blank? || hours_decimal == 0
          
          total_minutes = (hours_decimal * 60).round
          hours_part = total_minutes / 60
          minutes_part = total_minutes % 60
          
          "#{hours_part}:#{minutes_part.to_s.rjust(2, '0')}"
        end

        def messenger_time_entry_to_be_notified
          to_be_notified = []
          
          # Include issue assignee if time entry is related to an issue
          if issue.present?
            to_be_notified << issue.assigned_to if issue.assigned_to.present?
            to_be_notified += issue.watcher_users if issue.watcher_users.any?
          end
          
          to_be_notified.compact.uniq
        end

        def build_time_entry_mentions_message
          return '' unless issue.present?
          
          mentions = []
          
          # Add assignee mention
          if issue.assigned_to.present?
            assignee_mention = Messenger.format_user_mention(issue.assigned_to)
            mentions << "\n\n👤 担当者: #{assignee_mention}" if assignee_mention.present?
          end
          
          # Add watcher mentions
          if issue.watcher_users.any?
            watcher_mentions = issue.watcher_users.map { |user| Messenger.format_user_mention(user) }.compact
            if watcher_mentions.any?
              mentions << "\n👁️ ウォッチャー: #{watcher_mentions.join(' ')}\n\n"
            end
          end
          
          mentions.join
        end
      end
    end
  end
end